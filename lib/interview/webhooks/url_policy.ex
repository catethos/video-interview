defmodule Interview.Webhooks.URLPolicy do
  @moduledoc """
  Validates that a tenant-supplied `webhook_url` is safe to POST to
  (PLAN §7 Phase 4 — SSRF guard).

  Two layers:

    * `validate_shape/2` — used in the `Tenants.Tenant` changeset to reject
      obviously bad URLs at write time. Parseable? `https` (or `http` when
      `allow_http?`)? Hostname not in the denylist? IP-literal not in a
      private range?
    * `check_destination/2` — called from the HTTP adapter immediately
      before the request. Resolves the host and rejects when any resolved
      IPv4 address is in a private / loopback / link-local / CGNAT /
      cloud-metadata range. Defence-in-depth: a hostname that passes
      shape validation can still resolve to a private IP (DNS rebinding,
      misconfigured public DNS).

  Both layers can be relaxed in dev/test via app config:

      config :interview, Interview.Webhooks,
        allow_http_urls: true,
        allow_private_destinations: true

  Production keeps both `false`.
  """

  import Bitwise, only: [band: 2]

  @denied_hostname_suffixes ~w(.localhost .internal .local .lan .home .corp .intranet)
  @denied_hostnames ~w(localhost ip6-localhost ip6-loopback)

  @type opts :: [allow_http?: boolean(), allow_private?: boolean()]

  @doc """
  Validate `url` shape. Returns `:ok | {:error, reason :: atom()}`.

  `nil` and blank strings are treated as "no webhook configured" and pass —
  the caller (`Tenant.changeset/2`) decides whether `webhook_url` is
  required at all.
  """
  @spec validate_shape(nil | String.t(), opts()) :: :ok | {:error, atom()}
  def validate_shape(nil, _opts), do: :ok
  def validate_shape("", _opts), do: :ok

  def validate_shape(url, opts) when is_binary(url) do
    allow_http? = Keyword.get(opts, :allow_http?, default_allow_http?())
    allow_private? = Keyword.get(opts, :allow_private?, default_allow_private?())

    with {:ok, uri} <- parse(url),
         :ok <- validate_scheme(uri, allow_http?),
         :ok <- validate_host_present(uri),
         :ok <- validate_hostname_denylist(uri.host, allow_private?),
         :ok <- validate_ip_literal(uri.host, allow_private?) do
      :ok
    end
  end

  def validate_shape(_, _), do: {:error, :invalid_url}

  @doc """
  Resolve `url`'s host and refuse the request if any resolved IPv4 address
  is in a non-public range. Returns `:ok | {:error, reason}`. Skipped when
  `allow_private?` is true (dev/test).

  IPv6 resolution is currently ignored — we only resolve A records and
  reject on that basis. Adding AAAA filtering is straightforward; deferred
  until we have a customer hitting an IPv6-only endpoint.
  """
  @spec check_destination(String.t(), opts()) :: :ok | {:error, atom()}
  def check_destination(url, opts \\ []) when is_binary(url) do
    allow_private? = Keyword.get(opts, :allow_private?, default_allow_private?())

    if allow_private? do
      :ok
    else
      with {:ok, %URI{host: host}} <- parse(url),
           :ok <- check_host_ips(host) do
        :ok
      end
    end
  end

  @doc false
  def default_allow_http?, do: webhooks_config()[:allow_http_urls] == true

  @doc false
  def default_allow_private?, do: webhooks_config()[:allow_private_destinations] == true

  defp webhooks_config, do: Application.get_env(:interview, Interview.Webhooks, [])

  defp parse(url) do
    case URI.new(url) do
      {:ok, uri} -> {:ok, uri}
      {:error, _} -> {:error, :invalid_url}
    end
  end

  defp validate_scheme(%URI{scheme: "https"}, _allow_http?), do: :ok
  defp validate_scheme(%URI{scheme: "http"}, true), do: :ok
  defp validate_scheme(%URI{scheme: "http"}, false), do: {:error, :http_disallowed}
  defp validate_scheme(_, _), do: {:error, :scheme_required}

  defp validate_host_present(%URI{host: nil}), do: {:error, :host_required}
  defp validate_host_present(%URI{host: ""}), do: {:error, :host_required}
  defp validate_host_present(_), do: :ok

  defp validate_hostname_denylist(_host, true), do: :ok

  defp validate_hostname_denylist(host, false) do
    host = String.downcase(host)

    cond do
      host in @denied_hostnames ->
        {:error, :hostname_denied}

      Enum.any?(@denied_hostname_suffixes, &String.ends_with?(host, &1)) ->
        {:error, :hostname_denied}

      true ->
        :ok
    end
  end

  defp validate_ip_literal(host, allow_private?) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} ->
        if allow_private? or public_ip?(ip) do
          :ok
        else
          {:error, :private_ip_disallowed}
        end

      {:error, _} ->
        # Not an IP literal — fine; we'll check resolved IPs in
        # check_destination/2 at request time.
        :ok
    end
  end

  defp check_host_ips(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} ->
        if public_ip?(ip), do: :ok, else: {:error, :private_ip_disallowed}

      {:error, _} ->
        resolve_and_check(host)
    end
  end

  defp resolve_and_check(host) do
    case :inet.getaddrs(String.to_charlist(host), :inet) do
      {:ok, []} ->
        {:error, :dns_no_records}

      {:ok, addrs} ->
        if Enum.all?(addrs, &public_ip?/1) do
          :ok
        else
          {:error, :private_ip_disallowed}
        end

      {:error, reason} ->
        {:error, {:dns_lookup_failed, reason}}
    end
  end

  # IPv4 ranges to reject. The list mirrors the SSRF-cheatsheet defaults plus
  # cloud-metadata 169.254.169.254 (covered by 169.254/16 link-local).
  defp public_ip?({0, _, _, _}), do: false
  defp public_ip?({10, _, _, _}), do: false
  defp public_ip?({127, _, _, _}), do: false
  defp public_ip?({169, 254, _, _}), do: false
  defp public_ip?({172, b, _, _}) when b in 16..31, do: false
  defp public_ip?({192, 0, 0, _}), do: false
  defp public_ip?({192, 0, 2, _}), do: false
  defp public_ip?({192, 168, _, _}), do: false
  defp public_ip?({198, 18, _, _}), do: false
  defp public_ip?({198, 19, _, _}), do: false
  defp public_ip?({198, 51, 100, _}), do: false
  defp public_ip?({203, 0, 113, _}), do: false
  defp public_ip?({100, b, _, _}) when b in 64..127, do: false
  defp public_ip?({a, _, _, _}) when a >= 224, do: false
  defp public_ip?({_, _, _, _}), do: true
  # IPv6: be conservative — reject loopback, link-local, ULA. We only
  # actively resolve IPv4 today; this matches if a literal slips through.
  defp public_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: false
  defp public_ip?({a, _, _, _, _, _, _, _}) when band(a, 0xFE00) == 0xFC00, do: false
  defp public_ip?({a, _, _, _, _, _, _, _}) when band(a, 0xFFC0) == 0xFE80, do: false
  defp public_ip?({_, _, _, _, _, _, _, _}), do: true
end
