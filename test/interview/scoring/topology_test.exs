defmodule Interview.Scoring.TopologyTest do
  use ExUnit.Case, async: true

  alias Interview.Scoring.Topology

  describe "load/0 (the real committed topology.json)" do
    test "parses pipeline_version, bundle_path, and the five stages in order" do
      assert {:ok, topo} = Topology.load()

      assert topo.pipeline_version == "smoke_test_Pipeline_2_2026-05-25"
      assert topo.bundle_path == "smoke_test_Pipeline_2_2026-05-25-0423"
      assert Enum.map(topo.stages, & &1.id) == ~w(p1 p2 p3 p4 p5)
      assert Enum.all?(topo.stages, &(&1.entrypoint == "RunBatch"))
    end

    test "resolves bare binds and from:as binds" do
      {:ok, topo} = Topology.load()
      by_id = Map.new(topo.stages, &{&1.id, &1})

      assert by_id["p1"].binds == [%{from: "input_data", as: "input_data"}]

      # P5 reads P4's exploded per-question rows AS input_data, plus P3's output.
      assert by_id["p5"].binds == [
               %{from: "p4_results", as: "input_data"},
               %{from: "p3_results", as: "p3_results"}
             ]
    end

    test "every stage's lat_path points at a file that exists on disk" do
      {:ok, topo} = Topology.load()

      for stage <- topo.stages do
        path = Topology.lat_path(topo, stage)
        assert File.exists?(path), "missing .lat for #{stage.id}: #{path}"
      end
    end
  end

  describe "from_map/1 DAG validation" do
    defp base_stage(id, binds, output_label) do
      %{
        "id" => id,
        "lat" => "stages/#{id}.lat",
        "binds" => binds,
        "output_label" => output_label,
        "entrypoint" => "RunBatch"
      }
    end

    test "accepts a topology where every bind is produced upstream" do
      map = %{
        "pipeline_version" => "v1",
        "bundle_path" => "b",
        "stages" => [
          base_stage("p1", ["input_data"], "p1_results"),
          base_stage("p2", ["input_data", "p1_results"], "p2_results")
        ]
      }

      assert {:ok, %Topology{}} = Topology.from_map(map)
    end

    test "rejects a stage that binds a label no upstream stage produces" do
      map = %{
        "pipeline_version" => "v1",
        "bundle_path" => "b",
        "stages" => [
          base_stage("p1", ["input_data"], "p1_results"),
          base_stage("p2", ["ghost_results"], "p2_results")
        ]
      }

      assert {:error, {:unsatisfied_bind, "p2", "ghost_results"}} = Topology.from_map(map)
    end

    test "rejects stages listed out of topological order" do
      # p2 needs p3_results, but p3 is declared later.
      map = %{
        "pipeline_version" => "v1",
        "bundle_path" => "b",
        "stages" => [
          base_stage("p2", ["p3_results"], "p2_results"),
          base_stage("p3", ["input_data"], "p3_results")
        ]
      }

      assert {:error, {:unsatisfied_bind, "p2", "p3_results"}} = Topology.from_map(map)
    end
  end
end
