defmodule Interview.Capture.SessionQuestionTest do
  use Interview.DataCase, async: true

  alias Interview.Capture.SessionQuestion
  alias Interview.Fixtures

  test "changeset/2 casts display_order" do
    tenant = Fixtures.tenant!()
    template = Fixtures.template!(tenant.id)
    version = Fixtures.version!(template.id)
    q = Fixtures.question!(version.id, 1)
    session = Fixtures.session!(tenant.id, version.id)

    assert {:ok, sq} =
             %SessionQuestion{}
             |> SessionQuestion.changeset(%{
               session_id: session.id,
               template_question_id: q.id,
               position: 1,
               display_order: 3
             })
             |> Repo.insert()

    assert sq.display_order == 3
  end
end
