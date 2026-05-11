defmodule Interview.Repo.Migrations.CreateTenantApiKeys do
  use Ecto.Migration

  def change do
    create table(:tenant_api_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :prefix, :string, null: false
      add :key_hash, :binary, null: false
      add :last_used_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec

      add :created_by_id,
          references(:recruiter_users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tenant_api_keys, [:prefix])
    create index(:tenant_api_keys, [:tenant_id])
  end
end
