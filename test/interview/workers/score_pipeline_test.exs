defmodule Interview.Workers.ScorePipelineTest do
  use Interview.DataCase, async: false
  use Oban.Testing, repo: Interview.Repo

  alias Interview.Capture.{Response, SessionQuestion}
  alias Interview.Repo
  alias Interview.Scoring
  alias Interview.Scoring.{PipelineRunnerStub, SessionScore}
  alias Interview.Tenants.Tenant
  alias Interview.Webhooks.Delivery
  alias Interview.Workers.ScorePipeline

  setup do
    PipelineRunnerStub.clear()

    tenant = Interview.Fixtures.tenant!()

    {:ok, tenant} =
      tenant
      |> Tenant.changeset(%{
        webhook_url: "https://example.test/hook",
        webhook_secret: "shh"
      })
      |> Repo.update()

    %{session: session} = ready_session_with_transcript!(tenant.id)
    %{tenant: tenant, session: session}
  end

  defp delivery_for(session_id, event_type) do
    Repo.get_by(Delivery, session_id: session_id, event_type: event_type)
  end

  defp program_ok do
    PipelineRunnerStub.program(%{
      "p1" => {:ok, [%{"classifications" => "[]"}]},
      "p2" => {:ok, [%{"question_evidences" => "[]"}]},
      "p3" => {:ok, [%{"question_number" => 1}]},
      "p4" => {:ok, [%{"question_number" => 1}]},
      "p5" => {:ok, [%{"overall_insights" => "[]", "question_level_evaluation" => "[]"}]}
    })
  end

  test "success: writes session_scores ready + enqueues session.scored", %{session: session} do
    program_ok()

    assert :ok = perform_job(ScorePipeline, %{"session_id" => session.id})

    score = Repo.get_by(SessionScore, session_id: session.id)
    assert score.status == "ready"

    delivery = delivery_for(session.id, "session.scored")
    assert delivery
    assert delivery.payload["data"]["pipeline_version"] == "smoke_test_Pipeline_2_2026-05-25"
  end

  test "idempotent: already-scored session is a no-op", %{session: session} do
    {:ok, _} = Scoring.record_score(session.id, :ready)
    # No stub programmed: if the pipeline ran, the default stub would fire.
    assert :ok = perform_job(ScorePipeline, %{"session_id" => session.id})

    assert PipelineRunnerStub.calls() == []
    refute delivery_for(session.id, "session.scored")
  end

  test "snoozes when the session isn't finalized yet", %{tenant: tenant} do
    {_t, v} = template_version!(tenant.id)
    pending = Interview.Fixtures.session!(tenant.id, v.id, %{state: "in_progress"})

    assert {:snooze, 30} = perform_job(ScorePipeline, %{"session_id" => pending.id})
  end

  test "discards when the session is gone" do
    assert {:discard, _} = perform_job(ScorePipeline, %{"session_id" => Ecto.UUID.generate()})
  end

  test "terminal failure on the final attempt: records failed + fires session.scoring_failed",
       %{session: session} do
    PipelineRunnerStub.program(%{
      "p1" => {:ok, [%{"classifications" => "[]"}]},
      "p2" => {:ok, [%{"question_evidences" => "[]"}]},
      "p3" => {:error, {:rate_limited, "429"}}
    })

    assert :ok =
             perform_job(ScorePipeline, %{"session_id" => session.id},
               attempt: 6,
               max_attempts: 6
             )

    score = Repo.get_by(SessionScore, session_id: session.id)
    assert score.status == "failed"
    assert score.error_reason == "rate_limited"

    delivery = delivery_for(session.id, "session.scoring_failed")
    assert delivery
    assert delivery.payload["data"]["stage"] == "p3"
    assert delivery.payload["data"]["reason"] == "rate_limited"
    assert delivery.payload["data"]["attempts"] == 6
  end

  test "transient failure on a non-final attempt retries (no receipt, no webhook)",
       %{session: session} do
    PipelineRunnerStub.program(%{
      "p1" => {:ok, [%{"classifications" => "[]"}]},
      "p2" => {:ok, [%{"question_evidences" => "[]"}]},
      "p3" => {:error, {:server_error, 500, "boom"}}
    })

    assert {:error, _} =
             perform_job(ScorePipeline, %{"session_id" => session.id},
               attempt: 1,
               max_attempts: 6
             )

    refute Repo.get_by(SessionScore, session_id: session.id)
    refute delivery_for(session.id, "session.scoring_failed")
  end

  defp template_version!(tenant_id) do
    template = Interview.Fixtures.template!(tenant_id)
    {template, Interview.Fixtures.version!(template.id)}
  end

  defp ready_session_with_transcript!(tenant_id) do
    {_template, version} = template_version!(tenant_id)
    q1 = Interview.Fixtures.question!(version.id, 1, %{prompt_text: "Tell me…"})
    {:ok, _} = Interview.Templates.publish_draft(version)

    session =
      Interview.Fixtures.session!(tenant_id, version.id, %{
        state: "ready",
        job_role: "MT - Data",
        job_description: "Drives projects.",
        completed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      })

    now = DateTime.utc_now()

    {:ok, r1} =
      %Response{
        session_id: session.id,
        template_question_id: q1.id,
        attempt_number: 1,
        state: "ready",
        transcript_text: "…",
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

    %{session: session}
  end
end
