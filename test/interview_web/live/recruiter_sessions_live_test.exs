defmodule InterviewWeb.RecruiterSessionsLiveTest do
  use InterviewWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Interview.Fixtures

  setup %{conn: conn} do
    %{tenant: tenant, version: version, session: session} =
      Fixtures.graph!(%{
        session: %{candidate_email: "alice@example.com", state: "ready"}
      })

    recruiter = Fixtures.recruiter!(tenant.id)
    token = Fixtures.recruiter_session_token!(recruiter)
    conn = Plug.Test.init_test_session(conn, %{recruiter_token: token})

    %{conn: conn, tenant: tenant, recruiter: recruiter, version: version, session: session}
  end

  test "lists only this tenant's sessions", %{
    conn: conn,
    tenant: tenant,
    session: session
  } do
    other_tenant = Fixtures.tenant!()
    other_template = Fixtures.template!(other_tenant.id)
    other_version = Fixtures.version!(other_template.id)

    other_session =
      Fixtures.session!(other_tenant.id, other_version.id, %{
        candidate_email: "should-not-show@example.com"
      })

    {:ok, _view, html} = live(conn, ~p"/recruiter/sessions")

    assert html =~ "alice@example.com"
    assert html =~ session.id
    refute html =~ other_session.id
    refute html =~ "should-not-show@example.com"
    assert tenant.id != other_tenant.id
  end

  test "filter by state narrows the list via URL patch", %{
    conn: conn,
    tenant: tenant,
    version: version,
    session: ready_session
  } do
    failed = Fixtures.session!(tenant.id, version.id, %{state: "failed"})

    {:ok, view, _html} = live(conn, ~p"/recruiter/sessions")

    # Both rows visible without filter.
    html = render(view)
    assert html =~ ready_session.id
    assert html =~ failed.id

    # Click "ready" filter — URL patches and only ready row remains.
    view |> element("#state-filter-ready") |> render_click()

    assert_patched(view, ~p"/recruiter/sessions?states=ready")
    html = render(view)
    assert html =~ ready_session.id
    refute html =~ failed.id
  end

  test "delete_session removes the row from the stream and soft-deletes the DB row",
       %{conn: conn, session: session} do
    {:ok, view, _html} = live(conn, ~p"/recruiter/sessions")

    assert render(view) =~ session.id

    view
    |> element(~s|button[phx-click="delete_session"][phx-value-id="#{session.id}"]|)
    |> render_click()

    refute render(view) =~ session.id

    reloaded = Interview.Repo.get!(Interview.Capture.Session, session.id)
    assert reloaded.deleted_at
  end

  test "bulk delete: select two rows, delete selected, both soft-deleted", %{
    conn: conn,
    tenant: tenant,
    version: version,
    session: s1
  } do
    s2 = Fixtures.session!(tenant.id, version.id, %{state: "in_progress"})

    {:ok, view, _html} = live(conn, ~p"/recruiter/sessions")

    # Tick both checkboxes.
    view
    |> element(~s|input[phx-click="toggle_select"][phx-value-id="#{s1.id}"]|)
    |> render_click()

    view
    |> element(~s|input[phx-click="toggle_select"][phx-value-id="#{s2.id}"]|)
    |> render_click()

    # Bulk toolbar shows the count.
    html = render(view)
    assert html =~ "2"
    assert html =~ "selected"

    # Fire bulk delete.
    view |> element(~s|button[phx-click="delete_selected"]|) |> render_click()

    refute render(view) =~ s1.id
    refute render(view) =~ s2.id

    assert Interview.Repo.get!(Interview.Capture.Session, s1.id).deleted_at
    assert Interview.Repo.get!(Interview.Capture.Session, s2.id).deleted_at
  end

  test "without recruiter session redirects to /auth/sign-in" do
    conn = build_conn() |> Plug.Test.init_test_session(%{})

    assert {:error, {:redirect, %{to: "/auth/sign-in"}}} =
             live(conn, ~p"/recruiter/sessions")
  end
end
