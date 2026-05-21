defmodule Interview.Workers.PromptAssetCaption do
  @moduledoc """
  Per-`prompt_asset` WebVTT caption generation job. Closes the last
  WCAG item from the candidate-UX overhaul (see
  `docs/candidate-ux-overhaul-plan.md`): deaf candidates need a
  caption track on recruiter-recorded video prompts.

  Enqueued by `Interview.PromptAssets.mark_ready/2` once the
  finalizer has published the canonical artifact. Calls the
  configured `Interview.Transcripts` adapter with
  `response_format=vtt`, writes the .vtt file to local storage at
  the parallel key, and stamps
  `caption_storage_key` / `caption_provider` / `caption_ready_at`.

  Error policy mirrors `Workers.WhisperTranscript`:
    * `:missing_api_key` / `:unauthorized` → permafail.
    * `:rate_limited` / `{:server_error, _, _}` / `{:transport, _}`
      → retry with Oban backoff.

  Idempotency:
    * `caption_ready_at` already set → no-op.
    * Asset state isn't `"ready"` → discard (don't fight the finalizer).
    * Asset kind isn't `"video"` or `"audio"` → no-op (image/PDF
      assets have no audio track to transcribe).
  """
  use Oban.Worker, queue: :transcript, max_attempts: 6

  require Logger

  alias Interview.PromptAssets
  alias Interview.Storage
  alias Interview.Templates.PromptAsset

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"prompt_asset_id" => id}}) do
    case Interview.Repo.get(PromptAsset, id) do
      nil ->
        {:discard, "prompt_asset not found"}

      %PromptAsset{caption_ready_at: t} when not is_nil(t) ->
        :ok

      %PromptAsset{state: state} when state != "ready" ->
        {:discard, "asset not ready (state=#{state})"}

      %PromptAsset{kind: kind} when kind not in ["video", "audio"] ->
        {:discard, "asset kind=#{kind} has no audio to caption"}

      %PromptAsset{storage_key: nil} ->
        {:discard, "no storage_key"}

      %PromptAsset{} = asset ->
        do_caption(asset)
    end
  end

  defp do_caption(%PromptAsset{} = asset) do
    src_path = Storage.artifact_path(asset.storage_key)

    if not File.exists?(src_path) do
      {:discard, "artifact missing: #{src_path}"}
    else
      case Interview.Transcripts.transcribe_vtt(src_path) do
        {:ok, %{vtt: vtt, provider: provider}} ->
          write_and_stamp(asset, vtt, provider)

        {:error, :missing_api_key} ->
          Logger.warning("captions: missing OPENAI_API_KEY; permafailing job")
          {:discard, "missing OPENAI_API_KEY"}

        {:error, :unauthorized} ->
          Logger.warning("captions: OpenAI unauthorized; permafailing job")
          {:discard, "openai unauthorized"}

        {:error, :rate_limited} ->
          {:error, :rate_limited}

        {:error, {:server_error, status, _}} = err ->
          Logger.warning("captions: OpenAI #{status}; retrying")
          err

        {:error, {:transport, _}} = err ->
          err

        {:error, reason} = err ->
          Logger.warning("captions: error #{inspect(reason)}; retrying")
          err
      end
    end
  end

  defp write_and_stamp(%PromptAsset{} = asset, vtt, provider) do
    caption_key = caption_storage_key(asset)
    tmp_path = Path.join(System.tmp_dir!(), "prompt-caption-#{asset.id}.vtt")

    File.write!(tmp_path, vtt)

    try do
      case Storage.put_artifact(caption_key, tmp_path) do
        {:ok, _bytes} ->
          PromptAssets.mark_caption_ready(asset.id, caption_key, provider)

          :telemetry.execute(
            [:interview, :prompt_asset_caption, :ready],
            %{bytes: byte_size(vtt)},
            %{prompt_asset_id: asset.id, provider: provider}
          )

          :ok

        {:error, reason} = err ->
          Logger.warning("captions: put_artifact failed: #{inspect(reason)}")
          err
      end
    after
      _ = File.rm(tmp_path)
    end
  end

  # Parallel to the asset's MP4 key but with a `.vtt` extension.
  defp caption_storage_key(%PromptAsset{} = a) do
    "tenants/#{a.tenant_id}/prompt_assets/#{a.id}.vtt"
  end
end
