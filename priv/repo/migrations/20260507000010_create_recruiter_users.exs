defmodule Interview.Repo.Migrations.CreateRecruiterUsers do
  use Ecto.Migration

  def change do
    create table(:recruiter_users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :email, :string, null: false
      add :role, :string, null: false, default: "owner"
      add :last_seen_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:recruiter_users, [:email])
    create index(:recruiter_users, [:tenant_id])
  end
end
