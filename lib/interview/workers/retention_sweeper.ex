defmodule Interview.Workers.RetentionSweeper do
  @moduledoc """
  Daily cron job that enqueues `Interview.Workers.SessionDeletion` for
  every session whose `completed_at + tenant.retention_days` is past
  (PLAN §7 Phase 4, §8.3).

  Per-tenant `retention_days` defaults to 90; tenants can override via the
  admin API or seeds. Sessions already soft-deleted (`deleted_at != nil`)
  are skipped — the deletion worker is the one that flips that bit.

  Sweeper itself does no I/O beyond enqueueing — keeps the cron tick fast
  and uniform regardless of backlog size.
  """
  use Oban.Worker, queue: :sweeper, max_attempts: 3

  require Logger

  alias Interview.Capture.Session
  alias Interview.Repo
  alias Interview.Tenants.Tenant
  alias Interview.Workers.SessionDeletion

  import Ecto.Query

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    expired =
      from(s in Session,
        join: t in Tenant,
        on: t.id == s.tenant_id,
        where:
          is_nil(s.deleted_at) and
            not is_nil(s.completed_at) and
            fragment(
              "? + (? * interval '1 day') < ?",
              s.completed_at,
              t.retention_days,
              ^now
            ),
        select: s.id
      )
      |> Repo.all()

    Enum.each(expired, fn session_id ->
      {:ok, _} =
        %{"session_id" => session_id, "reason" => "retention"}
        |> SessionDeletion.new()
        |> Oban.insert()
    end)

    Logger.info("retention_sweeper: enqueued #{length(expired)} session deletions")

    {:ok, %{enqueued: length(expired)}}
  end
end
