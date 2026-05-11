defmodule InterviewWeb.Tus.PromptAssetPlugTest do
  use InterviewWeb.ConnCase, async: false

  alias Interview.Auth.Tokens
  alias Interview.PromptAssets
  alias Interview.Repo
  alias Interview.Templates.PromptAsset

  @tus_version "1.0.0"
  @body_ct "application/offset+octet-stream"

  setup do
    tenant = Interview.Fixtures.tenant!()
    recruiter = Interview.Fixtures.recruiter!(tenant.id)
    {:ok, asset, cid} = PromptAssets.create_recording(tenant.id, %{kind: "video"})
    bearer = Tokens.mint_recruiter_upload_bearer(recruiter.id, tenant.id)
    {:ok, tenant: tenant, recruiter: recruiter, asset: asset, cid: cid, bearer: bearer}
  end

  defp tus_url(aid, cid), do: "/uploads/prompt_assets/#{aid}/#{cid}"

  defp do_head(conn, aid, cid, opts \\ []) do
    conn
    |> put_req_header("tus-resumable", @tus_version)
    |> maybe_bearer(opts[:bearer])
    |> Phoenix.ConnTest.dispatch(InterviewWeb.Endpoint, :head, tus_url(aid, cid), nil)
  end

  defp do_patch(conn, aid, cid, offset, body, opts \\ []) do
    extra = Keyword.get(opts, :headers, [])
    upload_length = Keyword.get(opts, :upload_length)

    conn =
      conn
      |> put_req_header("tus-resumable", @tus_version)
      |> put_req_header("content-type", @body_ct)
      |> put_req_header("upload-offset", Integer.to_string(offset))
      |> maybe_bearer(opts[:bearer])

    conn =
      if upload_length,
        do: put_req_header(conn, "upload-length", Integer.to_string(upload_length)),
        else: conn

    conn = Enum.reduce(extra, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    Phoenix.ConnTest.dispatch(conn, InterviewWeb.Endpoint, :patch, tus_url(aid, cid), body)
  end

  defp maybe_bearer(conn, nil), do: conn
  defp maybe_bearer(conn, bearer), do: put_req_header(conn, "authorization", "Bearer " <> bearer)

  describe "OPTIONS" do
    test "advertises tus version", %{conn: conn} do
      conn =
        conn
        |> put_req_header("tus-resumable", @tus_version)
        |> Phoenix.ConnTest.dispatch(InterviewWeb.Endpoint, :options, "/uploads/prompt_assets", nil)

      assert conn.status == 204
      assert get_resp_header(conn, "tus-resumable") == [@tus_version]
    end
  end

  describe "HEAD" do
    test "fresh asset reports offset 0", %{conn: conn, asset: a, cid: cid, bearer: bearer} do
      conn = do_head(conn, a.id, cid, bearer: bearer)
      assert conn.status == 200
      assert get_resp_header(conn, "upload-offset") == ["0"]
    end

    test "fenced writer gets 410", %{conn: conn, asset: a, cid: cid, bearer: bearer} do
      asset = Repo.get!(PromptAsset, a.id)
      {:ok, _, _new_cid} = PromptAssets.claim(asset, [])

      conn = do_head(conn, a.id, cid, bearer: bearer)
      assert conn.status == 410
    end

    test "unknown asset is 404", %{conn: conn, bearer: bearer} do
      conn = do_head(conn, Ecto.UUID.generate(), "cap-x", bearer: bearer)
      assert conn.status == 404
    end

    test "missing bearer → 401", %{conn: conn, asset: a, cid: cid} do
      conn = do_head(conn, a.id, cid)
      assert conn.status == 401
    end

    test "wrong-tenant bearer → 404", %{conn: conn, asset: a, cid: cid} do
      other = Interview.Fixtures.tenant!()
      other_rec = Interview.Fixtures.recruiter!(other.id)
      bearer = Tokens.mint_recruiter_upload_bearer(other_rec.id, other.id)
      conn = do_head(conn, a.id, cid, bearer: bearer)
      assert conn.status == 404
    end
  end

  describe "PATCH" do
    test "first PATCH at offset 0 advances offset",
         %{conn: conn, asset: a, cid: cid, bearer: bearer} do
      conn = do_patch(conn, a.id, cid, 0, "hello", upload_length: 10, bearer: bearer)
      assert conn.status == 204
      assert get_resp_header(conn, "upload-offset") == ["5"]

      a2 = Repo.get!(PromptAsset, a.id)
      assert a2.bytes_uploaded == 5
      assert a2.expected_total_bytes == 10
    end

    test "subsequent PATCH advances offset",
         %{conn: conn, asset: a, cid: cid, bearer: bearer} do
      _ = do_patch(conn, a.id, cid, 0, "hello", bearer: bearer)
      conn2 = build_conn() |> do_patch(a.id, cid, 5, "-world", bearer: bearer)
      assert conn2.status == 204
      assert get_resp_header(conn2, "upload-offset") == ["11"]
    end

    test "wrong offset returns 409",
         %{conn: conn, asset: a, cid: cid, bearer: bearer} do
      _ = do_patch(conn, a.id, cid, 0, "hello", bearer: bearer)
      conn2 = build_conn() |> do_patch(a.id, cid, 999, "boom", bearer: bearer)
      assert conn2.status == 409
    end

    test "fenced writer returns 410",
         %{conn: conn, asset: a, cid: cid, bearer: bearer} do
      asset = Repo.get!(PromptAsset, a.id)
      {:ok, _, _} = PromptAssets.claim(asset, [])
      conn = do_patch(conn, a.id, cid, 0, "hello", bearer: bearer)
      assert conn.status == 410
    end

    test "wrong content-type returns 415",
         %{conn: conn, asset: a, cid: cid, bearer: bearer} do
      conn =
        conn
        |> put_req_header("tus-resumable", @tus_version)
        |> put_req_header("upload-offset", "0")
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("authorization", "Bearer " <> bearer)
        |> Phoenix.ConnTest.dispatch(InterviewWeb.Endpoint, :patch, tus_url(a.id, cid), "hi")

      assert conn.status == 415
    end

    test "PATCH without Authorization → 401", %{conn: conn, asset: a, cid: cid} do
      conn = do_patch(conn, a.id, cid, 0, "hello")
      assert conn.status == 401
    end

    test "PATCH with garbage bearer → 401",
         %{conn: conn, asset: a, cid: cid} do
      conn = do_patch(conn, a.id, cid, 0, "hello", bearer: "not-a-token")
      assert conn.status == 401
    end

    test "wrong-tenant bearer is 404 (cannot see asset)",
         %{conn: conn, asset: a, cid: cid} do
      other = Interview.Fixtures.tenant!()
      other_rec = Interview.Fixtures.recruiter!(other.id)
      bearer = Tokens.mint_recruiter_upload_bearer(other_rec.id, other.id)
      conn = do_patch(conn, a.id, cid, 0, "hello", bearer: bearer)
      assert conn.status == 404
    end
  end
end
