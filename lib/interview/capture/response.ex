defmodule Interview.Capture.Response do
  @moduledoc """
  One row per (session, question, attempt). PLAN §3.2.

  State machine (PLAN §3.2):
    pending → recording → capture_complete → uploading → upload_complete →
    finalizing → ready | failed_retryable | failed | superseded |
    abandoned | expired

  v1 fencing: `capture_instance_id` is the writer token. Any tus PATCH
  whose `captureInstanceId` does not match the row's current value is
  rejected (HTTP 410). Updates to the writer token go through a single
  `Interview.Capture.claim_instance/3` call inside a transaction so the
  "fence on supersede" semantics are atomic.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @states ~w(pending recording capture_complete uploading upload_complete
            finalizing ready failed_retryable failed superseded abandoned expired)

  schema "question_responses" do
    field :attempt_number, :integer, default: 1
    field :state, :string, default: "pending"
    field :storage_key, :string
    field :duration_ms, :integer
    field :format, :string
    field :recorder_mime_type, :string
    field :capture_instance_id, :string
    field :upload_session_id, :string
    field :bytes_recorded, :integer, default: 0
    field :bytes_uploaded, :integer, default: 0
    field :expected_total_bytes, :integer
    field :capture_started_at, :utc_datetime_usec
    field :capture_completed_at, :utc_datetime_usec
    field :upload_completed_at, :utc_datetime_usec
    field :finalized_at, :utc_datetime_usec
    field :last_upload_ack_at, :utc_datetime_usec
    field :last_error_code, :string
    field :last_error_message, :string
    field :retry_count, :integer, default: 0
    field :transcript_text, :string
    field :transcript_provider, :string
    field :transcript_ready_at, :utc_datetime_usec

    belongs_to :session, Interview.Capture.Session
    belongs_to :template_question, Interview.Templates.Question

    timestamps()
  end

  def states, do: @states

  def changeset(resp, attrs) do
    resp
    |> cast(attrs, [
      :session_id,
      :template_question_id,
      :attempt_number,
      :state,
      :storage_key,
      :duration_ms,
      :format,
      :recorder_mime_type,
      :capture_instance_id,
      :upload_session_id,
      :bytes_recorded,
      :bytes_uploaded,
      :expected_total_bytes,
      :capture_started_at,
      :capture_completed_at,
      :upload_completed_at,
      :finalized_at,
      :last_upload_ack_at,
      :last_error_code,
      :last_error_message,
      :retry_count
    ])
    |> validate_required([:session_id, :template_question_id, :attempt_number, :state])
    |> validate_inclusion(:state, @states)
    |> unique_constraint([:session_id, :template_question_id, :attempt_number])
    |> unique_constraint(:upload_session_id)
  end
end
