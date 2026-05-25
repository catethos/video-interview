defmodule Interview.Repo.Migrations.AddRandomizeQuestionsToVersions do
  use Ecto.Migration

  def change do
    # Recruiter opt-in (frozen with the version). When true, each candidate's
    # session_questions get a shuffled display_order; canonical order
    # (template_questions.position) is untouched.
    alter table(:interview_template_versions) do
      add :randomize_questions, :boolean, null: false, default: false
    end
  end
end
