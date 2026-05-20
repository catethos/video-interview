defmodule Interview.Repo.Migrations.AddExternalReturnToTemplateVersions do
  use Ecto.Migration

  def change do
    alter table(:interview_template_versions) do
      add :external_return_url, :text
      add :external_return_state, :text
    end
  end
end
