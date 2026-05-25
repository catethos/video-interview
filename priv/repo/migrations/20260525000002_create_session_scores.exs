defmodule Interview.Repo.Migrations.CreateSessionScores do
  use Ecto.Migration

  def change do
    create table(:session_scores, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :pipeline_version, :string, null: false

      # "ready" → pipeline ran and the score webhook was enqueued.
      # "failed" → pipeline gave up after retries; failure webhook enqueued.
      add :status, :string, null: false

      # null on success; a stable machine code on failure (e.g. "rate_limited").
      add :error_reason, :string

      add :computed_at, :utc_datetime_usec, null: false

      timestamps(updated_at: false)
    end

    # One row per (session, pipeline build). Lets a later re-score against a
    # newer pipeline land as a separate row for the same session, and lets the
    # worker short-circuit ("already scored?") on Oban retries — a cost guard
    # so we never double-run the pipeline.
    create unique_index(:session_scores, [:session_id, :pipeline_version])

    # The recruiter/observability dashboards filter by status ("show failures").
    create index(:session_scores, [:status])
  end
end
