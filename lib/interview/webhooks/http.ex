defmodule Interview.Webhooks.HTTP do
  @moduledoc """
  Tiny HTTP POST behaviour the webhook worker uses.

  Default implementation is `:httpc` (Erlang/OTP built-in, no extra dep).
  Tests swap in `Interview.Webhooks.HTTP.Stub` via Application config.
  """

  @callback post(url :: String.t(), headers :: list({String.t(), String.t()}), body :: binary()) ::
              {:ok, %{status: pos_integer(), headers: list(), body: binary()}} | {:error, term()}

  def post(url, headers, body) do
    impl().post(url, headers, body)
  end

  def impl do
    Application.get_env(:interview, __MODULE__, [])
    |> Keyword.get(:adapter, Interview.Webhooks.HTTP.Httpc)
  end
end

defmodule Interview.Webhooks.HTTP.Httpc do
  @moduledoc """
  Production adapter for `Interview.Webhooks.HTTP` built on OTP `:httpc`.

  Enforces three Phase-4 hardening invariants (PLAN §7 Phase 4):

    * **TLS peer verification** — explicit `verify: :verify_peer` against
      the system CA bundle, plus hostname check. OTP's default is
      `verify_none`; without this we accept any cert.
    * **SSRF guard** — `Interview.Webhooks.URLPolicy.check_destination/1`
      resolves the host and refuses the request if any resolved IPv4
      address is private / loopback / link-local / CGNAT / cloud-metadata.
      The Tenant changeset rejects obvious bad URLs at write time; this is
      the defence-in-depth layer that catches DNS rebinding and operator
      mistakes.
    * **Response body cap** — we slice the response body to
      `@response_body_cap` (8 KB) before returning so a misbehaving
      receiver can't bloat the `webhook_deliveries.response_body_preview`
      column. The full body is still pulled into memory by `:httpc`; a
      stricter cap requires moving to a streaming client (Finch/Mint) —
      tracked as a Phase-4-P3 follow-up.
  """

  @behaviour Interview.Webhooks.HTTP

  alias Interview.Webhooks.URLPolicy

  @response_body_cap 8 * 1024

  @impl true
  def post(url, headers, body) when is_binary(url) and is_binary(body) do
    with :ok <- URLPolicy.check_destination(url, []) do
      do_post(url, headers, body)
    end
  end

  defp do_post(url, headers, body) do
    _ = Application.ensure_all_started(:inets)
    _ = Application.ensure_all_started(:ssl)

    content_type =
      headers
      |> Enum.find_value(~c"application/json", fn
        {"Content-Type", v} -> String.to_charlist(v)
        _ -> nil
      end)

    request_headers =
      headers
      |> Enum.reject(fn {k, _} -> String.downcase(k) == "content-type" end)
      |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    request = {String.to_charlist(url), request_headers, content_type, body}

    http_opts = [
      timeout: 15_000,
      connect_timeout: 5_000,
      autoredirect: false,
      ssl: ssl_opts(url)
    ]

    opts = [body_format: :binary]

    case :httpc.request(:post, request, http_opts, opts) do
      {:ok, {{_v, status, _r}, resp_headers, resp_body}} ->
        normalised = Enum.map(resp_headers, fn {k, v} -> {to_string(k), to_string(v)} end)
        capped = cap_body(resp_body)
        {:ok, %{status: status, headers: normalised, body: capped}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ssl_opts(url) do
    base = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 4,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ],
      # Disable legacy renegotiation; SNI helps name-based vhost endpoints.
      server_name_indication: sni(url),
      versions: [:"tlsv1.2", :"tlsv1.3"]
    ]

    base
  end

  defp sni(url) do
    case URI.new(url) do
      {:ok, %URI{host: host}} when is_binary(host) -> String.to_charlist(host)
      _ -> :undefined
    end
  end

  defp cap_body(body) when is_binary(body) and byte_size(body) <= @response_body_cap, do: body
  defp cap_body(body) when is_binary(body), do: binary_part(body, 0, @response_body_cap)
  defp cap_body(body), do: to_string(body) |> cap_body()
end
