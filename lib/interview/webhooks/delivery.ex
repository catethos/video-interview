defmodule Interview.Webhooks.Delivery do
  @moduledoc """
  Append-only ledger for webhook delivery attempts (PLAN §3.1, §7 Phase 4).

  One row per `(session_id, event_type)`. The Oban worker mutates `state`,
  `attempts`, and `last_*` in place — the row is "append-only" in the sense
  that we never delete it, not that every attempt creates a fresh row.
  Idempotency: `delivered_at` is set once at row creation so retries carry
  a stable value to the receiver.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @states ~w(pending in_flight delivered failed)

  schema "webhook_deliveries" do
    field :event_type, :string
    field :state, :string, default: "pending"
    field :attempts, :integer, default: 0
    field :last_status, :integer
    field :last_error, :string
    field :response_body_preview, :string
    field :payload, :map, default: %{}
    field :delivered_at, :utc_datetime_usec
    field :occurred_at, :utc_datetime_usec

    belongs_to :tenant, Interview.Tenants.Tenant
    belongs_to :session, Interview.Capture.Session

    timestamps()
  end

  def states, do: @states

  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :tenant_id,
      :session_id,
      :event_type,
      :state,
      :attempts,
      :last_status,
      :last_error,
      :response_body_preview,
      :payload,
      :delivered_at,
      :occurred_at
    ])
    |> validate_required([:tenant_id, :event_type, :occurred_at])
    |> validate_inclusion(:state, @states)
  end
end
