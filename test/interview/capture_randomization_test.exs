defmodule Interview.CaptureRandomizationTest do
  use Interview.DataCase, async: true

  alias Interview.Capture
  alias Interview.Capture.SessionQuestion
  alias Interview.Fixtures

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
end
