defmodule Interview.Workers.AbandonedSessionSweeper do
  @moduledoc """
  Cron-driven sweeper that marks responses on stale sessions as
  `abandoned` (PLAN §3.2 state machine).

  A session is "stale" if its `last_client_seen_at` is older than
  `:stale_after_seconds` (default 4 hours) and any of its responses are
  in a non-terminal state. We never finalize via inference (PLAN §5.1),
  so this only marks rows abandoned — it does not trigger a finalizer.
  """
  use Oban.Worker, queue: :sweeper, max_attempts: 1

  alias Interview.Capture

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    cutoff = DateTime.add(DateTime.utc_now(), -stale_after_seconds(), :second)

    case Capture.stale_responses(cutoff) do
      [] ->
        :ok

      ids ->
        {:ok, n} = Capture.mark_abandoned(ids)
        require Logger
        Logger.info("sweeper: marked #{n} responses abandoned")
        :ok
    end
  end

  defp stale_after_seconds do
    Application.get_env(:interview, __MODULE__, [])
    |> Keyword.get(:stale_after_seconds, 4 * 60 * 60)
  end
end
