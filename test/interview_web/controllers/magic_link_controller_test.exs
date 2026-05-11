defmodule InterviewWeb.MagicLinkControllerTest do
  use InterviewWeb.ConnCase, async: true

  alias Interview.Auth.Recruiters
  alias Interview.Fixtures

  describe "POST /api/auth/magic-links" do
    test "always 202 for known email", %{conn: conn} do
      tenant = Fixtures.tenant!()
      Fixtures.recruiter!(tenant.id, %{email: "rec@example.com"})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/auth/magic-links", Jason.encode!(%{"email" => "rec@example.com"}))

      assert json_response(conn, 202) == %{"status" => "accepted"}
    end

    test "always 202 for unknown email (no enumeration)", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/auth/magic-links", Jason.encode!(%{"email" => "nobody@example.com"}))

      assert json_response(conn, 202) == %{"status" => "accepted"}
    end

    test "always 202 for missing email", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/auth/magic-links", Jason.encode!(%{}))

      assert json_response(conn, 202) == %{"status" => "accepted"}
    end
  end

  describe "GET /auth/magic-link/:token" do
    setup do
      tenant = Fixtures.tenant!()
      user = Fixtures.recruiter!(tenant.id, %{email: "rec@example.com"})
      {:ok, %{token: raw}} = Recruiters.request_magic_link("rec@example.com")
      %{user: user, raw: raw}
    end

    test "consumes + sets cookie + redirects to dashboard", %{conn: conn, raw: raw} do
      conn = get(conn, ~p"/auth/magic-link/#{raw}")
      assert redirected_to(conn) == "/recruiter/templates"
      # session set
      session = Plug.Conn.get_session(conn)
      assert is_binary(Map.get(session, :recruiter_token) || Map.get(session, "recruiter_token"))
    end

    test "double-consume rejected", %{conn: conn, raw: raw} do
      _ = get(conn, ~p"/auth/magic-link/#{raw}")
      conn = get(build_conn(), ~p"/auth/magic-link/#{raw}")
      assert conn.status == 401
    end

    test "garbage rejected", %{conn: conn} do
      conn = get(conn, ~p"/auth/magic-link/garbage")
      assert conn.status == 401
    end
  end
end
