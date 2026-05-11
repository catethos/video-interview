defmodule Interview.Repo.Migrations.CreateRecruiterMagicLinks do
  use Ecto.Migration

  def change do
    create table(:recruiter_magic_links, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :recruiter_user_id,
          references(:recruiter_users, type: :binary_id, on_delete: :delete_all),
          null: false

      add :token_hash, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :consumed_at, :utc_datetime_usec
      add :requested_ip, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:recruiter_magic_links, [:token_hash])
    create index(:recruiter_magic_links, [:recruiter_user_id])
  end
end
