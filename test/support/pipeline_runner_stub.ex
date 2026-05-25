defmodule Interview.Scoring.PipelineRunnerStub do
  @moduledoc """
  Process-local stub for the `Interview.Scoring.PipelineRunner` adapter
  (tests only). Mirrors `Interview.TranscriptsStub`: each test pid programmes
  a map of `stage_id => response` and receives a `:pipeline_stage_call`
  message per stage for ordering/threading assertions.
  """

  @behaviour Interview.Scoring.PipelineRunner

  @impl true
  def run_stage(_topology, stage, globals) do
    ensure_table()
    pid = caller_pid()
    send(pid, {:pipeline_stage_call, %{stage_id: stage.id, globals: globals}})

    case :ets.lookup(table(), {:script, pid}) do
      [{_, responses}] -> Map.get(responses, stage.id, default_response())
      _ -> default_response()
    end
  end

  defp default_response, do: {:ok, [%{}]}

  @doc "Programme `stage_id => response` for the calling pid."
  def program(responses) when is_map(responses) do
    ensure_table()
    :ets.insert(table(), {{:script, self()}, responses})
    :ok
  end

  @doc "Clear the calling pid's script."
  def clear do
    ensure_table()
    :ets.delete(table(), {:script, self()})
    :ok
  end

  @doc "Drain `:pipeline_stage_call` payloads from the mailbox, in call order."
  def calls(timeout \\ 0), do: drain([], timeout)

  defp drain(acc, timeout) do
    receive do
      {:pipeline_stage_call, payload} -> drain([payload | acc], timeout)
    after
      timeout -> Enum.reverse(acc)
    end
  end

  defp caller_pid do
    case Process.get(:"$callers") do
      [pid | _] -> pid
      _ -> self()
    end
  end

  defp ensure_table do
    case :ets.whereis(table()) do
      :undefined -> :ets.new(table(), [:named_table, :public, :set])
      _ -> :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp table, do: :interview_scoring_pipeline_runner_stub
end
