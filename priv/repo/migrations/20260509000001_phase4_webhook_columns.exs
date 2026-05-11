defmodule Interview.Repo.Migrations.Phase4WebhookColumns do
  use Ecto.Migration

  def change do
    alter table(:tenants) do
      add :webhook_secret, :string
      add :retention_days, :integer, null: false, default: 90
    end

    alter table(:sessions) do
      add :external_id, :string
      add :deleted_at, :utc_datetime_usec
    end

    create index(:sessions, [:completed_at])
    create index(:sessions, [:deleted_at])

    create table(:webhook_deliveries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :session_id, references(:sessions, type: :binary_id, on_delete: :nilify_all)
      add :event_type, :string, null: false
      add :state, :string, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :last_status, :integer
      add :last_error, :text
      add :response_body_preview, :text
      add :payload, :map, null: false, default: %{}
      add :delivered_at, :utc_datetime_usec
      add :occurred_at, :utc_datetime_usec, null: false

      timestamps()
    end

    create index(:webhook_deliveries, [:tenant_id])
    create index(:webhook_deliveries, [:session_id])
    create index(:webhook_deliveries, [:state])
    create unique_index(:webhook_deliveries, [:session_id, :event_type])
  end
end
