defmodule Interview.Capture.Session do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @states ~w(pending in_progress submitted ready failed expired)

  schema "sessions" do
    field :candidate_email, :string
    field :mode, :string, default: "async"
    field :state, :string, default: "pending"
    field :signed_token, :string
    field :expires_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :last_client_seen_at, :utc_datetime_usec
    field :user_agent, :string
    field :browser_name, :string
    field :browser_version, :string
    field :os, :string
    field :sdk_version, :string
    field :bootstrap_jti, :binary_id
    field :bootstrap_consumed_at, :utc_datetime_usec
    field :external_id, :string
    field :deleted_at, :utc_datetime_usec

    belongs_to :tenant, Interview.Tenants.Tenant
    belongs_to :template_version, Interview.Templates.Version
    has_many :responses, Interview.Capture.Response

    timestamps()
  end

  def states, do: @states

  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :tenant_id,
      :template_version_id,
      :candidate_email,
      :mode,
      :state,
      :signed_token,
      :expires_at,
      :completed_at,
      :last_client_seen_at,
      :user_agent,
      :browser_name,
      :browser_version,
      :os,
      :sdk_version,
      :bootstrap_jti,
      :bootstrap_consumed_at,
      :external_id,
      :deleted_at
    ])
    |> validate_required([:tenant_id, :template_version_id])
    |> validate_inclusion(:state, @states)
  end
end
