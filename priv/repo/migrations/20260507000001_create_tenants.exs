defmodule Interview.Repo.Migrations.CreateTenants do
  use Ecto.Migration

  def change do
    create table(:tenants, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :frame_ancestors, {:array, :string}, null: false, default: []
      add :webhook_url, :string
      add :branding, :map, null: false, default: %{}

      timestamps()
    end

    create unique_index(:tenants, [:slug])
  end
end
