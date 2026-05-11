defmodule Interview.Transcripts.OpenAI do
  @moduledoc """
  OpenAI Whisper transcription adapter (PLAN decision #9).

  POSTs the audio file (we pass the finalised MP4 directly — Whisper
  accepts MP4) to `https://api.openai.com/v1/audio/transcriptions` with
  `model=whisper-1` as a multipart form.

  TLS verification mirrors the webhook adapter — explicit `verify_peer`
  against the system CA bundle plus hostname check.

  Cost (PLAN §12.4): ~$0.006/min. A 5-question × 60s interview ≈
  $0.03/session.

  Rate limits: tier-1 is 50 RPM; tier-5 is 500 RPM. The worker treats
  429 as retryable so backoff naturally drains.
  """

  @behaviour Interview.Transcripts

  @endpoint "https://api.openai.com/v1/audio/transcriptions"
  @model "whisper-1"
  @provider "openai-whisper-1"

  @impl true
  def transcribe(audio_path) when is_binary(audio_path) do
    case api_key() do
      key when is_binary(key) and byte_size(key) > 0 -> do_post(audio_path, key)
      _ -> {:error, :missing_api_key}
    end
  end

  defp do_post(path, api_key) do
    boundary = "----InterviewWhisperBoundary#{System.unique_integer([:positive])}"
    body = multipart_body(path, boundary)

    headers = [
      {~c"Authorization", String.to_charlist("Bearer " <> api_key)},
      {~c"Accept", ~c"application/json"}
    ]

    content_type = String.to_charlist("multipart/form-data; boundary=" <> boundary)
    request = {String.to_charlist(@endpoint), headers, content_type, body}

    http_opts = [
      timeout: 120_000,
      connect_timeout: 5_000,
      autoredirect: false,
      ssl: ssl_opts()
    ]

    _ = Application.ensure_all_started(:inets)
    _ = Application.ensure_all_started(:ssl)

    case :httpc.request(:post, request, http_opts, body_format: :binary) do
      {:ok, {{_v, 200, _r}, _h, resp_body}} ->
        decode_text(resp_body)

      {:ok, {{_v, 401, _r}, _h, _}} ->
        {:error, :unauthorized}

      {:ok, {{_v, 429, _r}, _h, _}} ->
        {:error, :rate_limited}

      {:ok, {{_v, status, _r}, _h, resp_body}} when status >= 500 ->
        {:error, {:server_error, status, preview(resp_body)}}

      {:ok, {{_v, status, _r}, _h, resp_body}} ->
        {:error, {:http_error, status, preview(resp_body)}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp decode_text(resp_body) do
    case Jason.decode(to_string(resp_body)) do
      {:ok, %{"text" => text}} when is_binary(text) ->
        {:ok, %{text: text, provider: @provider}}

      {:ok, decoded} ->
        {:error, {:decode_failed, inspect(decoded) |> String.slice(0, 200)}}

      {:error, _} ->
        {:error, {:decode_failed, preview(resp_body)}}
    end
  end

  defp multipart_body(file_path, boundary) do
    file_bytes = File.read!(file_path)
    filename = Path.basename(file_path)

    dash = "--"
    crlf = "\r\n"

    [
      dash, boundary, crlf,
      "Content-Disposition: form-data; name=\"model\"", crlf, crlf,
      @model, crlf,
      dash, boundary, crlf,
      "Content-Disposition: form-data; name=\"file\"; filename=\"", filename, "\"", crlf,
      "Content-Type: application/octet-stream", crlf, crlf,
      file_bytes, crlf,
      dash, boundary, dash, crlf
    ]
    |> IO.iodata_to_binary()
  end

  defp ssl_opts do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 4,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ],
      versions: [:"tlsv1.2", :"tlsv1.3"]
    ]
  end

  defp api_key do
    Application.get_env(:interview, Interview.Transcripts, [])
    |> Keyword.get(:openai_api_key)
  end

  defp preview(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp preview(body), do: body |> to_string() |> String.slice(0, 200)
end
