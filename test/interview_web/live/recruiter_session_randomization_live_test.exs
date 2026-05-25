defmodule InterviewWeb.RecruiterSessionRandomizationLiveTest do
  use InterviewWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias Interview.Capture
  alias Interview.Capture.SessionQuestion
  alias Interview.Fixtures
  alias Interview.Repo

  test "debug panel shows the candidate's shown order for a randomized session", %{conn: conn} do
    # slug "dev*" flips on the dev-only debug panel.
    tenant = Fixtures.tenant!(%{slug: "dev-rand-#{System.unique_integer([:positive])}"})
    template = Fixtures.template!(tenant.id)
    version = Fixtures.version!(template.id, %{randomize_questions: true})
    q1 = Fixtures.question!(version.id, 1)
    q2 = Fixtures.question!(version.id, 2)
    q3 = Fixtures.question!(version.id, 3)
    {:ok, _} = Interview.Templates.publish_draft(version)

    session =
      Fixtures.session!(tenant.id, version.id, %{
        state: "ready",
        completed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      })

    :ok = Capture.ensure_session_questions(session)
    # Reversed display order → the candidate saw questions 3, 2, 1.
    for {qid, ord} <- %{q1.id => 3, q2.id => 2, q3.id => 1} do
      {1, _} =
        Repo.update_all(
          from(sq in SessionQuestion,
            where: sq.session_id == ^session.id and sq.template_question_id == ^qid
          ),
          set: [display_order: ord]
        )
    end

    recruiter = Fixtures.recruiter!(tenant.id)
    token = Fixtures.recruiter_session_token!(recruiter)
    conn = Plug.Test.init_test_session(conn, %{recruiter_token: token})

    {:ok, _view, html} = live(conn, ~p"/recruiter/sessions/#{session.id}")

    assert html =~ "Shown order (candidate sequence): 3, 2, 1"
  end
end
