defmodule Interview.Workers.AuditPrune do
  @moduledoc """
  Daily cron job that drops `audit_events` older than the configured
  retention window (default: 365 days). PLAN §7 Phase 4 / §8.3.

  Audit-log retention is a separate concern from session-recording
  retention (which is per-tenant `retention_days`). One year is the
  SOC-2 baseline; configurable via:

      config :interview, Interview.Audit, retention_days: 365

  This worker holds no long transactions and does no I/O outside the DB.
  """
  use Oban.Worker, queue: :sweeper, max_attempts: 3

  require Logger

  import Ecto.Query

  alias Interview.Audit.Event
  alias Interview.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    cutoff = DateTime.utc_now() |> DateTime.add(-retention_days() * 86_400, :second)

    {n, _} =
      from(e in Event, where: e.occurred_at < ^cutoff)
      |> Repo.delete_all()

    Logger.info("audit_prune: deleted #{n} events older than #{cutoff}")

    {:ok, %{deleted: n, cutoff: cutoff}}
  end

  defp retention_days do
    Application.get_env(:interview, Interview.Audit, [])
    |> Keyword.get(:retention_days, 365)
  end
end
