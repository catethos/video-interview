defmodule Interview.Repo.Migrations.CreateSessions do
  use Ecto.Migration

  def change do
    create table(:sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :template_version_id,
          references(:interview_template_versions, type: :binary_id, on_delete: :restrict),
          null: false

      add :candidate_email, :string
      add :mode, :string, null: false, default: "async"
      add :state, :string, null: false, default: "pending"
      add :signed_token, :string
      add :expires_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :last_client_seen_at, :utc_datetime_usec
      add :user_agent, :text
      add :browser_name, :string
      add :browser_version, :string
      add :os, :string
      add :sdk_version, :string

      timestamps()
    end

    create index(:sessions, [:tenant_id])
    create index(:sessions, [:template_version_id])
    create index(:sessions, [:state])
    create index(:sessions, [:last_client_seen_at])
  end
end
