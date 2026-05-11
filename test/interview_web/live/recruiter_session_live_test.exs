defmodule InterviewWeb.RecruiterSessionLiveTest do
  use InterviewWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  use Oban.Testing, repo: Interview.Repo

  alias Interview.Capture
  alias Interview.Fixtures
  alias Interview.Workers.SessionDeletion

  setup %{conn: conn} do
    %{tenant: tenant, session: session, questions: [q1, q2]} =
      Fixtures.graph_with_questions!(
        [
          %{prompt_text: "Q1 prompt"},
          %{prompt_text: "Q2 prompt"}
        ],
        session: %{candidate_email: "alice@example.com"}
      )

    {:ok, response, _} = Capture.claim_instance(session, q1, 1, "cap-A")
    response = Fixtures.with_artifact!(response)

    {:ok, _ready} =
      Capture.mark_ready(response.id, %{
        storage_key: response.storage_key,
        duration_ms: response.duration_ms
      })

    Capture.ensure_session_questions(session)

    recruiter = Fixtures.recruiter!(tenant.id)
    token = Fixtures.recruiter_session_token!(recruiter)
    conn = Plug.Test.init_test_session(conn, %{recruiter_token: token})

    %{
      conn: conn,
      tenant: tenant,
      session: session,
      response: response,
      q1: q1,
      q2: q2
    }
  end

  test "renders one card per question with a video for the ready response", %{
    conn: conn,
    session: session,
    response: response,
    q1: q1,
    q2: q2
  } do
    {:ok, _view, html} = live(conn, ~p"/recruiter/sessions/#{session.id}")

    assert html =~ "alice@example.com"
    assert html =~ "Q1 prompt"
    assert html =~ "Q2 prompt"

    # The selected response renders a <video> with the playback URL src.
    assert html =~ ~s|src="/recruiter/playback/#{response.id}"|

    # Q2 (no response) shows the empty-state copy and no video tag.
    refute html =~ ~s|data-question-id="#{q2.id}".*<video|
    assert html =~ "No playable response yet."
    assert html =~ q1.id
  end

  test "404s on a session belonging to another tenant", %{conn: conn} do
    other_tenant = Fixtures.tenant!()
    other_template = Fixtures.template!(other_tenant.id)
    other_version = Fixtures.version!(other_template.id)
    other_session = Fixtures.session!(other_tenant.id, other_version.id)

    {:ok, _view, html} = live(conn, ~p"/recruiter/sessions/#{other_session.id}")

    assert html =~ "Session not found"
  end

  test "without recruiter session redirects to /auth/sign-in", %{session: session} do
    conn = build_conn() |> Plug.Test.init_test_session(%{})

    assert {:error, {:redirect, %{to: "/auth/sign-in"}}} =
             live(conn, ~p"/recruiter/sessions/#{session.id}")
  end

  test "delete button soft-deletes the session and enqueues scrub worker", %{
    conn: conn,
    session: session
  } do
    {:ok, view, _html} = live(conn, ~p"/recruiter/sessions/#{session.id}")

    assert {:error, {:live_redirect, %{to: "/recruiter/sessions"}}} =
             view |> element("#delete-session") |> render_click()

    reloaded = Interview.Repo.get!(Interview.Capture.Session, session.id)
    assert reloaded.deleted_at

    assert_enqueued(worker: SessionDeletion, args: %{"session_id" => session.id})
  end

  test "deleted session is hidden from the list and the detail page", %{
    conn: conn,
    session: session
  } do
    {:ok, _del} =
      Capture.soft_delete_session(session.id, %{
        actor_kind: "recruiter",
        actor_id: nil
      })

    # Detail page now 404s.
    {:ok, _view, detail_html} = live(conn, ~p"/recruiter/sessions/#{session.id}")
    assert detail_html =~ "Session not found"

    # Index page no longer lists the row.
    {:ok, _view, list_html} = live(conn, ~p"/recruiter/sessions")
    refute list_html =~ session.id
  end
end
