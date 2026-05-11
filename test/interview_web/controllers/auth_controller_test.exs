defmodule InterviewWeb.AuthControllerTest do
  use InterviewWeb.ConnCase, async: true

  alias Interview.Auth.Tokens
  alias Interview.Fixtures

  test "GET /auth/sign-in renders form", %{conn: conn} do
    conn = get(conn, ~p"/auth/sign-in")
    assert conn.status == 200
    assert conn.resp_body =~ "Send the link"
  end

  test "POST /api/auth/refresh requires recruiter; rotates token", %{conn: conn} do
    tenant = Fixtures.tenant!()
    recruiter = Fixtures.recruiter!(tenant.id)
    token = Fixtures.recruiter_session_token!(recruiter)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)
      |> post(~p"/api/auth/refresh", "{}")

    assert %{"token" => returned, "expires_in" => _} = json_response(conn, 200)
    assert {:ok, %{rid: rid}} = Tokens.verify_recruiter_session(returned)
    assert rid == recruiter.id
  end

  test "POST /api/auth/refresh 401 without auth", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json")
      |> post(~p"/api/auth/refresh", "{}")

    assert json_response(conn, 401)
  end

  test "DELETE /auth/sign-out drops the session and redirects", %{conn: conn} do
    tenant = Fixtures.tenant!()
    recruiter = Fixtures.recruiter!(tenant.id)
    token = Fixtures.recruiter_session_token!(recruiter)

    conn =
      conn
      |> Plug.Test.init_test_session(%{recruiter_token: token})
      |> delete(~p"/auth/sign-out")

    assert redirected_to(conn) == "/auth/sign-in"
    assert Plug.Conn.get_session(conn, :recruiter_token) == nil
  end
end
