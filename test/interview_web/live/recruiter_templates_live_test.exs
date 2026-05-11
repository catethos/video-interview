defmodule InterviewWeb.RecruiterTemplatesLiveTest do
  use InterviewWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Interview.Fixtures
  alias Interview.Templates

  setup %{conn: conn} do
    tenant = Fixtures.tenant!()
    recruiter = Fixtures.recruiter!(tenant.id)
    token = Fixtures.recruiter_session_token!(recruiter)
    conn = Plug.Test.init_test_session(conn, %{recruiter_token: token})

    %{conn: conn, tenant: tenant}
  end

  test "lists templates for the current tenant only", %{conn: conn, tenant: tenant} do
    own = Fixtures.template!(tenant.id, %{name: "Own template"})

    other_tenant = Fixtures.tenant!()
    other = Fixtures.template!(other_tenant.id, %{name: "Other tenant template"})

    {:ok, _view, html} = live(conn, ~p"/recruiter/templates")

    assert html =~ "Own template"
    assert html =~ own.id
    refute html =~ "Other tenant template"
    refute html =~ other.id
  end

  test "shows the empty state when no templates exist", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/recruiter/templates")
    assert html =~ "No templates yet."
  end

  test "create button mints a template and navigates to its editor", %{
    conn: conn,
    tenant: tenant
  } do
    {:ok, view, _html} = live(conn, ~p"/recruiter/templates")

    assert {:error, {:live_redirect, %{to: path}}} =
             render_submit(form(view, "#create-template-form"), %{name: "Brand new"})

    assert path =~ "/recruiter/templates/"

    [created] = Templates.list_templates(tenant.id)
    assert created.name == "Brand new"
    assert path == "/recruiter/templates/#{created.id}"
  end

  test "without recruiter session redirects to /auth/sign-in" do
    conn = build_conn() |> Plug.Test.init_test_session(%{})

    assert {:error, {:redirect, %{to: "/auth/sign-in"}}} =
             live(conn, ~p"/recruiter/templates")
  end
end
