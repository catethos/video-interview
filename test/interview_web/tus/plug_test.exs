defmodule InterviewWeb.Tus.PlugTest do
  use InterviewWeb.ConnCase, async: false

  alias Interview.Capture
  alias Interview.Repo

  @tus_version "1.0.0"
  @body_ct "application/offset+octet-stream"

  setup do
    %{session: session, question: question} = Interview.Fixtures.graph!()
    {:ok, response, _} = Capture.claim_instance(session, question, 1, "cap-A")
    bearer = Interview.Fixtures.upload_bearer!(session)
    {:ok, response: response, session: session, bearer: bearer}
  end

  defp tus_url(rid, cid), do: "/uploads/tus/#{rid}/#{cid}"

  defp do_head(conn, rid, cid, opts \\ []) do
    bearer = Keyword.get(opts, :bearer)

    conn
    |> put_req_header("tus-resumable", @tus_version)
    |> maybe_bearer(bearer)
    |> Phoenix.ConnTest.dispatch(InterviewWeb.Endpoint, :head, tus_url(rid, cid), nil)
  end

  defp do_patch(conn, rid, cid, offset, body, opts \\ []) do
    extra = Keyword.get(opts, :headers, [])
    upload_length = Keyword.get(opts, :upload_length)
    bearer = Keyword.get(opts, :bearer)

    conn =
      conn
      |> put_req_header("tus-resumable", @tus_version)
      |> put_req_header("content-type", @body_ct)
      |> put_req_header("upload-offset", Integer.to_string(offset))
      |> maybe_bearer(bearer)

    conn =
      if upload_length,
        do: put_req_header(conn, "upload-length", Integer.to_string(upload_length)),
        else: conn

    conn =
      Enum.reduce(extra, conn, fn {k, v}, c -> put_req_header(c, k, v) end)

    Phoenix.ConnTest.dispatch(conn, InterviewWeb.Endpoint, :patch, tus_url(rid, cid), body)
  end

  defp maybe_bearer(conn, nil), do: conn
  defp maybe_bearer(conn, bearer), do: put_req_header(conn, "authorization", "Bearer " <> bearer)

  describe "OPTIONS" do
    test "advertises tus version", %{conn: conn} do
      conn =
        conn
        |> put_req_header("tus-resumable", @tus_version)
        |> Phoenix.ConnTest.dispatch(InterviewWeb.Endpoint, :options, "/uploads/tus", nil)

      assert conn.status == 204
      assert get_resp_header(conn, "tus-resumable") == [@tus_version]
      assert get_resp_header(conn, "tus-version") == [@tus_version]
    end
  end

  describe "HEAD" do
    test "fresh response reports offset 0", %{conn: conn, response: r, bearer: bearer} do
      conn = do_head(conn, r.id, "cap-A", bearer: bearer)
      assert conn.status == 200
      assert get_resp_header(conn, "upload-offset") == ["0"]
      assert get_resp_header(conn, "tus-resumable") == [@tus_version]
    end

    test "fenced writer gets 410", %{conn: conn, response: r, bearer: bearer} do
      session = Repo.get!(Interview.Capture.Session, r.session_id)
      question = Repo.get!(Interview.Templates.Question, r.template_question_id)
      {:ok, _, _} = Capture.claim_instance(session, question, 1, "cap-B")

      conn = do_head(conn, r.id, "cap-A", bearer: bearer)
      assert conn.status == 410
    end

    test "missing tus-resumable header is 412", %{conn: conn, response: r, bearer: _bearer} do
      conn =
        Phoenix.ConnTest.dispatch(conn, InterviewWeb.Endpoint, :head, tus_url(r.id, "cap-A"), nil)

      assert conn.status == 412
    end

    test "unknown response is 404", %{conn: conn} do
      conn = do_head(conn, Ecto.UUID.generate(), "cap-A")
      assert conn.status == 404
    end
  end

  describe "PATCH" do
    test "first PATCH at offset 0 advances offset and persists",
         %{conn: conn, response: r, bearer: bearer} do
      conn = do_patch(conn, r.id, "cap-A", 0, "hello", upload_length: 10, bearer: bearer)
      assert conn.status == 204
      assert get_resp_header(conn, "upload-offset") == ["5"]

      r2 = Repo.get!(Interview.Capture.Response, r.id)
      assert r2.bytes_uploaded == 5
      assert r2.expected_total_bytes == 10
      assert r2.last_upload_ack_at
    end

    test "subsequent PATCH advances offset", %{conn: conn, response: r, bearer: bearer} do
      _ = do_patch(conn, r.id, "cap-A", 0, "hello", bearer: bearer)
      conn2 = build_conn() |> do_patch(r.id, "cap-A", 5, "-world", bearer: bearer)
      assert conn2.status == 204
      assert get_resp_header(conn2, "upload-offset") == ["11"]
    end

    test "wrong offset returns 409 with current size", %{conn: conn, response: r, bearer: bearer} do
      _ = do_patch(conn, r.id, "cap-A", 0, "hello", bearer: bearer)
      conn2 = build_conn() |> do_patch(r.id, "cap-A", 999, "boom", bearer: bearer)
      assert conn2.status == 409
    end

    test "fenced writer returns 410 even before any bytes are written",
         %{conn: conn, response: r, bearer: bearer} do
      session = Repo.get!(Interview.Capture.Session, r.session_id)
      question = Repo.get!(Interview.Templates.Question, r.template_question_id)
      {:ok, _, _} = Capture.claim_instance(session, question, 1, "cap-B")

      conn = do_patch(conn, r.id, "cap-A", 0, "hello", bearer: bearer)
      assert conn.status == 410
    end

    test "wrong content-type returns 415", %{conn: conn, response: r, bearer: _bearer} do
      conn =
        conn
        |> put_req_header("tus-resumable", @tus_version)
        |> put_req_header("upload-offset", "0")
        |> put_req_header("content-type", "application/octet-stream")
        |> Phoenix.ConnTest.dispatch(InterviewWeb.Endpoint, :patch, tus_url(r.id, "cap-A"), "hi")

      assert conn.status == 415
    end

    test "missing tus-resumable returns 412", %{conn: conn, response: r, bearer: _bearer} do
      conn =
        conn
        |> put_req_header("content-type", @body_ct)
        |> put_req_header("upload-offset", "0")
        |> Phoenix.ConnTest.dispatch(InterviewWeb.Endpoint, :patch, tus_url(r.id, "cap-A"), "hi")

      assert conn.status == 412
    end

    test "replayed bytes are accepted as a no-op", %{conn: conn, response: r, bearer: bearer} do
      _ = do_patch(conn, r.id, "cap-A", 0, "hello", bearer: bearer)
      conn2 = build_conn() |> do_patch(r.id, "cap-A", 0, "h", bearer: bearer)
      assert conn2.status == 204
      assert get_resp_header(conn2, "upload-offset") == ["5"]
    end

    test "session.last_client_seen_at is touched on PATCH", %{
      conn: conn,
      response: r,
      bearer: bearer
    } do
      _ = do_patch(conn, r.id, "cap-A", 0, "hello", bearer: bearer)
      session = Repo.get!(Interview.Capture.Session, r.session_id)
      assert session.last_client_seen_at
    end
  end

  describe "upload bearer" do
    test "PATCH without Authorization → 401", %{conn: conn, response: r} do
      conn = do_patch(conn, r.id, "cap-A", 0, "hello")
      assert conn.status == 401
    end

    test "PATCH with sid-mismatched bearer → 401", %{conn: conn, response: r} do
      other = Interview.Fixtures.tenant!()
      other_template = Interview.Fixtures.template!(other.id)
      other_version = Interview.Fixtures.version!(other_template.id)
      other_session = Interview.Fixtures.session!(other.id, other_version.id)
      wrong_bearer = Interview.Fixtures.upload_bearer!(other_session)

      conn = do_patch(conn, r.id, "cap-A", 0, "hello", bearer: wrong_bearer)
      assert conn.status == 401
    end

    test "PATCH with garbage bearer → 401", %{conn: conn, response: r} do
      conn = do_patch(conn, r.id, "cap-A", 0, "hello", bearer: "not-a-token")
      assert conn.status == 401
    end

    test "HEAD without Authorization → 401", %{conn: conn, response: r} do
      conn = do_head(conn, r.id, "cap-A")
      assert conn.status == 401
    end
  end
end
