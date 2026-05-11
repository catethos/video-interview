defmodule Interview.PlaybackTest do
  use Interview.DataCase, async: false

  alias Interview.Capture
  alias Interview.Fixtures
  alias Interview.Playback

  describe "list_sessions/2" do
    test "returns only sessions for the given tenant" do
      %{tenant: t1, session: s1} =
        Fixtures.graph!(%{session: %{candidate_email: "a@x.com"}})

      %{session: s2} =
        Fixtures.graph!(%{session: %{candidate_email: "should-not-appear@y.com"}})

      ids = Playback.list_sessions(t1.id) |> Enum.map(& &1.session.id)
      assert s1.id in ids
      refute s2.id in ids
    end

    test "filters by state" do
      %{tenant: tenant, session: ready, version: version} =
        Fixtures.graph!(%{session: %{state: "ready"}})

      _other =
        Fixtures.session!(tenant.id, version.id, %{state: "failed"})

      ids =
        Playback.list_sessions(tenant.id, states: ["ready"])
        |> Enum.map(& &1.session.id)

      assert [ready.id] == ids
    end

    test "filters by template_id" do
      %{tenant: tenant, template: template, session: own} = Fixtures.graph!()

      other_template = Fixtures.template!(tenant.id)
      other_version = Fixtures.version!(other_template.id)
      _other_session = Fixtures.session!(tenant.id, other_version.id)

      ids =
        Playback.list_sessions(tenant.id, template_id: template.id)
        |> Enum.map(& &1.session.id)

      assert [own.id] == ids
    end
  end

  describe "get_session/2" do
    test "returns nil for cross-tenant session" do
      %{session: session} = Fixtures.graph!()
      other_tenant = Fixtures.tenant!()

      assert is_nil(Playback.get_session(other_tenant.id, session.id))
    end

    test "groups responses by question and resolves selected_response" do
      %{tenant: tenant, session: session, question: question} = Fixtures.graph!()

      {:ok, response, _} = Capture.claim_instance(session, question, 1, "cap-A")
      response = Fixtures.with_artifact!(response)

      # Mark ready triggers the retake policy → selected_response_id set.
      Capture.mark_ready(response.id, %{
        storage_key: response.storage_key,
        duration_ms: response.duration_ms
      })

      %{questions: [card]} = Playback.get_session(tenant.id, session.id)
      assert card.template_question.id == question.id
      assert length(card.attempts) == 1
      assert card.selected_response.id == response.id
    end
  end

  describe "get_response_for_playback/2" do
    test "returns the response when tenant matches" do
      %{tenant: tenant, session: session, question: question} = Fixtures.graph!()
      {:ok, response, _} = Capture.claim_instance(session, question, 1, "cap-A")

      assert %{id: id} = Playback.get_response_for_playback(tenant.id, response.id)
      assert id == response.id
    end

    test "returns nil for cross-tenant response" do
      %{session: session, question: question} = Fixtures.graph!()
      {:ok, response, _} = Capture.claim_instance(session, question, 1, "cap-A")
      other_tenant = Fixtures.tenant!()

      assert is_nil(Playback.get_response_for_playback(other_tenant.id, response.id))
    end
  end
end
