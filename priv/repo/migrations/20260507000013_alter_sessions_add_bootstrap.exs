defmodule Interview.Repo.Migrations.AlterSessionsAddBootstrap do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :bootstrap_jti, :binary_id
      add :bootstrap_consumed_at, :utc_datetime_usec
    end
  end
end
