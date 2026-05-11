defmodule Interview.Workers.AuditPruneTest do
  use Interview.DataCase, async: false
  use Oban.Testing, repo: Interview.Repo

  alias Interview.Audit.Event
  alias Interview.Repo
  alias Interview.Workers.AuditPrune

  setup do
    prev = Application.get_env(:interview, Interview.Audit, [])
    Application.put_env(:interview, Interview.Audit, Keyword.put(prev, :retention_days, 30))
    on_exit(fn -> Application.put_env(:interview, Interview.Audit, prev) end)
    :ok
  end

  defp insert_event!(occurred_at) do
    tenant = Interview.Fixtures.tenant!()

    %Event{}
    |> Event.changeset(%{
      tenant_id: tenant.id,
      actor_kind: "system",
      action: "test.event",
      occurred_at: occurred_at
    })
    |> Repo.insert!()
  end

  test "drops events older than the configured retention" do
    fresh = insert_event!(DateTime.utc_now() |> DateTime.add(-1, :day))
    stale = insert_event!(DateTime.utc_now() |> DateTime.add(-90, :day))

    assert {:ok, %{deleted: 1}} = perform_job(AuditPrune, %{})

    assert Repo.get(Event, fresh.id)
    refute Repo.get(Event, stale.id)
  end

  test "no-ops when nothing is past retention" do
    _ = insert_event!(DateTime.utc_now() |> DateTime.add(-5, :day))

    assert {:ok, %{deleted: 0}} = perform_job(AuditPrune, %{})
  end
end
