defmodule Interview.Repo.Migrations.CreateAuditEvents do
  use Ecto.Migration

  def change do
    create table(:audit_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :nilify_all)
      add :actor_kind, :string, null: false
      add :actor_id, :string
      add :action, :string, null: false
      add :subject_kind, :string
      add :subject_id, :string
      add :ip_address, :string
      add :user_agent, :text
      add :metadata, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime_usec, null: false

      timestamps(updated_at: false)
    end

    create index(:audit_events, [:tenant_id])
    create index(:audit_events, [:action])
    create index(:audit_events, [:subject_kind, :subject_id])
    create index(:audit_events, [:occurred_at])
  end
end
