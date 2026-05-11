defmodule Interview.Workers.WebhookDeliveriesPrune do
  @moduledoc """
  Daily cron job that drops `webhook_deliveries` rows older than the
  configured retention window (default: 90 days). PLAN §7 Phase 4.

  All states are eligible after the window. Failed rows are useful for
  debugging but lose value quickly past 90 days, and after the worker's
  ~24 h retry curve they're not going anywhere. Pending / in_flight rows
  that survive the window are stuck on a dead Oban job — pruning them
  with the rest is fine.

  Configurable via:

      config :interview, Interview.Webhooks, deliveries_retention_days: 90
  """
  use Oban.Worker, queue: :sweeper, max_attempts: 3

  require Logger

  import Ecto.Query

  alias Interview.Repo
  alias Interview.Webhooks.Delivery

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    cutoff = DateTime.utc_now() |> DateTime.add(-retention_days() * 86_400, :second)

    {n, _} =
      from(d in Delivery, where: d.inserted_at < ^cutoff)
      |> Repo.delete_all()

    Logger.info("webhook_deliveries_prune: deleted #{n} rows older than #{cutoff}")

    {:ok, %{deleted: n, cutoff: cutoff}}
  end

  defp retention_days do
    Application.get_env(:interview, Interview.Webhooks, [])
    |> Keyword.get(:deliveries_retention_days, 90)
  end
end
