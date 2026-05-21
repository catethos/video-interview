defmodule InterviewWeb.ScoringExportControllerTest do
  use InterviewWeb.ConnCase, async: true

  alias Interview.Capture.{Response, SessionQuestion}
  alias Interview.Fixtures
  alias Interview.Repo
  alias Interview.Templates

  defp authed_conn(conn, secret) do
    conn
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> secret)
  end

  defp ready_session_with_transcript!(tenant_id) do
    template = Fixtures.template!(tenant_id, %{name: "Acme SDR"})
    version = Fixtures.version!(template.id, %{version_number: 1})
    q1 = Fixtures.question!(version.id, 1, %{prompt_text: "Tell me about a time…"})
    q2 = Fixtures.question!(version.id, 2, %{prompt_text: "How would you handle…"})
    {:ok, _published} = Templates.publish_draft(version)

    session =
      Fixtures.session!(tenant_id, version.id, %{
        candidate_email: "alyazhafira@example.com",
        external_id: "pulsifi:app:abc-123",
        state: "ready",
        completed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      })

    now = DateTime.utc_now()

    {:ok, r1} =
      %Response{
        session_id: session.id,
        template_question_id: q1.id,
        attempt_number: 1,
        state: "ready",
        transcript_text: "There was one time at Everdy Insurance when I…",
        transcript_ready_at: now
      }
      |> Repo.insert()

    {:ok, r2} =
      %Response{
        session_id: session.id,
        template_question_id: q2.id,
        attempt_number: 1,
        state: "ready",
        transcript_text: "I would start by listening to the stakeholder…",
        transcript_ready_at: now
      }
      |> Repo.insert()

    {:ok, _} =
      %SessionQuestion{
        session_id: session.id,
        template_question_id: q1.id,
        position: 1,
        selected_response_id: r1.id
      }
      |> Repo.insert()

    {:ok, _} =
      %SessionQuestion{
        session_id: session.id,
        template_question_id: q2.id,
        position: 2,
        selected_response_id: r2.id
      }
      |> Repo.insert()

    %{
      session: session,
      template: template,
      version: version,
      questions: [q1, q2],
      responses: [r1, r2]
    }
  end

  setup do
    tenant = Fixtures.tenant!()
    {_key, secret} = Fixtures.api_key!(tenant.id)
    %{tenant: tenant, secret: secret}
  end

  describe "GET /api/sessions/:id/scoring_export" do
    test "returns the flat Q+A array for a ready session", %{
      conn: conn,
      tenant: tenant,
      secret: secret
    } do
      %{session: session, questions: [q1, q2], responses: [r1, r2]} =
        ready_session_with_transcript!(tenant.id)

      conn =
        conn
        |> authed_conn(secret)
        |> get(~p"/api/sessions/#{session.id}/scoring_export")

      assert payload = json_response(conn, 200)
      assert payload["session_id"] == session.id
      assert payload["external_id"] == "pulsifi:app:abc-123"
      assert payload["tenant_id"] == tenant.id
      assert payload["candidate_email"] == "alyazhafira@example.com"
      assert payload["state"] == "ready"
      assert is_binary(payload["completed_at"])

      transcript = payload["interview_transcript"]
      assert length(transcript) == 2

      entry1 = Enum.at(transcript, 0)
      assert entry1["question_number"] == 1
      assert entry1["question_text"] == q1.prompt_text
      assert entry1["answer_text"] == r1.transcript_text
      assert entry1["response_id"] == r1.id

      entry2 = Enum.at(transcript, 1)
      assert entry2["question_number"] == 2
      assert entry2["question_text"] == q2.prompt_text
      assert entry2["answer_text"] == r2.transcript_text
      assert entry2["response_id"] == r2.id
    end

    test "answer_text is null when no response was selected for a question", %{
      conn: conn,
      tenant: tenant,
      secret: secret
    } do
      template = Fixtures.template!(tenant.id, %{name: "T"})
      version = Fixtures.version!(template.id, %{version_number: 1})
      q = Fixtures.question!(version.id, 1, %{prompt_text: "?"})
      {:ok, _} = Templates.publish_draft(version)

      session =
        Fixtures.session!(tenant.id, version.id, %{
          state: "ready",
          completed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
        })

      {:ok, _} =
        %SessionQuestion{
          session_id: session.id,
          template_question_id: q.id,
          position: 1,
          selected_response_id: nil
        }
        |> Repo.insert()

      conn = conn |> authed_conn(secret) |> get(~p"/api/sessions/#{session.id}/scoring_export")
      payload = json_response(conn, 200)
      assert [entry] = payload["interview_transcript"]
      assert entry["answer_text"] == nil
    end

    test "returns 404 for a session belonging to a different tenant", %{
      conn: conn,
      secret: secret
    } do
      other = Fixtures.tenant!()
      %{session: session} = ready_session_with_transcript!(other.id)

      conn = conn |> authed_conn(secret) |> get(~p"/api/sessions/#{session.id}/scoring_export")
      assert json_response(conn, 404) == %{"error" => "session_not_found"}
    end

    test "returns 404 for a non-existent session", %{conn: conn, secret: secret} do
      conn =
        conn
        |> authed_conn(secret)
        |> get(~p"/api/sessions/#{Ecto.UUID.generate()}/scoring_export")

      assert json_response(conn, 404) == %{"error" => "session_not_found"}
    end

    test "returns 409 when the session is not yet ready", %{
      conn: conn,
      tenant: tenant,
      secret: secret
    } do
      template = Fixtures.template!(tenant.id)
      version = Fixtures.version!(template.id)
      _q = Fixtures.question!(version.id, 1)
      {:ok, _} = Templates.publish_draft(version)

      session = Fixtures.session!(tenant.id, version.id, %{state: "in_progress"})

      conn = conn |> authed_conn(secret) |> get(~p"/api/sessions/#{session.id}/scoring_export")
      assert resp = json_response(conn, 409)
      assert resp["error"] == "session_not_ready"
      assert is_binary(resp["hint"])
    end

    test "rejects requests without a valid bearer token", %{conn: conn} do
      conn = get(conn, ~p"/api/sessions/#{Ecto.UUID.generate()}/scoring_export")
      # TenantAuth halts the conn — exact body shape depends on the plug;
      # just assert it's a non-2xx.
      assert conn.status in 401..403
    end
  end
end
