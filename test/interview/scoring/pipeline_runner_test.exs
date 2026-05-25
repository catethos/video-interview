defmodule Interview.Scoring.PipelineRunnerTest do
  # Pure orchestration over a stubbed per-stage runner — no DB, no LLM.
  use ExUnit.Case, async: true

  alias Interview.Scoring.{PipelineRunner, PipelineRunnerStub, Topology}

  setup do
    {:ok, topo} = Topology.load()
    PipelineRunnerStub.clear()
    {:ok, topo: topo}
  end

  defp row, do: %{"custom_id" => "c1", "job_role" => "MT", "interview_transcript" => "[]"}

  test "runs every stage in topological order, keyed by stage id", %{topo: topo} do
    PipelineRunnerStub.program(%{
      "p1" => {:ok, [%{"classifications" => "[]"}]},
      "p2" => {:ok, [%{"question_evidences" => "[]"}]},
      "p3" => {:ok, [%{"clarity_coherence" => %{"score" => 4}}]},
      "p4" => {:ok, [%{"layer2_scores" => %{}}]},
      "p5" => {:ok, [%{"overall_insights" => "[]"}]}
    })

    assert {:ok, result} = PipelineRunner.run_pipeline(topo, row())

    assert result.pipeline_version == "smoke_test_Pipeline_2_2026-05-25"
    assert result.stage_outputs |> Map.keys() |> Enum.sort() == ~w(p1 p2 p3 p4 p5)

    called = PipelineRunnerStub.calls() |> Enum.map(& &1.stage_id)
    assert called == ~w(p1 p2 p3 p4 p5)
  end

  test "serializes a stage's nested output before the next stage binds it", %{topo: topo} do
    PipelineRunnerStub.program(%{
      "p1" => {:ok, [%{}]},
      "p2" =>
        {:ok,
         [
           %{
             "question_evidences" => [
               %{"question_number" => 1, "evidence" => %{"actions" => ["x"]}}
             ]
           }
         ]},
      "p3" => {:ok, [%{}]},
      "p4" => {:ok, [%{}]},
      "p5" => {:ok, [%{}]}
    })

    assert {:ok, _} = PipelineRunner.run_pipeline(topo, row())

    # p3 binds p2_results: it must see the flattened JSON-string form, not
    # the raw nested map (the DuckDB nested-Arrow workaround).
    p3 = PipelineRunnerStub.calls() |> Enum.find(&(&1.stage_id == "p3"))
    assert [%{"question_evidences" => qe}] = p3.globals["p2_results"]
    assert is_binary(qe)
    assert Jason.decode!(qe) == [%{"question_number" => 1, "evidence" => %{"actions" => ["x"]}}]
  end

  test ":prebound skips the supplied stage and threads it (serialized) downstream", %{topo: topo} do
    PipelineRunnerStub.program(%{
      "p2" => {:ok, [%{}]},
      "p3" => {:ok, [%{}]},
      "p4" => {:ok, [%{}]},
      "p5" => {:ok, [%{}]}
    })

    p1_rows = [%{"classifications" => [%{"question_number" => 1}]}]

    assert {:ok, result} =
             PipelineRunner.run_pipeline(topo, row(), prebound: %{"p1_results" => p1_rows})

    calls = PipelineRunnerStub.calls()
    assert Enum.map(calls, & &1.stage_id) == ~w(p2 p3 p4 p5)
    refute Map.has_key?(result.stage_outputs, "p1")

    # p4 binds p1_results — it gets the serialized cached value.
    p4 = Enum.find(calls, &(&1.stage_id == "p4"))
    assert [%{"classifications" => c}] = p4.globals["p1_results"]
    assert Jason.decode!(c) == [%{"question_number" => 1}]
  end

  test ":only runs just the named stages", %{topo: topo} do
    PipelineRunnerStub.program(%{"p1" => {:ok, [%{"classifications" => "[]"}]}})

    assert {:ok, result} = PipelineRunner.run_pipeline(topo, row(), only: ["p1"])

    assert Map.keys(result.stage_outputs) == ["p1"]
    assert PipelineRunnerStub.calls() |> Enum.map(& &1.stage_id) == ["p1"]
  end

  test "halts on the first failing stage and leaves downstream stages unrun", %{topo: topo} do
    PipelineRunnerStub.program(%{
      "p1" => {:ok, [%{}]},
      "p2" => {:error, {:rate_limited, "429"}}
    })

    assert {:error, {"p2", {:rate_limited, "429"}}} = PipelineRunner.run_pipeline(topo, row())

    assert PipelineRunnerStub.calls() |> Enum.map(& &1.stage_id) == ~w(p1 p2)
  end
end
