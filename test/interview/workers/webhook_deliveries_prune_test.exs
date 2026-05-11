defmodule Interview.Workers.WebhookDeliveriesPruneTest do
  use Interview.DataCase, async: false
  use Oban.Testing, repo: Interview.Repo

  import Ecto.Query

  alias Interview.Repo
  alias Interview.Tenants.Tenant
  alias Interview.Webhooks
  alias Interview.Webhooks.Delivery
  alias Interview.Workers.WebhookDeliveriesPrune

  setup do
    prev = Application.get_env(:interview, Interview.Webhooks, [])

    Application.put_env(
      :interview,
      Interview.Webhooks,
      Keyword.put(prev, :deliveries_retention_days, 30)
    )

    on_exit(fn -> Application.put_env(:interview, Interview.Webhooks, prev) end)
    :ok
  end

  defp configured_tenant! do
    tenant = Interview.Fixtures.tenant!()

    {:ok, t} =
      tenant
      |> Tenant.changeset(%{
        webhook_url: "https://hooks.example.com/x",
        webhook_secret: "topsecret-32-bytes-or-so-padding"
      })
      |> Repo.update()

    t
  end

  defp session_for(tenant) do
    template = Interview.Fixtures.template!(tenant.id)
    version = Interview.Fixtures.version!(template.id)
    Interview.Fixtures.session!(tenant.id, version.id, %{state: "in_progress"})
  end

  test "drops rows older than the retention window regardless of state" do
    tenant = configured_tenant!()

    fresh_session = session_for(tenant)
    stale_session = session_for(tenant)

    {:ok, %Delivery{id: fresh_id}} = Webhooks.enqueue(fresh_session, "session.submitted")
    {:ok, %Delivery{id: stale_id}} = Webhooks.enqueue(stale_session, "session.submitted")

    # Backdate the stale row past retention.
    old = DateTime.utc_now() |> DateTime.add(-90, :day)

    Repo.update_all(
      from(d in Delivery, where: d.id == ^stale_id),
      set: [inserted_at: old, updated_at: old, state: "delivered"]
    )

    assert {:ok, %{deleted: 1}} = perform_job(WebhookDeliveriesPrune, %{})

    assert Repo.get(Delivery, fresh_id)
    refute Repo.get(Delivery, stale_id)
  end
end
