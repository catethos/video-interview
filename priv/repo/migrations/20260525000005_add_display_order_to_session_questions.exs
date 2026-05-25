defmodule Interview.Repo.Migrations.AddDisplayOrderToSessionQuestions do
  use Ecto.Migration

  def change do
    # The candidate's per-session 1..N slot for this question. Nullable for
    # back-compat with rows created before this column; readers fall back to
    # `position`. `position` stays the canonical template order.
    alter table(:session_questions) do
      add :display_order, :integer
    end
  end
end
