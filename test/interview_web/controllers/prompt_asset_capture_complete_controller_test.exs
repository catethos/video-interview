defmodule InterviewWeb.PromptAssetCaptureCompleteControllerTest do
  use InterviewWeb.ConnCase, async: false

  alias Interview.Auth.Tokens
  alias Interview.PromptAssets
  alias Interview.Workers.PromptAssetFinalizer

  use Oban.Testing, repo: Interview.Repo

  setup do
    tenant = Interview.Fixtures.tenant!()
    recruiter = Interview.Fixtures.recruiter!(tenant.id)
    {:ok, asset, cid} = PromptAssets.create_recording(tenant.id, %{kind: "video"})
    bearer = Tokens.mint_recruiter_upload_bearer(recruiter.id, tenant.id)
    {:ok, tenant: tenant, recruiter: recruiter, asset: asset, cid: cid, bearer: bearer}
  end

  defp post_complete(conn, aid, body, bearer) do
    conn
    |> put_req_header("authorization", "Bearer " <> bearer)
    |> post(~p"/api/prompt_assets/#{aid}/capture_complete", body)
  end

  test "happy path enqueues finalizer", %{conn: conn, asset: a, cid: cid, bearer: b} do
    res =
      post_complete(
        conn,
        a.id,
        %{"captureInstanceId" => cid, "expectedTotalBytes" => 4096},
        b
      )

    assert %{"ok" => true, "state" => "capture_complete"} = json_response(res, 200)
    assert_enqueued(worker: PromptAssetFinalizer, args: %{"prompt_asset_id" => a.id})
  end

  test "fenced writer returns 410", %{conn: conn, asset: a, cid: cid, bearer: b} do
    asset = Interview.Repo.get!(Interview.Templates.PromptAsset, a.id)
    {:ok, _, _new_cid} = PromptAssets.claim(asset, [])

    res =
      post_complete(
        conn,
        a.id,
        %{"captureInstanceId" => cid, "expectedTotalBytes" => 4096},
        b
      )

    assert %{"ok" => false, "error" => "fenced"} = json_response(res, 410)
  end

  test "wrong-tenant bearer is 404", %{conn: conn, asset: a, cid: cid} do
    other = Interview.Fixtures.tenant!()
    other_rec = Interview.Fixtures.recruiter!(other.id)
    bad = Tokens.mint_recruiter_upload_bearer(other_rec.id, other.id)

    res =
      post_complete(
        conn,
        a.id,
        %{"captureInstanceId" => cid, "expectedTotalBytes" => 4096},
        bad
      )

    assert %{"error" => "not_found"} = json_response(res, 404)
  end

  test "missing captureInstanceId → 422", %{conn: conn, asset: a, bearer: b} do
    res = post_complete(conn, a.id, %{"expectedTotalBytes" => 4096}, b)
    assert %{"error" => "missing_captureInstanceId"} = json_response(res, 422)
  end

  test "401 without Authorization", %{conn: conn, asset: a, cid: cid} do
    conn =
      post(conn, ~p"/api/prompt_assets/#{a.id}/capture_complete", %{
        "captureInstanceId" => cid,
        "expectedTotalBytes" => 4096
      })

    assert json_response(conn, 401) == %{"ok" => false, "error" => "unauthorized"}
  end
end
