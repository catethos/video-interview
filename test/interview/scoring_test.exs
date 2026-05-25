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

  describe "score_session/1" do
    # Stage outputs in the shape the lattice runner returns: per-question
    # stages (p3/p4) carry question_number from ProcessData; leaf scores are
    # JSON strings (decoded on assembly).
    defp program_full_pipeline! do
      PipelineRunnerStub.program(%{
        "p1" =>
          {:ok,
           [
             %{
               "classifications" =>
                 Jason.encode!([
                   %{
                     "question_number" => 1,
                     "question_type" => "behavioral",
                     "target_constructs" => ["Adaptability"]
                   }
                 ])
             }
           ]},
        "p2" =>
          {:ok,
           [
             %{
               "question_evidences" =>
                 Jason.encode!([%{"question_number" => 1, "evidence" => %{"actions" => ["x"]}}])
             }
           ]},
        "p3" =>
          {:ok,
           [
             %{
               "question_number" => 1,
               "clarity_coherence" => Jason.encode!(%{"score" => 4, "justification" => "clear"}),
               "relevance_completeness" =>
                 Jason.encode!(%{"score" => 3, "justification" => "ok"}),
               "support_quality" => Jason.encode!(%{"score" => 3, "justification" => "ok"})
             }
           ]},
        "p4" =>
          {:ok,
           [
             %{
               "question_number" => 1,
               "layer2_scores" =>
                 Jason.encode!(%{
                   "action_effectiveness" => %{"score" => 4, "justification" => "good"}
                 })
             }
           ]},
        "p5" =>
          {:ok,
           [
             %{
               "overall_insights" => Jason.encode!(["solid technical example"]),
               "question_level_evaluation" =>
                 Jason.encode!([%{"question_number" => 1, "overall_scoring_rationale" => "r"}])
             }
           ]}
      })
    end

    test "assembles the full webhook data payload per the contract" do
      tenant = Fixtures.tenant!()

      %{session: session} =
        ready_session_with_transcript!(tenant.id, %{
          job_role: "MT - Data",
          job_description: "Drives data projects."
        })

      program_full_pipeline!()

      assert {:ok, data} = Scoring.score_session(session.id)

      assert data["pipeline_version"] == "smoke_test_Pipeline_2_2026-05-25"
      assert is_binary(data["scored_at"])

      # Job context the scoring ran against — a frozen snapshot from the session.
      assert data["job_context"] == %{
               "role" => "MT - Data",
               "description" => "Drives data projects."
             }

      # P1 classifications, decoded from the JSON-string leaf
      assert data["classifications"] == [
               %{
                 "question_number" => 1,
                 "question_type" => "behavioral",
                 "target_constructs" => ["Adaptability"]
               }
             ]

      outs = data["pipeline_outputs"]

      assert outs["p2"]["question_evidences"] == [
               %{"question_number" => 1, "evidence" => %{"actions" => ["x"]}}
             ]

      # p3/p4 are per-question arrays, each carrying question_number, scores decoded
      assert [%{"question_number" => 1, "clarity_coherence" => %{"score" => 4}}] = outs["p3"]

      assert [
               %{
                 "question_number" => 1,
                 "layer2_scores" => %{"action_effectiveness" => %{"score" => 4}}
               }
             ] =
               outs["p4"]

      assert outs["p5"]["overall_insights"] == ["solid technical example"]

      # transcript mirrors the export (string keys)
      assert [%{"question_number" => 1, "answer_text" => _}] = data["interview_transcript"]

      # cache miss → P1 ran and was cached
      assert PipelineRunnerStub.calls() |> Enum.map(& &1.stage_id) == ~w(p1 p2 p3 p4 p5)

      assert Scoring.get_classification(
               session.template_version_id,
               "smoke_test_Pipeline_2_2026-05-25"
             )
    end

    test "reuses a cached classification instead of re-running P1" do
      tenant = Fixtures.tenant!()
      %{session: session} = ready_session_with_transcript!(tenant.id)

      {:ok, _} =
        Scoring.upsert_classification(%{
          template_version_id: session.template_version_id,
          pipeline_version: Scoring.pipeline_version(),
          provider: "google/gemini-2.5-flash",
          result: %{
            "rows" => [
              %{
                "classifications" =>
                  Jason.encode!([%{"question_number" => 1, "question_type" => "behavioral"}])
              }
            ]
          },
          computed_at: DateTime.utc_now()
        })

      # No p1 programmed — if it ran, the stub default would fire and p1 would
      # appear in calls. It must not.
      PipelineRunnerStub.program(%{
        "p2" => {:ok, [%{"question_evidences" => "[]"}]},
        "p3" => {:ok, [%{"question_number" => 1}]},
        "p4" => {:ok, [%{"question_number" => 1}]},
        "p5" => {:ok, [%{"overall_insights" => "[]", "question_level_evaluation" => "[]"}]}
      })

      assert {:ok, data} = Scoring.score_session(session.id)
      assert data["classification_provider"] == "google/gemini-2.5-flash"

      assert data["classifications"] == [
               %{"question_number" => 1, "question_type" => "behavioral"}
             ]

      assert PipelineRunnerStub.calls() |> Enum.map(& &1.stage_id) == ~w(p2 p3 p4 p5)
    end

    test "returns :not_ready when the session is not finalized" do
      {tenant, _tpl, v} = version!()
      session = Fixtures.session!(tenant.id, v.id, %{state: "in_progress"})
      assert {:error, :not_ready} = Scoring.score_session(session.id)
    end
  end

  defp ready_session_with_transcript!(tenant_id, session_attrs \\ %{}) do
    template = Fixtures.template!(tenant_id, %{name: "Acme SDR"})
    version = Fixtures.version!(template.id, %{version_number: 1})
    q1 = Fixtures.question!(version.id, 1, %{prompt_text: "Tell me about a time…"})
    {:ok, _} = Templates.publish_draft(version)

    session =
      Fixtures.session!(
        tenant_id,
        version.id,
        Map.merge(
          %{state: "ready", completed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)},
          session_attrs
        )
      )

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
