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
      :branding
    ])
    |> validate_required([:name, :slug])
    |> validate_number(:retention_days, greater_than: 0)
    |> validate_webhook_url()
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

  defp webhook_url_message(:invalid_url), do: "is not a valid URL"
  defp webhook_url_message(:scheme_required), do: "must use https://"
  defp webhook_url_message(:http_disallowed), do: "must use https:// (http:// not allowed)"
  defp webhook_url_message(:host_required), do: "must include a host"
  defp webhook_url_message(:hostname_denied), do: "must not point at an internal hostname"
  defp webhook_url_message(:private_ip_disallowed), do: "must not point at a private IP"
  defp webhook_url_message(other), do: "is not allowed (#{inspect(other)})"
end
