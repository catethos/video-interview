defmodule Interview.ExternalIntegration.ReturnTo do
  @moduledoc """
  Validates and assembles redirect URLs for the recruiter deep-link callback
  flow.

  External systems (e.g. Pulsifi) drive a recruiter through VI's
  template-builder by sending them to a VI URL with `?return_to=<url>`. On
  successful save, VI redirects the browser to that URL with the
  newly-created template UUID appended.

  Security:
    * The `return_to` URL's origin (scheme://host:port) must appear in the
      tenant's `allowed_return_origins` whitelist. Empty list = no external
      callbacks allowed (default-safe).
    * The caller may include a `state` query param that we echo back
      unchanged on the redirect — used by the external system to defend
      against CSRF / replay.
    * Path/query/fragment on the inbound `return_to` are preserved; the new
      params we append never overwrite caller params (we use `Map.put_new`
      semantics).
  """

  @type result :: {:ok, URI.t()} | {:error, reason()}
  @type reason ::
          :return_to_required
          | :return_to_malformed
          | :return_to_scheme_disallowed
          | :return_to_host_missing
          | :return_to_origin_not_whitelisted

  @doc """
  Validate that `return_to` is well-formed and its origin is permitted for
  the given tenant. Returns the parsed `URI` so callers can build a
  redirect URL without re-parsing.
  """
  @spec validate(String.t() | nil, [String.t()]) :: result()
  def validate(nil, _whitelist), do: {:error, :return_to_required}
  def validate("", _whitelist), do: {:error, :return_to_required}

  def validate(url, whitelist) when is_binary(url) and is_list(whitelist) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme} = uri} when scheme in ["http", "https"] ->
        validate_host_and_origin(uri, whitelist)

      {:ok, _} ->
        {:error, :return_to_scheme_disallowed}

      {:error, _} ->
        {:error, :return_to_malformed}
    end
  end

  defp validate_host_and_origin(%URI{host: host}, _) when host in [nil, ""],
    do: {:error, :return_to_host_missing}

  defp validate_host_and_origin(%URI{} = uri, whitelist) do
    # Both sides go through the same canonicalisation so default-port
    # variants ("https://x.com" vs "https://x.com:443") compare equal.
    canonical = canonical_origin(uri)
    whitelist_set = whitelist |> Enum.map(&canonicalize_whitelist_entry/1) |> MapSet.new()

    if MapSet.member?(whitelist_set, canonical) do
      {:ok, uri}
    else
      {:error, :return_to_origin_not_whitelisted}
    end
  end

  @doc """
  Build the redirect URL by appending the given params to the validated
  `return_to` URI. Existing query keys on the `return_to` URL are preserved;
  our new params only fill gaps (`put_new` semantics) so a caller-supplied
  `state` survives untouched.
  """
  @spec build_redirect(URI.t(), %{optional(String.t()) => String.t() | nil}) :: String.t()
  def build_redirect(%URI{} = uri, params) when is_map(params) do
    existing = decode_query(uri.query)

    merged =
      params
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.reduce(existing, fn {k, v}, acc -> Map.put_new(acc, k, v) end)

    %{uri | query: URI.encode_query(merged)} |> URI.to_string()
  end

  defp decode_query(nil), do: %{}
  defp decode_query(""), do: %{}
  defp decode_query(q) when is_binary(q), do: URI.decode_query(q)

  # The canonical origin for whitelist comparison: scheme://host[:port].
  # Default ports are normalized out so "https://x.com" matches "https://x.com:443".
  defp canonical_origin(%URI{scheme: scheme, host: host, port: port}) do
    default_port = if scheme == "https", do: 443, else: 80

    if is_nil(port) or port == default_port do
      "#{scheme}://#{host}"
    else
      "#{scheme}://#{host}:#{port}"
    end
  end

  # Whitelist entries may be written with or without an explicit port.
  # Parse and canonicalize so the comparison set matches the URL's form
  # regardless of which way the operator wrote it. A malformed entry can
  # never match anything, so it's effectively ignored.
  defp canonicalize_whitelist_entry(entry) when is_binary(entry) do
    case URI.new(entry) do
      {:ok, %URI{scheme: s, host: h} = uri}
      when s in ["http", "https"] and is_binary(h) and h != "" ->
        canonical_origin(uri)

      _ ->
        # Unmatched sentinel — guaranteed not to equal any canonical origin.
        :__invalid__
    end
  end

  defp canonicalize_whitelist_entry(_), do: :__invalid__
end
