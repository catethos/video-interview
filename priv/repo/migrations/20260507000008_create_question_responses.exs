defmodule Interview.Repo.Migrations.CreateQuestionResponses do
  use Ecto.Migration

  def change do
    create table(:question_responses, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :template_question_id,
          references(:template_questions, type: :binary_id, on_delete: :restrict),
          null: false

      add :attempt_number, :integer, null: false, default: 1
      add :state, :string, null: false, default: "pending"
      add :storage_key, :string
      add :duration_ms, :integer
      add :format, :string
      add :recorder_mime_type, :string
      add :capture_instance_id, :string
      add :upload_session_id, :string
      add :bytes_recorded, :bigint, null: false, default: 0
      add :bytes_uploaded, :bigint, null: false, default: 0
      add :expected_total_bytes, :bigint
      add :capture_started_at, :utc_datetime_usec
      add :capture_completed_at, :utc_datetime_usec
      add :upload_completed_at, :utc_datetime_usec
      add :finalized_at, :utc_datetime_usec
      add :last_upload_ack_at, :utc_datetime_usec
      add :last_error_code, :string
      add :last_error_message, :text
      add :retry_count, :integer, null: false, default: 0
      add :transcript_text, :text
      add :transcript_provider, :string
      add :transcript_ready_at, :utc_datetime_usec

      timestamps()
    end

    create unique_index(:question_responses, [:session_id, :template_question_id, :attempt_number])

    create unique_index(:question_responses, [:upload_session_id],
             where: "upload_session_id IS NOT NULL"
           )

    create index(:question_responses, [:session_id])
    create index(:question_responses, [:state])
    create index(:question_responses, [:capture_instance_id])

    alter table(:session_questions) do
      modify :selected_response_id,
             references(:question_responses, type: :binary_id, on_delete: :nilify_all)
    end
  end
end
