defmodule Interview.Tenants.Tenant do
  use Ecto.Schema
  import Ecto.Changeset

  alias Interview.Webhooks.URLPolicy

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "tenants" do
    field :name, :string
    field :slug, :string
    field :frame_ancestors, {:array, :string}, default: []
    field :webhook_url, :string
    field :webhook_secret, :string
    field :retention_days, :integer, default: 90
    field :branding, :map, default: %{}
    field :allowed_return_origins, {:array, :string}, default: []

    timestamps()
  end

  def changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [
      :name,
      :slug,
      :frame_ancestors,
      :webhook_url,
      :webhook_secret,
      :retention_days,
      :branding,
      :allowed_return_origins
    ])
    |> validate_required([:name, :slug])
    |> validate_number(:retention_days, greater_than: 0)
    |> validate_webhook_url()
    |> validate_allowed_return_origins()
    |> put_default_webhook_secret()
    |> unique_constraint(:slug)
  end

  @doc """
  Generate a fresh URL-safe webhook secret. 32 random bytes → ~43 chars
  base64url, no padding. Used both for auto-bootstrap on tenant create
  and for the recruiter "rotate secret" action.
  """
  def generate_webhook_secret do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  # Auto-bootstrap a webhook_secret on insert so new tenants never ship
  # with a nil secret (which silently permafails every delivery). On
  # update we leave the existing secret alone unless the caller is
  # explicitly rotating.
  defp put_default_webhook_secret(%Ecto.Changeset{data: %__MODULE__{id: nil}} = cs) do
    case get_field(cs, :webhook_secret) do
      s when is_binary(s) and byte_size(s) > 0 -> cs
      _ -> put_change(cs, :webhook_secret, generate_webhook_secret())
    end
  end

  defp put_default_webhook_secret(cs), do: cs

  defp validate_webhook_url(changeset) do
    validate_change(changeset, :webhook_url, fn :webhook_url, value ->
      case URLPolicy.validate_shape(value, []) do
        :ok -> []
        {:error, reason} -> [webhook_url: webhook_url_message(reason)]
      end
    end)
  end

  # Each entry must be a syntactically valid http(s) origin: scheme + host
  # (+ optional port). Path/query/fragment are rejected — origins only.
  defp validate_allowed_return_origins(changeset) do
    validate_change(changeset, :allowed_return_origins, fn :allowed_return_origins, origins ->
      origins
      |> Enum.flat_map(fn origin ->
        case origin_shape(origin) do
          :ok -> []
          {:error, reason} -> [allowed_return_origins: "#{origin}: #{reason}"]
        end
      end)
    end)
  end

  defp origin_shape(origin) when is_binary(origin) do
    case URI.new(origin) do
      {:ok, %URI{scheme: scheme, host: host, path: path, query: q, fragment: f}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" and
             (is_nil(path) or path == "") and is_nil(q) and is_nil(f) ->
        :ok

      {:ok, _} ->
        {:error, "must be a bare origin (scheme + host [+ port]) with no path/query/fragment"}

      {:error, _} ->
        {:error, "is not a valid URL"}
    end
  end

  defp origin_shape(_), do: {:error, "must be a string"}

  defp webhook_url_message(:invalid_url), do: "is not a valid URL"
  defp webhook_url_message(:scheme_required), do: "must use https://"
  defp webhook_url_message(:http_disallowed), do: "must use https:// (http:// not allowed)"
  defp webhook_url_message(:host_required), do: "must include a host"
  defp webhook_url_message(:hostname_denied), do: "must not point at an internal hostname"
  defp webhook_url_message(:private_ip_disallowed), do: "must not point at a private IP"
  defp webhook_url_message(other), do: "is not allowed (#{inspect(other)})"
end
