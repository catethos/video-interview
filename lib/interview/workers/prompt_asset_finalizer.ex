defmodule Interview.Workers.PromptAssetFinalizer do
  @moduledoc """
  Finalizer Oban job per `prompt_asset` (PLAN §3.4 recruiter prompts).

  Mirrors `Interview.Workers.Finalizer`, scoped to the recruiter-owned
  prompt-asset writer file:

    1. Claim the asset: `capture_complete` → `finalizing`.
    2. Resolve the writer's bytes via
       `Storage.prompt_asset_writer_path/2`. Use the asset's CURRENT
       `capture_instance_id` — fenced earlier writers are intentionally
       ignored.
    3. Transcode via `Interview.Transcode.transcode/1`.
    4. Probe duration.
    5. Publish to the canonical key
       `tenants/<tenant_id>/prompt_assets/<asset_id>.mp4` via
       `Storage.put_artifact/2`.
    6. `PromptAssets.mark_ready/2`.
    7. Best-effort cleanup of the writer file.

  Errors leave the asset in `finalizing`; Oban backs off and retries up
  to `max_attempts`. A genuinely missing writer file is terminal —
  `PromptAssets.mark_failed/3` lands the row in `failed` so the
  recruiter UI can prompt a re-record.
  """
  use Oban.Worker, queue: :finalize, max_attempts: 5

  require Logger

  alias Interview.PromptAssets
  alias Interview.Storage
  alias Interview.Templates.PromptAsset
  alias Interview.Transcode

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"prompt_asset_id" => asset_id}}) do
    case lookup(asset_id) do
      nil ->
        {:discard, "prompt_asset not found"}

      %PromptAsset{state: state}
      when state in ["ready", "failed", "abandoned"] ->
        Logger.info(
          "prompt_asset_finalizer: #{asset_id} already terminal (#{state}); skipping"
        )

        :ok

      %PromptAsset{} = asset ->
        finalize(asset)
    end
  end

  defp finalize(%PromptAsset{} = asset) do
    {:ok, _} = PromptAssets.mark_finalizing(asset.id) |> ok_or_existing(asset)

    src = Storage.prompt_asset_writer_path(asset.id, asset.capture_instance_id)

    if not File.exists?(src) do
      PromptAssets.mark_failed(asset.id, "no_bytes", "writer file missing: #{src}")
      {:discard, "writer file missing"}
    else
      with {:ok, dst} <- Transcode.transcode(src),
           {:ok, duration_ms} <- Transcode.probe_duration_ms(dst),
           storage_key = artifact_key(asset),
           {:ok, bytes} <- Storage.put_artifact(storage_key, dst),
           :ok <- File.rm(dst) |> ignore_enoent(),
           {:ok, _} <-
             PromptAssets.mark_ready(asset.id, %{
               storage_key: storage_key,
               mime_type: "video/mp4",
               duration_ms: duration_ms,
               bytes: bytes
             }) do
        :ok
      else
        {:error, reason} ->
          Logger.warning("prompt_asset_finalizer: failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp ok_or_existing({:ok, _} = ok, _asset), do: ok
  defp ok_or_existing({:error, :wrong_state}, asset), do: {:ok, asset}
  defp ok_or_existing(other, _asset), do: other

  defp artifact_key(%PromptAsset{} = a) do
    "tenants/#{a.tenant_id}/prompt_assets/#{a.id}.mp4"
  end

  defp ignore_enoent(:ok), do: :ok
  defp ignore_enoent({:error, :enoent}), do: :ok
  defp ignore_enoent({:error, _} = err), do: err

  # `PromptAssets.get/2` is tenant-scoped; this worker doesn't have a
  # tenant id at hand, so reach the row directly.
  defp lookup(asset_id) do
    Interview.Repo.get(PromptAsset, asset_id)
  end
end
