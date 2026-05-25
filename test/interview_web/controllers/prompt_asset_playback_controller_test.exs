defmodule InterviewWeb.PromptAssetPlaybackControllerTest do
  use InterviewWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Interview.Fixtures
  alias Interview.Repo
  alias Interview.Storage
  alias Interview.Templates.{PromptAsset, Question}

  setup do
    tenant = Fixtures.tenant!()
    template = Fixtures.template!(tenant.id)
    version = Fixtures.version!(template.id)
    question = Fixtures.question!(version.id, 1)
    session = Fixtures.session!(tenant.id, version.id)

    # Materialise a ready asset with a real on-disk artifact.
    storage_key = "test/prompt_assets/#{Ecto.UUID.generate()}.mp4"
    path = Storage.artifact_path(storage_key)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "VIDEO" <> :binary.copy(<<"X">>, 64))

    asset =
      Fixtures.prompt_asset!(tenant.id, %{
        state: "ready",
        storage_key: storage_key,
        mime_type: "video/mp4",
        kind: "video"
      })

    Repo.update_all(from(q in Question, where: q.id == ^question.id),
      set: [prompt_asset_id: asset.id]
    )

    on_exit(fn -> File.rm(path) end)

    {:ok, session: session, asset: asset, storage_key: storage_key}
  end

  test "streams the artifact when referenced by the session's template",
       %{conn: conn, session: s, asset: a} do
    res = get(conn, ~p"/capture/#{s.id}/prompt_assets/#{a.id}")
    assert res.status == 200
    assert get_resp_header(res, "content-type") == ["video/mp4; charset=utf-8"]
    body = response(res, 200)
    assert byte_size(body) > 0
  end

  test "returns 404 when the asset is not referenced by this session",
       %{conn: conn, asset: a} do
    other_session =
      Fixtures.session!(a.tenant_id, Fixtures.version!(Fixtures.template!(a.tenant_id).id).id)

    res = get(conn, ~p"/capture/#{other_session.id}/prompt_assets/#{a.id}")
    assert res.status == 404
  end

  test "returns 404 when the asset is not ready", %{conn: conn, session: s, asset: a} do
    Repo.update_all(from(x in PromptAsset, where: x.id == ^a.id), set: [state: "pending"])
    res = get(conn, ~p"/capture/#{s.id}/prompt_assets/#{a.id}")
    assert res.status == 404
  end

  test "supports HTTP Range requests for partial playback",
       %{conn: conn, session: s, asset: a} do
    res =
      conn
      |> put_req_header("range", "bytes=0-3")
      |> get(~p"/capture/#{s.id}/prompt_assets/#{a.id}")

    assert res.status == 206
    body = response(res, 206)
    assert byte_size(body) == 4
  end
end
