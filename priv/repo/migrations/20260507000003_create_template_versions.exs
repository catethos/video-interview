defmodule Interview.Repo.Migrations.CreateTemplateVersions do
  use Ecto.Migration

  def change do
    create table(:interview_template_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :template_id,
          references(:interview_templates, type: :binary_id, on_delete: :delete_all),
          null: false

      add :version_number, :integer, null: false

      add :retake_policy, :map,
        null: false,
        default: %{"max_attempts" => 1, "mode" => "first_only"}

      add :published_at, :utc_datetime_usec
      add :published_by, :string

      timestamps()
    end

    create unique_index(:interview_template_versions, [:template_id, :version_number])

    alter table(:interview_templates) do
      modify :current_version_id,
             references(:interview_template_versions, type: :binary_id, on_delete: :nilify_all)
    end
  end
end
