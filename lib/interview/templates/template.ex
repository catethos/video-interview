defmodule Interview.Templates.Template do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "interview_templates" do
    field :name, :string
    field :description, :string
    field :archived_at, :utc_datetime_usec

    belongs_to :tenant, Interview.Tenants.Tenant
    belongs_to :current_version, Interview.Templates.Version
    has_many :versions, Interview.Templates.Version

    timestamps()
  end

  def changeset(template, attrs) do
    template
    |> cast(attrs, [:tenant_id, :name, :description, :current_version_id, :archived_at])
    |> validate_required([:tenant_id, :name])
  end
end
