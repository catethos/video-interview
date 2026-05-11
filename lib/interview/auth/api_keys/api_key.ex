defmodule Interview.Auth.ApiKeys.ApiKey do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "tenant_api_keys" do
    field :name, :string
    field :prefix, :string
    field :key_hash, :binary
    field :last_used_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :created_by_id, :binary_id

    belongs_to :tenant, Interview.Tenants.Tenant

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(key, attrs) do
    key
    |> cast(attrs, [
      :tenant_id,
      :name,
      :prefix,
      :key_hash,
      :last_used_at,
      :revoked_at,
      :created_by_id
    ])
    |> validate_required([:tenant_id, :name, :prefix, :key_hash])
    |> unique_constraint(:prefix)
    |> foreign_key_constraint(:tenant_id)
  end
end
