defmodule Interview.Repo.Migrations.CreateSessionQuestions do
  use Ecto.Migration

  def change do
    create table(:session_questions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :template_question_id,
          references(:template_questions, type: :binary_id, on_delete: :restrict),
          null: false

      add :position, :integer, null: false
      add :selected_response_id, :binary_id

      timestamps()
    end

    create unique_index(:session_questions, [:session_id, :template_question_id])
    create index(:session_questions, [:session_id, :position])
  end
end
