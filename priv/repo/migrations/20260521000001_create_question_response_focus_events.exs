defmodule Interview.Repo.Migrations.CreateQuestionResponseFocusEvents do
  use Ecto.Migration

  def change do
    create table(:question_response_focus_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :response_id,
          references(:question_responses, type: :binary_id, on_delete: :delete_all),
          null: false

      # "lost"  → tab/window lost focus (blur / visibilitychange→hidden)
      # "regained" → tab/window regained focus
      add :kind, :string, null: false
      add :occurred_at, :utc_datetime_usec, null: false

      timestamps(updated_at: false)
    end

    create index(:question_response_focus_events, [:response_id])

    # Idempotency: the JS hook can fire blur + visibilitychange in
    # rapid succession on some browsers (e.g. backgrounding the tab
    # on Safari). The unique constraint on the natural triple lets
    # us safely upsert-or-ignore on the LV side.
    create unique_index(:question_response_focus_events, [:response_id, :occurred_at, :kind])
  end
end
