defmodule Interview.Workers.AbandonedPromptAssetSweeper do
  @moduledoc """
  Cron-driven sweeper that marks prompt-asset rows stuck in non-terminal
  states as `abandoned` (PLAN §3.4 recruiter prompts, R6).

  An asset is "stale" if its `inserted_at` is older than
  `:stale_after_seconds` (default 4 hours) and its state is not yet
  terminal (`ready`, `failed`, `abandoned`). We never finalize via
  inference — this sweeper only marks rows abandoned. Re-recording
  creates a brand-new asset row.
  """
  use Oban.Worker, queue: :sweeper, max_attempts: 1

  alias Interview.PromptAssets

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    cutoff = DateTime.add(DateTime.utc_now(), -stale_after_seconds(), :second)

    case PromptAssets.stale_in_flight(cutoff) do
      [] ->
        :ok

      ids ->
        {:ok, n} = PromptAssets.mark_abandoned(ids)
        require Logger
        Logger.info("prompt_asset_sweeper: marked #{n} assets abandoned")
        :ok
    end
  end

  defp stale_after_seconds do
    Application.get_env(:interview, __MODULE__, [])
    |> Keyword.get(:stale_after_seconds, 4 * 60 * 60)
  end
end
