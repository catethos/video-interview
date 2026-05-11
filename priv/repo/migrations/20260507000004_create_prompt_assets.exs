defmodule Interview.Repo.Migrations.CreatePromptAssets do
  use Ecto.Migration

  def change do
    create table(:prompt_assets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :mime_type, :string
      add :storage_key, :string, null: false
      add :duration_ms, :integer
      add :bytes, :bigint
      add :created_by, :string

      timestamps()
    end

    create index(:prompt_assets, [:tenant_id])
  end
end
