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
      key when is_binary(key) and byte_size(key) > 0 ->
        do_post(audio_path, key, response_format: "json")

      _ ->
        {:error, :missing_api_key}
    end
  end

  @impl true
  def transcribe_vtt(audio_path) when is_binary(audio_path) do
    case api_key() do
      key when is_binary(key) and byte_size(key) > 0 ->
        do_post(audio_path, key, response_format: "vtt")

      _ ->
        {:error, :missing_api_key}
    end
  end

  defp do_post(path, api_key, opts) do
    response_format = Keyword.fetch!(opts, :response_format)
    boundary = "----InterviewWhisperBoundary#{System.unique_integer([:positive])}"
    body = multipart_body(path, boundary, response_format)

    # When asking for VTT we want plain text back, not JSON, so let the
    # server know via Accept. (OpenAI also honors response_format=vtt
    # and emits text/vtt regardless, but being explicit matches the
    # rest of the request shape.)
    accept =
      case response_format do
        "vtt" -> ~c"text/vtt"
        _ -> ~c"application/json"
      end

    headers = [
      {~c"Authorization", String.to_charlist("Bearer " <> api_key)},
      {~c"Accept", accept}
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
        decode_success(resp_body, response_format)

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

  defp decode_success(resp_body, "json") do
    case Jason.decode(to_string(resp_body)) do
      {:ok, %{"text" => text}} when is_binary(text) ->
        {:ok, %{text: text, provider: @provider}}

      {:ok, decoded} ->
        {:error, {:decode_failed, inspect(decoded) |> String.slice(0, 200)}}

      {:error, _} ->
        {:error, {:decode_failed, preview(resp_body)}}
    end
  end

  defp decode_success(resp_body, "vtt") do
    vtt = to_string(resp_body)

    # Sanity-check that the body actually looks like WebVTT — if Whisper
    # ever silently returned something unexpected (e.g. an HTML error
    # page from a stale proxy), `<track>` would render nothing without
    # any indication of why. The first line of a valid file is "WEBVTT"
    # (optionally followed by a description).
    if String.starts_with?(vtt, "WEBVTT") do
      {:ok, %{vtt: vtt, provider: @provider}}
    else
      {:error, {:decode_failed, preview(vtt)}}
    end
  end

  defp multipart_body(file_path, boundary, response_format) do
    file_bytes = File.read!(file_path)
    filename = Path.basename(file_path)

    dash = "--"
    crlf = "\r\n"

    # Force English transcription. Whisper's auto-detect routinely
    # misroutes Malaysian-/Singaporean-accent English to Bahasa Malaysia
    # / Indonesian because of the prosody. Hardcoded "en" for now;
    # post-demo, expose this per-question on the template so companies
    # doing multilingual assessments can specify the expected answer
    # language per item (and gibberish output then serves as a clear
    # signal the candidate answered in the wrong language).
    [
      dash,
      boundary,
      crlf,
      "Content-Disposition: form-data; name=\"model\"",
      crlf,
      crlf,
      @model,
      crlf,
      dash,
      boundary,
      crlf,
      "Content-Disposition: form-data; name=\"language\"",
      crlf,
      crlf,
      "en",
      crlf,
      dash,
      boundary,
      crlf,
      "Content-Disposition: form-data; name=\"response_format\"",
      crlf,
      crlf,
      response_format,
      crlf,
      dash,
      boundary,
      crlf,
      "Content-Disposition: form-data; name=\"file\"; filename=\"",
      filename,
      "\"",
      crlf,
      "Content-Type: application/octet-stream",
      crlf,
      crlf,
      file_bytes,
      crlf,
      dash,
      boundary,
      dash,
      crlf
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
