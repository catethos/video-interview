defmodule Interview.Workers.SessionDeletion do
  @moduledoc """
  Hard-delete a session's storage artifacts and the response rows
  (PLAN §7 Phase 4, §8.3). Triggered by either:

    * `Interview.Workers.RetentionSweeper` for sessions whose
      `completed_at + retention_days` is past, or
    * `DELETE /api/sessions/:id` (right-to-delete).

  Idempotency:

    * Storage deletes are idempotent on missing keys (see
      `Interview.Storage.delete_response/1` /
      `Interview.Storage.delete_artifact/1`).
    * `sessions.deleted_at` is soft-set first (by the caller); this job
      hard-deletes storage and response rows. Re-running the job is safe.
    * The session row itself is NOT hard-deleted — keep it for audit
      trails. Only `deleted_at` flips and the storage_keys are scrubbed.

  PLAN §12.5: no long DB transaction wrapping object-store I/O. Storage
  calls happen first; the small DB tx that scrubs response rows opens
  after.
  """
  use Oban.Worker, queue: :sweeper, max_attempts: 5

  require Logger

  alias Interview.Capture.{Response, Session}
  alias Interview.Repo
  alias Interview.Storage

  import Ecto.Query

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"session_id" => session_id} = args}) do
    case Repo.get(Session, session_id) do
      nil ->
        :ok

      %Session{} = session ->
        responses = list_responses(session_id)

        # Object-store deletes first (no DB transaction held).
        Enum.each(responses, fn r ->
          Storage.delete_response(r.id)

          if r.storage_key, do: Storage.delete_artifact(r.storage_key)
        end)

        # Now scrub the rows in a small DB tx.
        Repo.transaction(fn ->
          from(r in Response, where: r.session_id == ^session_id) |> Repo.delete_all()

          from(s in Session, where: s.id == ^session_id and is_nil(s.deleted_at))
          |> Repo.update_all(set: [deleted_at: DateTime.utc_now()])
        end)

        Interview.Audit.log!(%{
          tenant_id: session.tenant_id,
          actor_kind: Map.get(args, "actor_kind", "system"),
          actor_id: Map.get(args, "actor_id"),
          action: "session.delete",
          subject_kind: "session",
          subject_id: session.id,
          metadata: %{
            "reason" => Map.get(args, "reason", "retention"),
            "responses_deleted" => length(responses)
          }
        })

        if Map.get(args, "emit_webhook", true) do
          reason = Map.get(args, "reason", "retention")
          _ = Interview.Webhooks.enqueue(session, "session.deleted", %{"reason" => reason})
        end

        :ok
    end
  end

  defp list_responses(session_id) do
    from(r in Response, where: r.session_id == ^session_id) |> Repo.all()
  end
end
