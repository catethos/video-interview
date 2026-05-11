defmodule Interview.Repo.Migrations.CreateTemplateQuestions do
  use Ecto.Migration

  def change do
    create table(:template_questions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :template_version_id,
          references(:interview_template_versions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :position, :integer, null: false
      add :prompt_text, :text, null: false

      add :prompt_asset_id,
          references(:prompt_assets, type: :binary_id, on_delete: :nilify_all)

      add :attachment_asset_id,
          references(:prompt_assets, type: :binary_id, on_delete: :nilify_all)

      add :think_time_seconds, :integer
      add :max_answer_seconds, :integer
      add :min_answer_seconds, :integer
      add :required, :boolean, null: false, default: true
      add :max_attempts_override, :integer
      add :tags, {:array, :string}, null: false, default: []
      add :locale, :string
      add :external_id, :string
      add :notes, :text

      timestamps()
    end

    create unique_index(:template_questions, [:template_version_id, :position])
  end
end
