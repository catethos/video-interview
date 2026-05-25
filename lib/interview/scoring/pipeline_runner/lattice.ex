defmodule Interview.Scoring.PipelineRunner.Lattice do
  @moduledoc """
  The production `PipelineRunner` adapter: runs one stage against the real
  lattice runtime (`{:lattice, "0.2.2"}`).

  A **fresh runtime per stage** is deliberate (mirrors pulsifi-demo's
  runner.ts): every stage's `.lat` defines a `GenerateOutput` with a
  different signature, and the runtime registers function defs globally, so
  reusing one runtime across stages would let `map_row` pick the wrong
  overload. A fresh runtime costs ~50ms init — trivial against the LLM call.

  Requires `sql: true` (DuckDB data-processing) and `llm: true` (the
  `GenerateOutput` calls). The provider key is read by lattice from the env
  var named in each `.lat`'s `llm_config` (e.g. `OPENROUTER_API_KEY`).
  """

  @behaviour Interview.Scoring.PipelineRunner

  alias Interview.Scoring.Topology

  @impl true
  def run_stage(%Topology{} = topology, %Topology.Stage{} = stage, globals) do
    path = Topology.lat_path(topology, stage)

    with {:ok, source} <- File.read(path),
         {:ok, runtime} <- Lattice.new(sql: true, llm: true),
         {:ok, _} <- Lattice.eval(runtime, source),
         :ok <- bind_globals(runtime, stage.binds, globals),
         {:ok, rows} <- Lattice.call(runtime, stage.entrypoint, []) do
      {:ok, List.wrap(rows)}
    end
  end

  defp bind_globals(runtime, binds, globals) do
    Enum.reduce_while(binds, :ok, fn %{from: from, as: as}, :ok ->
      case Map.fetch(globals, from) do
        {:ok, value} ->
          Lattice.set_global(runtime, as, value)
          {:cont, :ok}

        :error ->
          {:halt, {:error, {:missing_global, from}}}
      end
    end)
  end
end
