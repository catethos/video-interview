defmodule Interview.Auth.Recruiters.User do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "recruiter_users" do
    field :email, :string
    field :role, :string, default: "owner"
    field :last_seen_at, :utc_datetime_usec

    belongs_to :tenant, Interview.Tenants.Tenant

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:tenant_id, :email, :role, :last_seen_at])
    |> validate_required([:tenant_id, :email])
    |> update_change(:email, &normalize_email/1)
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/)
    |> unique_constraint(:email)
    |> foreign_key_constraint(:tenant_id)
  end

  def normalize_email(nil), do: nil

  def normalize_email(email) when is_binary(email),
    do: email |> String.trim() |> String.downcase()
end
