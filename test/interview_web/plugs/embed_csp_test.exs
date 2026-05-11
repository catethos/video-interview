defmodule InterviewWeb.Plugs.EmbedCSPTest do
  use InterviewWeb.ConnCase, async: true

  alias Interview.Fixtures

  defp csp_header(conn) do
    conn |> Plug.Conn.get_resp_header("content-security-policy") |> List.first() || ""
  end

  test "uses tenant.frame_ancestors when session resolves", %{conn: conn} do
    tenant = Fixtures.tenant!(%{frame_ancestors: ["https://customer-a.com"]})
    template = Fixtures.template!(tenant.id)
    version = Fixtures.version!(template.id)
    Fixtures.question!(version.id, 1)
    session = Fixtures.session!(tenant.id, version.id)
    token = Fixtures.bootstrap_token!(session)

    conn = get(conn, ~p"/capture/#{session.id}?token=#{token}")
    csp = csp_header(conn)
    assert csp =~ "frame-ancestors https://customer-a.com"
  end

  test "tenant with no configured ancestors defaults to 'self' (deny external)", %{conn: conn} do
    tenant = Fixtures.tenant!(%{frame_ancestors: []})
    template = Fixtures.template!(tenant.id)
    version = Fixtures.version!(template.id)
    Fixtures.question!(version.id, 1)
    session = Fixtures.session!(tenant.id, version.id)
    token = Fixtures.bootstrap_token!(session)

    conn = get(conn, ~p"/capture/#{session.id}?token=#{token}")
    csp = csp_header(conn)
    assert csp =~ "frame-ancestors 'self'"
    refute csp =~ "https://"
  end

  test "no session: falls back to app-config ancestors", %{conn: conn} do
    bogus = "00000000-0000-0000-0000-000000000000"
    conn = get(conn, ~p"/capture/#{bogus}")
    csp = csp_header(conn)
    assert csp =~ "frame-ancestors"
  end
end
