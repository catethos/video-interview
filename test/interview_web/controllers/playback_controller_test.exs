defmodule InterviewWeb.PlaybackControllerTest do
  use InterviewWeb.ConnCase, async: false

  alias Interview.Capture
  alias Interview.Fixtures

  defp signed_in(conn, recruiter) do
    token = Fixtures.recruiter_session_token!(recruiter)
    Plug.Test.init_test_session(conn, %{recruiter_token: token})
  end

  defp setup_ready_response(opts \\ []) do
    %{tenant: tenant, session: session, question: question} = Fixtures.graph!()
    recruiter = Fixtures.recruiter!(tenant.id)
    {:ok, response, _} = Capture.claim_instance(session, question, 1, "cap-A")
    response = Fixtures.with_artifact!(response, opts)
    {tenant, recruiter, response}
  end

  test "200 + headers for a ready response", %{conn: conn} do
    {_tenant, recruiter, response} = setup_ready_response()
    conn = signed_in(conn, recruiter)

    res = get(conn, ~p"/recruiter/playback/#{response.id}")

    assert res.status == 200
    assert get_resp_header(res, "content-type") |> Enum.any?(&(&1 =~ "video/mp4"))
    assert ["bytes"] = get_resp_header(res, "accept-ranges")
    assert [_len] = get_resp_header(res, "content-length")
  end

  test "404 when response is not in :ready state", %{conn: conn} do
    %{tenant: tenant, session: session, question: question} = Fixtures.graph!()
    recruiter = Fixtures.recruiter!(tenant.id)
    {:ok, response, _} = Capture.claim_instance(session, question, 1, "cap-A")
    # No artifact written, response stays in `recording`.
    conn = signed_in(conn, recruiter)

    res = get(conn, ~p"/recruiter/playback/#{response.id}")
    assert res.status == 404
  end

  test "404 when response belongs to a different tenant", %{conn: conn} do
    {_tenant, _, response} = setup_ready_response()
    other_tenant = Fixtures.tenant!()
    other_recruiter = Fixtures.recruiter!(other_tenant.id)

    conn = signed_in(conn, other_recruiter)

    res = get(conn, ~p"/recruiter/playback/#{response.id}")
    assert res.status == 404
  end

  test "redirects to sign-in when no recruiter session", %{conn: conn} do
    {_, _, response} = setup_ready_response()

    conn = Plug.Test.init_test_session(conn, %{})
    res = get(conn, ~p"/recruiter/playback/#{response.id}")

    assert res.status in 302..303
    assert ["/auth/sign-in"] = get_resp_header(res, "location")
  end

  test "honours Range: bytes=0-99 with 206 + correct slice", %{conn: conn} do
    body = :binary.copy(<<"x">>, 4096)
    {_tenant, recruiter, response} = setup_ready_response(bytes: body)
    conn = signed_in(conn, recruiter)

    res =
      conn
      |> put_req_header("range", "bytes=0-99")
      |> get(~p"/recruiter/playback/#{response.id}")

    assert res.status == 206
    assert ["bytes 0-99/4096"] = get_resp_header(res, "content-range")
    assert ["100"] = get_resp_header(res, "content-length")
    assert response(res, 206) == binary_part(body, 0, 100)
  end

  test "Range past end returns 416", %{conn: conn} do
    body = :binary.copy(<<"y">>, 100)
    {_tenant, recruiter, response} = setup_ready_response(bytes: body)
    conn = signed_in(conn, recruiter)

    res =
      conn
      |> put_req_header("range", "bytes=200-300")
      |> get(~p"/recruiter/playback/#{response.id}")

    assert res.status == 416
    assert ["bytes */100"] = get_resp_header(res, "content-range")
  end

  test "suffix Range bytes=-50 returns the last 50 bytes", %{conn: conn} do
    body = :binary.copy(<<"z">>, 200)
    {_tenant, recruiter, response} = setup_ready_response(bytes: body)
    conn = signed_in(conn, recruiter)

    res =
      conn
      |> put_req_header("range", "bytes=-50")
      |> get(~p"/recruiter/playback/#{response.id}")

    assert res.status == 206
    assert ["bytes 150-199/200"] = get_resp_header(res, "content-range")
    assert ["50"] = get_resp_header(res, "content-length")
  end
end
