defmodule InterviewWeb.Plugs.RecruiterAuthTest do
  use InterviewWeb.ConnCase, async: true

  alias InterviewWeb.Plugs.RecruiterAuth
  alias Interview.Fixtures

  setup do
    tenant = Fixtures.tenant!()
    recruiter = Fixtures.recruiter!(tenant.id)
    %{tenant: tenant, recruiter: recruiter}
  end

  test "via session cookie", %{conn: conn, tenant: tenant, recruiter: recruiter} do
    token = Fixtures.recruiter_session_token!(recruiter)

    out =
      conn
      |> Plug.Test.init_test_session(%{recruiter_token: token})
      |> RecruiterAuth.call(RecruiterAuth.init([]))

    refute out.halted
    assert out.assigns.tenant.id == tenant.id
    assert out.assigns.current_recruiter.id == recruiter.id
    assert out.assigns.current_scope.recruiter.id == recruiter.id
  end

  test "via Authorization bearer", %{conn: conn, recruiter: recruiter} do
    token = Fixtures.recruiter_session_token!(recruiter)

    out =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
      |> RecruiterAuth.call(RecruiterAuth.init([]))

    refute out.halted
    assert out.assigns.current_recruiter.id == recruiter.id
  end

  test "JSON request: 401 on miss", %{conn: conn} do
    out =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> RecruiterAuth.call(RecruiterAuth.init([]))

    assert out.halted
    assert out.status == 401
  end

  test "HTML request: redirect to /auth/sign-in on miss", %{conn: conn} do
    out =
      conn
      |> Plug.Test.init_test_session(%{})
      |> RecruiterAuth.call(RecruiterAuth.init([]))

    assert out.halted
    assert out.status == 302
    assert Plug.Conn.get_resp_header(out, "location") == ["/auth/sign-in"]
  end
end
