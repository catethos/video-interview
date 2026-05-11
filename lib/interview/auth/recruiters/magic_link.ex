defmodule Interview.Auth.Recruiters.MagicLink do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "recruiter_magic_links" do
    field :token_hash, :binary
    field :expires_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec
    field :requested_ip, :string

    belongs_to :recruiter_user, Interview.Auth.Recruiters.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:recruiter_user_id, :token_hash, :expires_at, :consumed_at, :requested_ip])
    |> validate_required([:recruiter_user_id, :token_hash, :expires_at])
    |> unique_constraint(:token_hash)
  end
end
