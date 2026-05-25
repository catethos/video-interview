defmodule Interview.CaptureRandomizationTest do
  use Interview.DataCase, async: true

  alias Interview.Capture
  alias Interview.Capture.{Response, SessionQuestion}
  alias Interview.ExternalIntegration.ScoringExport
  alias Interview.Fixtures
  alias Interview.Playback

  defp session_with_questions!(randomize, n) do
    tenant = Fixtures.tenant!()
    template = Fixtures.template!(tenant.id)
    version = Fixtures.version!(template.id, %{randomize_questions: randomize})
    for i <- 1..n, do: Fixtures.question!(version.id, i)
    Fixtures.session!(tenant.id, version.id)
  end

  defp session_questions(session) do
    Repo.all(from sq in SessionQuestion, where: sq.session_id == ^session.id)
  end

  describe "ensure_session_questions/1 with randomize off" do
    test "assigns display_order in template order" do
      session = session_with_questions!(false, 3)
      :ok = Capture.ensure_session_questions(session)

      sqs = session_questions(session) |> Enum.sort_by(& &1.position)
      assert Enum.map(sqs, & &1.display_order) == [1, 2, 3]

      qs = Capture.list_questions_in_display_order(session)
      assert Enum.map(qs, & &1.position) == [1, 2, 3]
    end
  end

  describe "ensure_session_questions/1 with randomize on" do
    test "display_order is a permutation of 1..N and covers every question once" do
      session = session_with_questions!(true, 4)
      :ok = Capture.ensure_session_questions(session)

      sqs = session_questions(session)
      assert sqs |> Enum.map(& &1.display_order) |> Enum.sort() == [1, 2, 3, 4]

      qs = Capture.list_questions_in_display_order(session)
      assert length(qs) == 4
      assert qs |> Enum.map(& &1.position) |> Enum.sort() == [1, 2, 3, 4]
    end

    test "list_questions_in_display_order returns questions ordered by display_order" do
      session = session_with_questions!(true, 4)
      :ok = Capture.ensure_session_questions(session)

      expected =
        session_questions(session)
        |> Enum.sort_by(& &1.display_order)
        |> Enum.map(& &1.template_question_id)

      assert Capture.list_questions_in_display_order(session) |> Enum.map(& &1.id) == expected
    end

    test "is frozen — a second ensure does not reshuffle" do
      session = session_with_questions!(true, 5)
      :ok = Capture.ensure_session_questions(session)
      first = session_questions(session) |> Map.new(&{&1.template_question_id, &1.display_order})

      :ok = Capture.ensure_session_questions(session)
      again = session_questions(session) |> Map.new(&{&1.template_question_id, &1.display_order})

      assert again == first
    end
  end

  # The keystone guarantee: a candidate seeing a shuffled order must NOT shift
  # scoring or the recruiter report off canonical template order.
  describe "scoring + report stay canonical for a randomized session" do
    test "ScoringExport and Playback order by template position despite a reversed display_order" do
      tenant = Fixtures.tenant!()
      template = Fixtures.template!(tenant.id)
      version = Fixtures.version!(template.id, %{randomize_questions: true})
      q1 = Fixtures.question!(version.id, 1, %{prompt_text: "first"})
      q2 = Fixtures.question!(version.id, 2, %{prompt_text: "second"})
      q3 = Fixtures.question!(version.id, 3, %{prompt_text: "third"})
      {:ok, _} = Interview.Templates.publish_draft(version)

      session =
        Fixtures.session!(tenant.id, version.id, %{
          state: "ready",
          completed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
        })

      # Candidate's display order is reversed: q3, q2, q1.
      now = DateTime.utc_now()

      [q1, q2, q3]
      |> Enum.with_index(1)
      |> Enum.each(fn {q, pos} ->
        {:ok, r} =
          %Response{
            session_id: session.id,
            template_question_id: q.id,
            attempt_number: 1,
            state: "ready",
            transcript_text: "answer #{pos}",
            transcript_ready_at: now
          }
          |> Repo.insert()

        {:ok, _} =
          %SessionQuestion{
            session_id: session.id,
            template_question_id: q.id,
            position: q.position,
            display_order: 4 - pos,
            selected_response_id: r.id
          }
          |> Repo.insert()
      end)

      # Scoring export: canonical question order regardless of display order.
      {:ok, export} = ScoringExport.build(tenant.id, session.id)
      assert Enum.map(export.interview_transcript, & &1.question_number) == [1, 2, 3]

      assert Enum.map(export.interview_transcript, & &1.answer_text) == [
               "answer 1",
               "answer 2",
               "answer 3"
             ]

      # Recruiter report: canonical too.
      %{questions: cards} = Playback.get_session(tenant.id, session.id)
      assert Enum.map(cards, & &1.template_question.position) == [1, 2, 3]
    end
  end
end
