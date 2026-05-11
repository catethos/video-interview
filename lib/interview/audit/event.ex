defmodule Interview.Audit.Event do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "audit_events" do
    field :actor_kind, :string
    field :actor_id, :string
    field :action, :string
    field :subject_kind, :string
    field :subject_id, :string
    field :ip_address, :string
    field :user_agent, :string
    field :metadata, :map, default: %{}
    field :occurred_at, :utc_datetime_usec

    belongs_to :tenant, Interview.Tenants.Tenant

    timestamps(updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :tenant_id,
      :actor_kind,
      :actor_id,
      :action,
      :subject_kind,
      :subject_id,
      :ip_address,
      :user_agent,
      :metadata,
      :occurred_at
    ])
    |> validate_required([:actor_kind, :action, :occurred_at])
  end
end
