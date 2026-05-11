defmodule Interview.Workers.WhisperTranscript do
  @moduledoc """
  Per-`question_response` Whisper transcription job (PLAN decision #9,
  Phase 2 carry).

  Enqueued by `Interview.Capture.mark_ready/2` once the finalizer's MP4
  artifact has landed and the response has flipped to `ready`. Calls the
  configured `Interview.Transcripts` adapter (OpenAI in prod, stub in
  tests) with the local artifact path and writes
  `transcript_text` / `transcript_provider` / `transcript_ready_at` on
  success.

  Error policy:
    * `:missing_api_key` → permafail (operator action required).
    * `:unauthorized` → permafail (operator action required).
    * `:rate_limited` → retry (Oban backoff).
    * `{:server_error, _, _}` → retry.
    * `{:transport, _}` → retry.
    * Any other `:error` → retry up to `max_attempts`.

  Idempotency: if `transcript_ready_at` is already populated, the job
  no-ops. The audio file is downloaded to a temp path and deleted
  regardless of outcome.
  """
  use Oban.Worker, queue: :transcript, max_attempts: 6

  require Logger

  alias Interview.Capture
  alias Interview.Capture.Response
  alias Interview.Storage

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"response_id" => id}}) do
    case Capture.get_response(id) do
      nil ->
        {:discard, "response not found"}

      %Response{transcript_ready_at: t} when not is_nil(t) ->
        :ok

      %Response{state: state} when state != "ready" ->
        {:discard, "response not ready (state=#{state})"}

      %Response{storage_key: nil} ->
        {:discard, "no storage_key"}

      %Response{} = response ->
        do_transcribe(response)
    end
  end

  defp do_transcribe(%Response{} = response) do
    src_path = Storage.artifact_path(response.storage_key)

    if not File.exists?(src_path) do
      {:discard, "artifact missing: #{src_path}"}
    else
      case Interview.Transcripts.transcribe(src_path) do
        {:ok, %{text: text, provider: provider}} ->
          Capture.set_transcript(response.id, text, provider)

          :telemetry.execute(
            [:interview, :transcript, :ready],
            %{bytes: byte_size(text)},
            %{response_id: response.id, provider: provider}
          )

          :ok

        {:error, :missing_api_key} ->
          Logger.warning("transcript: missing OPENAI_API_KEY; permafailing job")
          {:discard, "missing OPENAI_API_KEY"}

        {:error, :unauthorized} ->
          Logger.warning("transcript: OpenAI unauthorized; permafailing job")
          {:discard, "openai unauthorized"}

        {:error, :rate_limited} ->
          {:error, :rate_limited}

        {:error, {:server_error, status, _}} = err ->
          Logger.warning("transcript: OpenAI #{status}; retrying")
          err

        {:error, {:transport, _}} = err ->
          err

        {:error, reason} = err ->
          Logger.warning("transcript: error #{inspect(reason)}; retrying")
          err
      end
    end
  end
end
