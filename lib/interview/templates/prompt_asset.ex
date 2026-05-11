defmodule Interview.Templates.PromptAsset do
  @moduledoc """
  Recruiter-authored media attached to a `template_question` (PLAN §3.4
  recruiter prompts).

  State machine mirrors `Interview.Capture.Response`, minus retake/supersede
  semantics — there is no "attempt" concept for recruiter authoring; a
  re-recording creates a new asset and the question is re-pointed in a
  separate step.

      pending → recording → capture_complete → uploading →
        upload_complete → finalizing → ready | failed | abandoned

  Image/PDF attachments skip the recording pipeline and land in `ready`
  directly via `Interview.PromptAssets.create_attachment/2`.

  `capture_instance_id` is the writer token (single-recorder-per-asset
  v1). Any tus PATCH whose `captureInstanceId` does not match the row's
  current value is fenced (HTTP 410).

  ## Retention

  Prompt assets are **kept forever** by default. Unlike `sessions` (which
  expire after `tenants.retention_days`, default 90), prompt assets are
  studio content — they belong to the recruiter, not the candidate, and
  any published template_version that references them is immutable
  (PLAN §3.4). Auto-aging an asset out of storage would silently degrade
  a stable URL the same way `on_delete: :nilify_all` did before
  migration `20260511000002`; the FK is now `RESTRICT` so a referenced
  asset cannot be deleted without first detaching every reference.

  Tenants that need a per-tenant `prompt_asset_retention_days` knob
  (e.g. EU compliance asking for studio-content TTL) can request it —
  the implementation is a tenants-column add + a sweeper that filters
  out anything still referenced by a template_question.
  Not in v1 scope.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @states ~w(pending recording capture_complete uploading upload_complete
            finalizing ready failed abandoned)

  @kinds ~w(video audio image pdf)

  schema "prompt_assets" do
    field :kind, :string
    field :mime_type, :string
    field :storage_key, :string
    field :duration_ms, :integer
    field :bytes, :integer
    field :created_by, :string

    field :state, :string, default: "pending"
    field :capture_instance_id, :string
    field :upload_session_id, :string
    field :bytes_uploaded, :integer, default: 0
    field :expected_total_bytes, :integer
    field :recorder_mime_type, :string
    field :capture_started_at, :utc_datetime_usec
    field :capture_completed_at, :utc_datetime_usec
    field :upload_completed_at, :utc_datetime_usec
    field :finalized_at, :utc_datetime_usec
    field :last_error_code, :string
    field :last_error_message, :string

    belongs_to :tenant, Interview.Tenants.Tenant
    belongs_to :created_by_user, Interview.Auth.Recruiters.User

    timestamps()
  end

  def states, do: @states
  def kinds, do: @kinds

  def changeset(asset, attrs) do
    asset
    |> cast(attrs, [
      :tenant_id,
      :kind,
      :mime_type,
      :storage_key,
      :duration_ms,
      :bytes,
      :created_by,
      :state,
      :capture_instance_id,
      :upload_session_id,
      :bytes_uploaded,
      :expected_total_bytes,
      :recorder_mime_type,
      :capture_started_at,
      :capture_completed_at,
      :upload_completed_at,
      :finalized_at,
      :last_error_code,
      :last_error_message,
      :created_by_user_id
    ])
    |> validate_required([:tenant_id, :kind, :state])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:state, @states)
    |> validate_ready_has_storage_key()
    |> unique_constraint(:upload_session_id)
  end

  defp validate_ready_has_storage_key(changeset) do
    case {get_field(changeset, :state), get_field(changeset, :storage_key)} do
      {"ready", nil} ->
        add_error(changeset, :storage_key, "is required when state is ready")

      {"ready", ""} ->
        add_error(changeset, :storage_key, "is required when state is ready")

      _ ->
        changeset
    end
  end
end
