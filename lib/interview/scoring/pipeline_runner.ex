defmodule Interview.Scoring.PipelineRunner do
  @moduledoc """
  Runs the scoring pipeline for one candidate (PLAN — scoring-integration-
  plan.md §"Lattice runner"). Elixir port of pulsifi-demo's
  `scoring/runner.ts`.

  The only part that touches the lattice runtime (and therefore the LLM) is
  `run_stage/3`, which is a swappable adapter — the real
  `PipelineRunner.Lattice` in production, a process-local stub in tests:

      config :interview, Interview.Scoring.PipelineRunner,
        adapter: Interview.Scoring.PipelineRunnerStub

  Everything else here — execution order, threading each stage's output to
  the next, the flatten-to-JSON-string step between stages, skipping
  already-computed (cached) stages — is plain orchestration over that seam,
  so it is fully unit-tested without spending an LLM call.
  """

  alias Interview.Scoring.Topology

  @callback run_stage(Topology.t(), Topology.Stage.t(), globals :: map()) ::
              {:ok, [map()]} | {:error, term()}

  @doc "Run a single stage via the configured adapter."
  @spec run_stage(Topology.t(), Topology.Stage.t(), map()) :: {:ok, [map()]} | {:error, term()}
  def run_stage(%Topology{} = topology, stage, globals) do
    impl().run_stage(topology, stage, globals)
  end

  @doc """
  Run the pipeline for one input row, threading each stage's output to the
  next under its `output_label`.

  Options:

    * `:prebound` — `%{output_label => raw_rows}` of stage outputs already
      computed (e.g. the cached P1 result). Those stages are skipped and
      their value is bound (serialized) for downstream stages.
    * `:only` — run only these stage ids (e.g. `["p1"]` to compute P1 alone).

  Returns `{:ok, %{stage_outputs: %{stage_id => rows}, pipeline_version}}`
  or `{:error, {failing_stage_id, reason}}` — the first failing stage halts
  the run and downstream stages are not executed.
  """
  @spec run_pipeline(Topology.t(), map(), keyword()) ::
          {:ok, %{stage_outputs: %{String.t() => [map()]}, pipeline_version: String.t()}}
          | {:error, {String.t(), term()}}
  def run_pipeline(%Topology{} = topology, input_row, opts \\ []) do
    prebound = Keyword.get(opts, :prebound, %{})
    only = Keyword.get(opts, :only)

    globals =
      Enum.reduce(prebound, %{"input_data" => [input_row]}, fn {label, rows}, acc ->
        Map.put(acc, label, serialize_rows(rows))
      end)

    topology.stages
    |> Enum.reject(&Map.has_key?(globals, &1.output_label))
    |> filter_only(only)
    |> run_stages(topology, globals, %{})
  end

  defp filter_only(stages, nil), do: stages
  defp filter_only(stages, only), do: Enum.filter(stages, &(&1.id in only))

  defp run_stages(stages, topology, globals, outputs) do
    Enum.reduce_while(stages, {globals, outputs}, fn stage, {globals, outputs} ->
      case run_stage(topology, stage, globals) do
        {:ok, rows} ->
          globals = Map.put(globals, stage.output_label, serialize_rows(rows))
          {:cont, {globals, Map.put(outputs, stage.id, rows)}}

        {:error, reason} ->
          {:halt, {:error, {stage.id, reason}}}
      end
    end)
    |> case do
      {:error, _} = error ->
        error

      {_globals, outputs} ->
        {:ok, %{stage_outputs: outputs, pipeline_version: topology.pipeline_version}}
    end
  end

  @doc false
  def impl,
    do:
      Application.get_env(:interview, __MODULE__, []) |> Keyword.get(:adapter, __MODULE__.Lattice)

  @doc """
  Flatten a stage's output rows for the next stage to ingest.

  Each downstream stage loads the previous output as a DuckDB table via SQL,
  and DuckDB's Arrow ingestion rejects nested List/Struct columns. So nested
  cells become JSON strings (the `.lat` SQL casts them back out, e.g.
  `CAST(p2.question_evidences AS JSON[])`), and `null` cells are dropped so
  Arrow can infer a column type from non-null neighbours.
  """
  @spec serialize_rows(term()) :: term()
  def serialize_rows(rows) when is_list(rows), do: Enum.map(rows, &serialize_row/1)
  def serialize_rows(other), do: other

  defp serialize_row(row) when is_map(row) do
    for {k, v} <- row, v not in [nil, :null], into: %{}, do: {k, serialize_value(v)}
  end

  defp serialize_row(row), do: row

  defp serialize_value(v) when is_binary(v) or is_integer(v) or is_float(v) or is_boolean(v),
    do: v

  defp serialize_value(v), do: Jason.encode!(v)
end
