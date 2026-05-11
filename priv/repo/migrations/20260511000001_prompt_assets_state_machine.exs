defmodule Interview.Repo.Migrations.PromptAssetsStateMachine do
  use Ecto.Migration

  def change do
    # storage_key is only populated once an asset reaches `ready`; pre-finalize
    # rows must be insertable without one.
    execute(
      "ALTER TABLE prompt_assets ALTER COLUMN storage_key DROP NOT NULL",
      "ALTER TABLE prompt_assets ALTER COLUMN storage_key SET NOT NULL"
    )

    alter table(:prompt_assets) do
      add :state, :string, null: false, default: "ready"
      add :capture_instance_id, :string
      add :upload_session_id, :string
      add :bytes_uploaded, :bigint, null: false, default: 0
      add :expected_total_bytes, :bigint
      add :recorder_mime_type, :string

      add :created_by_user_id,
          references(:recruiter_users, type: :binary_id, on_delete: :nilify_all)

      add :capture_started_at, :utc_datetime_usec
      add :capture_completed_at, :utc_datetime_usec
      add :upload_completed_at, :utc_datetime_usec
      add :finalized_at, :utc_datetime_usec
      add :last_error_code, :string
      add :last_error_message, :text
    end

    create unique_index(:prompt_assets, [:upload_session_id])

    # Sweeper hot path: find non-terminal rows older than a cutoff.
    create index(:prompt_assets, [:state, :inserted_at],
             where: "state NOT IN ('ready','failed','abandoned')",
             name: :prompt_assets_state_in_flight_idx
           )
  end
end
