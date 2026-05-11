defmodule Interview.Workers.RetentionSweeperTest do
  use Interview.DataCase, async: false
  use Oban.Testing, repo: Interview.Repo

  alias Interview.Capture.Session
  alias Interview.Repo
  alias Interview.Tenants.Tenant
  alias Interview.Workers.{RetentionSweeper, SessionDeletion}

  test "enqueues SessionDeletion for sessions past retention" do
    tenant = Interview.Fixtures.tenant!()

    {:ok, tenant} =
      tenant
      |> Tenant.changeset(%{retention_days: 30})
      |> Repo.update()

    template = Interview.Fixtures.template!(tenant.id)
    version = Interview.Fixtures.version!(template.id)

    expired = Interview.Fixtures.session!(tenant.id, version.id, %{state: "ready"})

    Repo.update_all(
      from(s in Session, where: s.id == ^expired.id),
      set: [state: "ready", completed_at: DateTime.utc_now() |> DateTime.add(-90, :day)]
    )

    fresh = Interview.Fixtures.session!(tenant.id, version.id, %{state: "ready"})

    Repo.update_all(
      from(s in Session, where: s.id == ^fresh.id),
      set: [state: "ready", completed_at: DateTime.utc_now() |> DateTime.add(-1, :day)]
    )

    {:ok, %{enqueued: 1}} = perform_job(RetentionSweeper, %{})

    assert_enqueued(worker: SessionDeletion, args: %{"session_id" => expired.id})
    refute_enqueued(worker: SessionDeletion, args: %{"session_id" => fresh.id})
  end

  test "skips already soft-deleted sessions" do
    tenant = Interview.Fixtures.tenant!()
    template = Interview.Fixtures.template!(tenant.id)
    version = Interview.Fixtures.version!(template.id)

    s = Interview.Fixtures.session!(tenant.id, version.id, %{state: "ready"})

    Repo.update_all(
      from(x in Session, where: x.id == ^s.id),
      set: [
        completed_at: DateTime.utc_now() |> DateTime.add(-200, :day),
        deleted_at: DateTime.utc_now()
      ]
    )

    {:ok, %{enqueued: 0}} = perform_job(RetentionSweeper, %{})
  end
end
