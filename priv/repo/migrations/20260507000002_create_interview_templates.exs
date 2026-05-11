defmodule Interview.Repo.Migrations.CreateInterviewTemplates do
  use Ecto.Migration

  def change do
    create table(:interview_templates, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :description, :text
      add :current_version_id, :binary_id
      add :archived_at, :utc_datetime_usec

      timestamps()
    end

    create index(:interview_templates, [:tenant_id])
  end
end
