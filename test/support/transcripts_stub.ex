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
        do_call(pid, :transcribe, audio_path, default_transcribe_response())
    end
  end

  @impl true
  def transcribe_vtt(audio_path) do
    case caller_pid() do
      nil ->
        raise "TranscriptsStub.transcribe_vtt/1 called from a non-test pid (no $callers, no test pid in pdict)"

      pid ->
        do_call(pid, :transcribe_vtt, audio_path, default_vtt_response())
    end
  end

  defp do_call(pid, op, audio_path, default) do
    send(pid, {op, %{audio_path: audio_path}})
    send(pid, {:transcribe_call, %{audio_path: audio_path, op: op}})

    case :ets.lookup(table(), {:script, pid}) do
      [{_, [next | rest]}] ->
        :ets.insert(table(), {{:script, pid}, rest})
        next

      _ ->
        default
    end
  end

  defp default_transcribe_response,
    do: {:ok, %{text: "stub transcript", provider: "stub"}}

  defp default_vtt_response,
    do:
      {:ok,
       %{
         vtt: "WEBVTT\n\n00:00:00.000 --> 00:00:02.000\nstub caption\n",
         provider: "stub"
       }}

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
