defmodule Interview.Workers.Finalizer do
  @moduledoc """
  Finalizer Oban job per `question_response` (PLAN §3.3, §12.3).

  Pipeline:

    1. Claim the response: move from `capture_complete` → `finalizing`.
       Idempotent — `mark_finalizing` only fires the transition once.
    2. Resolve the writer's source bytes:
       `Storage.writer_path(response_id, capture_instance_id)`.
       (We pick the *current* `capture_instance_id` on the row, which is
       what `mark_ready` will reference; bytes from prior, fenced writers
       are intentionally ignored.)
    3. Spawn `ffmpeg` with `nice` so it can't pin the web-tier schedulers
       under burst (PLAN §12.7). `libx264 -preset veryfast -crf 23` is
       the v1 ladder — Phase-0 bench used the same.
    4. Probe duration via `ffprobe`.
    5. Publish the artifact via `Storage.put_artifact/2`.
    6. `Capture.mark_ready/2` — moves the response to `ready` and rolls
       up the session.
    7. Cleanup the writer file (best-effort).

  Errors:
    * If ffmpeg fails, the row is left in `finalizing` and the job retries
      (default Oban backoff). After `max_attempts`, the row is moved to
      `failed` by Oban's discard hook (we read this in `Oban.Worker.timeout`).
  """
  use Oban.Worker, queue: :finalize, max_attempts: 5

  require Logger

  alias Interview.Capture
  alias Interview.Capture.Response
  alias Interview.Storage
  alias Interview.Transcode

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"response_id" => response_id}}) do
    case Capture.get_response(response_id) do
      nil ->
        {:discard, "response not found"}

      %Response{state: state}
      when state in ["ready", "failed", "superseded", "abandoned", "expired"] ->
        Logger.info(
          "finalizer: response #{response_id} already in terminal state #{state}; skipping"
        )

        :ok

      %Response{} = response ->
        finalize(response)
    end
  end

  defp finalize(%Response{} = response) do
    {:ok, _} = Capture.mark_finalizing(response.id) |> ok_or_existing(response)

    src = Storage.writer_path(response.id, response.capture_instance_id)

    if not File.exists?(src) do
      Capture.mark_failed(response.id, "no_bytes", "writer file missing: #{src}")
      Capture.fail_session(response.session_id, "no_bytes")
      {:discard, "writer file missing"}
    else
      with {:ok, dst} <- Transcode.transcode(src),
           {:ok, duration_ms} <- Transcode.probe_duration_ms(dst),
           storage_key = artifact_key(response),
           {:ok, _bytes} <- Storage.put_artifact(storage_key, dst),
           :ok <- File.rm(dst) |> ignore_enoent(),
           {:ok, _} <-
             Capture.mark_ready(response.id, %{
               storage_key: storage_key,
               duration_ms: duration_ms,
               format: "mp4"
             }) do
        :ok
      else
        {:error, reason} ->
          Logger.warning("finalizer: failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp ok_or_existing({:ok, _} = ok, _resp), do: ok
  defp ok_or_existing({:error, :wrong_state}, resp), do: {:ok, resp}
  defp ok_or_existing(other, _resp), do: other

  defp artifact_key(%Response{} = r) do
    "tenants/_/sessions/#{r.session_id}/responses/#{r.id}.mp4"
  end

  defp ignore_enoent(:ok), do: :ok
  defp ignore_enoent({:error, :enoent}), do: :ok
  defp ignore_enoent({:error, _} = err), do: err
end
