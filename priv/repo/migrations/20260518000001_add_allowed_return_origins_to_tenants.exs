defmodule Interview.Repo.Migrations.AddAllowedReturnOriginsToTenants do
  use Ecto.Migration

  @moduledoc """
  Adds the per-tenant whitelist of external origins permitted to receive
  deep-link callbacks from VI's recruiter LiveViews.

  When an external system (e.g. Pulsifi) drives a recruiter through VI's
  template-builder via a `?return_to=<url>` query param, we validate the
  URL's origin against this list before redirecting. Empty list = no
  external callbacks allowed (default-safe).
  """

  def change do
    alter table(:tenants) do
      add :allowed_return_origins, {:array, :string}, default: [], null: false
    end
  end
end
