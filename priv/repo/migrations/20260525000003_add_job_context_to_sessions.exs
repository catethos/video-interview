defmodule Interview.Repo.Migrations.AddJobContextToSessions do
  use Ecto.Migration

  def change do
    # Consumer-supplied job context, passed at POST /api/sessions alongside
    # external_id (the talent-app owns the job; VI just holds this for the
    # scoring run). job_role feeds P1's prompt; job_description feeds P2-P5.
    alter table(:sessions) do
      add :job_role, :string
      add :job_description, :text
    end
  end
end
