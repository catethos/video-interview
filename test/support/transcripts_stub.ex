defmodule Interview.TranscriptsStub do
  @moduledoc """
  Process-local stub for `Interview.Transcripts` (tests only). Mirrors
  the `Interview.WebhookStub` pattern: each test pid programmes a script
  of return values + receives a `:transcribe_call` message for assertions.
  """

  @behaviour Interview.Transcripts

  @impl true
  def transcribe(audio_path) do
    case caller_pid() do
      nil ->
        raise "TranscriptsStub.transcribe/1 called from a non-test pid (no $callers, no test pid in pdict)"

      pid ->
        do_transcribe(pid, audio_path)
    end
  end

  defp do_transcribe(pid, audio_path) do
    send(pid, {:transcribe_call, %{audio_path: audio_path}})

    case :ets.lookup(table(), {:script, pid}) do
      [{_, [next | rest]}] ->
        :ets.insert(table(), {{:script, pid}, rest})
        next

      _ ->
        {:ok, %{text: "stub transcript", provider: "stub"}}
    end
  end

  @doc """
  Programme the stub to return `responses` in order for the calling pid.
  Each entry must match the `Interview.Transcripts` behaviour return type.
  """
  def program(responses) when is_list(responses) do
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

  @doc "Drain all :transcribe_call messages from the calling pid's mailbox."
  def calls(timeout \\ 0), do: drain([], timeout)

  defp drain(acc, timeout) do
    receive do
      {:transcribe_call, _} = m -> drain([m | acc], timeout)
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
  end

  defp table, do: :interview_transcripts_stub
end
