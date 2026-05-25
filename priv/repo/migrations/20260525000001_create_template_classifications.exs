defmodule Interview.Repo.Migrations.CreateTemplateClassifications do
  use Ecto.Migration

  def change do
    create table(:template_classifications, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :template_version_id,
          references(:interview_template_versions, type: :binary_id, on_delete: :delete_all),
          null: false

      # The pipeline build that produced this classification. Part of the
      # cache key: bumping the pipeline naturally invalidates old rows
      # (a new build → a new row), so we never serve a stale P1.
      add :pipeline_version, :string, null: false

      # Which LLM produced the P1 classification (e.g. "google/gemini-2.5-flash").
      add :provider, :string

      # The P1 output, stored as JSON (one classification entry per question).
      add :result, :map, null: false

      add :computed_at, :utc_datetime_usec, null: false

      timestamps(updated_at: false)
    end

    # One classification per (template version, pipeline build). The explicit
    # name keeps the identifier under Postgres' 63-char limit — the default
    # name would be 67 chars and silently truncate, which would stop the
    # changeset's unique_constraint from matching the real index.
    create unique_index(:template_classifications, [:template_version_id, :pipeline_version],
             name: :template_classifications_version_pipeline_index
           )
  end
end
