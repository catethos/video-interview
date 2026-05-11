defmodule Interview.WebhookStub do
  @moduledoc """
  Process-local HTTP stub for `Interview.Webhooks.HTTP` (tests only).

  Each test process registers a script of responses + records every POST
  it receives. The stub looks up the calling test pid via
  `$callers` (Oban runs jobs synchronously in `perform_job/2`, which
  preserves caller context) so async tests can each program their own
  expectations.
  """
  @behaviour Interview.Webhooks.HTTP

  @impl true
  def post(url, headers, body) do
    case caller_pid() do
      nil ->
        raise "WebhookStub.post/3 called from a non-test pid (no $callers, no test pid in pdict)"

      pid ->
        do_post(pid, url, headers, body)
    end
  end

  defp do_post(pid, url, headers, body) do
    log = {:webhook_post, %{url: url, headers: Map.new(headers), body: body}}
    send(pid, log)

    case :ets.lookup(table(), {:script, pid}) do
      [{_, [next | rest]}] ->
        :ets.insert(table(), {{:script, pid}, rest})
        next

      _ ->
        {:ok, %{status: 200, headers: [], body: ""}}
    end
  end

  @doc """
  Programmes the stub to return `responses` in order for the calling pid.
  Each entry is one of:

      {:ok, %{status: 200, body: "ok"}}
      {:ok, %{status: 500, body: "boom"}}
      {:error, :timeout}
  """
  def program(responses) when is_list(responses) do
    ensure_table()
    pid = self()
    :ets.insert(table(), {{:script, pid}, responses})
    on_exit_clean(pid)
    :ok
  end

  @doc "Clears any pending responses for the calling pid."
  def clear do
    ensure_table()
    :ets.delete(table(), {:script, self()})
    :ok
  end

  @doc """
  Pulls all `:webhook_post` messages out of the calling pid's mailbox in
  order and returns them as a list.
  """
  def calls(timeout \\ 0) do
    drain([], timeout)
  end

  defp drain(acc, timeout) do
    receive do
      {:webhook_post, _} = m -> drain([m | acc], timeout)
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

  defp on_exit_clean(_pid), do: :ok

  defp table, do: :interview_webhook_stub
end
