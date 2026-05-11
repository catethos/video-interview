defmodule InterviewWeb.Plugs.TenantAuthTest do
  use InterviewWeb.ConnCase, async: true

  alias InterviewWeb.Plugs.TenantAuth
  alias Interview.Fixtures

  test "passes through with a valid api key bearer", %{conn: conn} do
    tenant = Fixtures.tenant!()
    {_key, secret} = Fixtures.api_key!(tenant.id)

    out =
      conn
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> secret)
      |> TenantAuth.call(TenantAuth.init([]))

    refute out.halted
    assert out.assigns.tenant.id == tenant.id
    assert out.assigns.current_recruiter == nil
  end

  test "passes through with a valid recruiter session bearer", %{conn: conn} do
    tenant = Fixtures.tenant!()
    recruiter = Fixtures.recruiter!(tenant.id)
    token = Fixtures.recruiter_session_token!(recruiter)

    out =
      conn
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
      |> TenantAuth.call(TenantAuth.init([]))

    refute out.halted
    assert out.assigns.tenant.id == tenant.id
    assert out.assigns.current_recruiter.id == recruiter.id
  end

  test "401 with no header", %{conn: conn} do
    out = TenantAuth.call(conn, TenantAuth.init([]))
    assert out.halted
    assert out.status == 401
  end

  test "401 with garbage bearer", %{conn: conn} do
    out =
      conn
      |> Plug.Conn.put_req_header("authorization", "Bearer tk_garbage")
      |> TenantAuth.call(TenantAuth.init([]))

    assert out.halted
    assert out.status == 401
  end

  test "401 with revoked api key", %{conn: conn} do
    tenant = Fixtures.tenant!()
    {_key, secret} = Fixtures.api_key!(tenant.id, revoked: true)

    out =
      conn
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> secret)
      |> TenantAuth.call(TenantAuth.init([]))

    assert out.halted
    assert out.status == 401
  end
end
