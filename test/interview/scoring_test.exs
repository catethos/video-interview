defmodule Interview.ScoringTest do
  use Interview.DataCase, async: true

  alias Interview.Capture.{Response, SessionQuestion}
  alias Interview.Fixtures
  alias Interview.Scoring
  alias Interview.Scoring.{PipelineRunnerStub, SessionScore, TemplateClassification}
  alias Interview.Templates

  setup do
    PipelineRunnerStub.clear()
    :ok
  end

  defp version! do
    tenant = Fixtures.tenant!()
    template = Fixtures.template!(tenant.id)
    {tenant, template, Fixtures.version!(template.id)}
  end

  describe "pipeline_version/0" do
    test "comes from the committed topology" do
      assert Scoring.pipeline_version() == "smoke_test_Pipeline_2_2026-05-25"
    end
  end

  describe "classification cache" do
    test "get_classification returns nil when absent" do
      {_t, _tpl, v} = version!()
      assert Scoring.get_classification(v.id, Scoring.pipeline_version()) == nil
    end

    test "upsert_classification inserts, then is idempotent on conflict" do
      {_t, _tpl, v} = version!()

      attrs = %{
        template_version_id: v.id,
        pipeline_version: Scoring.pipeline_version(),
        provider: nil,
        result: %{"rows" => [%{"classifications" => "[]"}]},
        computed_at: DateTime.utc_now()
      }

      assert {:ok, c1} = Scoring.upsert_classification(attrs)
      assert {:ok, c2} = Scoring.upsert_classification(attrs)
      assert c1.id == c2.id
      assert Repo.aggregate(TemplateClassification, :count) == 1
    end
  end

  describe "with_classification_lock/2" do
    test "runs the fun inside a transaction and returns its value" do
      {_t, _tpl, v} = version!()
      assert {:ok, :did_it} = Scoring.with_classification_lock(v.id, fn -> :did_it end)
    end
  end

  describe "classify/1" do
    test "runs P1 via the runner and wraps the rows" do
      PipelineRunnerStub.program(%{
        "p1" => {:ok, [%{"classifications" => ~s([{"question_number":1}])}]}
      })

      row = %{
        "template_version_id" => Ecto.UUID.generate(),
        "job_role" => "MT",
        "interview_transcript" => "[]"
      }

      assert {:ok, %{result: %{"rows" => rows}, provider: nil}} = Scoring.classify(row)
      assert rows == [%{"classifications" => ~s([{"question_number":1}])}]
      assert PipelineRunnerStub.calls() |> Enum.map(& &1.stage_id) == ["p1"]
    end

    test "propagates a stage error" do
      PipelineRunnerStub.program(%{"p1" => {:error, {:rate_limited, "429"}}})
      assert {:error, {"p1", {:rate_limited, "429"}}} = Scoring.classify(%{"x" => 1})
    end
  end

  describe "record_score/3 + already_scored?/2" do
    test "records a ready score; already_scored? flips true; idempotent" do
      {tenant, _tpl, v} = version!()
      session = Fixtures.session!(tenant.id, v.id)
      pv = Scoring.pipeline_version()

      refute Scoring.already_scored?(session.id, pv)
      assert {:ok, %SessionScore{status: "ready"}} = Scoring.record_score(session.id, :ready)
      assert Scoring.already_scored?(session.id, pv)

      assert {:ok, _} = Scoring.record_score(session.id, :ready)

      assert Repo.aggregate(from(s in SessionScore, where: s.session_id == ^session.id), :count) ==
               1
    end

    test "records a failed score with an error reason" do
      {tenant, _tpl, v} = version!()
      session = Fixtures.session!(tenant.id, v.id)

      assert {:ok, %SessionScore{status: "failed", error_reason: "rate_limited"}} =
               Scoring.record_score(session.id, :failed, error_reason: "rate_limited")
    end
  end

  describe "eligible_for_scoring?/1" do
    test "true when state ready and every selected response is transcribed" do
      tenant = Fixtures.tenant!()
      %{session: session} = ready_session_with_transcript!(tenant.id)
      assert Scoring.eligible_for_scoring?(session.id)
    end

    test "false for an in_progress session" do
      {tenant, _tpl, v} = version!()
      session = Fixtures.session!(tenant.id, v.id, %{state: "in_progress"})
      refute Scoring.eligible_for_scoring?(session.id)
    end

    test "false for a missing session" do
      refute Scoring.eligible_for_scoring?(Ecto.UUID.generate())
    end
  end

  defp ready_session_with_transcript!(tenant_id) do
    template = Fixtures.template!(tenant_id, %{name: "Acme SDR"})
    version = Fixtures.version!(template.id, %{version_number: 1})
    q1 = Fixtures.question!(version.id, 1, %{prompt_text: "Tell me about a time…"})
    {:ok, _} = Templates.publish_draft(version)

    session =
      Fixtures.session!(tenant_id, version.id, %{
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
        transcript_text: "There was one time…",
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
