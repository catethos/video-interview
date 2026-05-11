defmodule Interview.Transcripts do
  @moduledoc """
  Behaviour + dispatch for speech-to-text providers (PLAN §7 Phase 2 carry,
  decision #9 — OpenAI Whisper API).

  v1 ships one provider (`Interview.Transcripts.OpenAI`). The behaviour
  exists so tests can swap a process-local stub via:

      config :interview, Interview.Transcripts,
        enabled: true,
        adapter: Interview.TranscriptsStub

  Production runtime config:

      config :interview, Interview.Transcripts,
        enabled: true,
        adapter: Interview.Transcripts.OpenAI,
        openai_api_key: System.get_env("OPENAI_API_KEY")

  `enabled: false` (the default) makes `Capture.mark_ready/2` skip the
  transcript enqueue entirely — useful for self-hosted deployments
  without an OpenAI key.
  """

  @callback transcribe(audio_path :: String.t()) ::
              {:ok, %{text: String.t(), provider: String.t()}}
              | {:error, :missing_api_key}
              | {:error, :unauthorized}
              | {:error, :rate_limited}
              | {:error, {:server_error, integer()}}
              | {:error, {:http_error, integer(), String.t()}}
              | {:error, {:transport, term()}}
              | {:error, term()}

  @doc """
  Run transcription via the configured adapter. Returns
  `{:ok, %{text:, provider:}}` or a structured error.
  """
  def transcribe(audio_path) when is_binary(audio_path) do
    impl().transcribe(audio_path)
  end

  @doc "Whether transcripts are turned on (config `enabled: true`)."
  def enabled? do
    config() |> Keyword.get(:enabled, false) == true
  end

  @doc false
  def impl do
    config() |> Keyword.get(:adapter, Interview.Transcripts.OpenAI)
  end

  defp config, do: Application.get_env(:interview, __MODULE__, [])
end
