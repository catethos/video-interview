defmodule InterviewWeb.DocsLiveTest do
  use InterviewWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Interview.Fixtures

  setup %{conn: conn} do
    tenant = Fixtures.tenant!()
    recruiter = Fixtures.recruiter!(tenant.id)
    token = Fixtures.recruiter_session_token!(recruiter)
    conn = Plug.Test.init_test_session(conn, %{recruiter_token: token})

    %{conn: conn, tenant: tenant}
  end

  test "renders the tutorial doc with headers and code blocks", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/recruiter/docs")

    assert html =~ "End-to-end tutorial"
    assert html =~ "<h1"
    assert html =~ "<pre"
    assert html =~ "Tutorial" or html =~ "tutorial"
    assert html =~ "Sign in as a recruiter"
  end

  test "renders the tutorial via the slugged route", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/recruiter/docs/tutorial")
    assert html =~ "End-to-end tutorial"
  end

  test "shows a not-found page for an unknown slug", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/recruiter/docs/does-not-exist")
    assert html =~ "Doc not found"
  end

  test "without recruiter session redirects to /auth/sign-in" do
    conn = build_conn() |> Plug.Test.init_test_session(%{})

    assert {:error, {:redirect, %{to: "/auth/sign-in"}}} =
             live(conn, ~p"/recruiter/docs")
  end
end
