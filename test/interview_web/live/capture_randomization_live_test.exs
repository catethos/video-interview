defmodule InterviewWeb.CaptureRandomizationLiveTest do
  use InterviewWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Interview.Fixtures
  import Ecto.Query

  alias Interview.Capture
  alias Interview.Capture.SessionQuestion
  alias Interview.Repo

  defp capture_path(session) do
    token = bootstrap_token!(session)
    ~p"/capture/#{session.id}?token=#{token}"
  end

  defp set_display_order!(session, by_question_id) do
    for {qid, ord} <- by_question_id do
      {1, _} =
        Repo.update_all(
          from(sq in SessionQuestion,
            where: sq.session_id == ^session.id and sq.template_question_id == ^qid
          ),
          set: [display_order: ord]
        )
    end
  end

  test "the capture iframe serves questions in the session's display_order", %{conn: conn} do
    %{session: session, questions: [q1, q2, q3]} =
      graph_with_questions!(
        [
          %{prompt_text: "ALPHA", required: true, max_answer_seconds: 60},
          %{prompt_text: "BRAVO", required: true, max_answer_seconds: 60},
          %{prompt_text: "CHARLIE", required: true, max_answer_seconds: 60}
        ],
        version: %{randomize_questions: true}
      )

    # Materialise the rows, then pin a known reversed display order so the
    # assertion doesn't depend on the random shuffle.
    :ok = Capture.ensure_session_questions(session)
    set_display_order!(session, %{q1.id => 3, q2.id => 2, q3.id => 1})

    {:ok, view, _html} = live(conn, capture_path(session))
    questions = :sys.get_state(view.pid).socket.assigns.questions

    # Candidate walks display order (CHARLIE, BRAVO, ALPHA), not template order.
    assert Enum.map(questions, & &1.id) == [q3.id, q2.id, q1.id]
    assert Enum.map(questions, & &1.position) == [3, 2, 1]
  end
end
