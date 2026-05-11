defmodule Interview.Workers.SessionDeletionTest do
  use Interview.DataCase, async: false
  use Oban.Testing, repo: Interview.Repo

  alias Interview.Capture
  alias Interview.Capture.{Response, Session}
  alias Interview.Storage
  alias Interview.Workers.SessionDeletion

  setup do
    %{session: session, question: question} = Interview.Fixtures.graph!()
    {:ok, response, _} = Capture.claim_instance(session, question, 1, "cap-A")

    # Pretend the session is finalized: stamp a storage_key + write artifact bytes.
    storage_key = "test/sess/#{response.id}.mp4"
    artifact_path = Storage.artifact_path(storage_key)
    File.mkdir_p!(Path.dirname(artifact_path))
    File.write!(artifact_path, "FAKEMP4")

    writer_path = Storage.writer_path(response.id, "cap-A")
    File.mkdir_p!(Path.dirname(writer_path))
    File.write!(writer_path, "writer-bytes")

    {1, _} =
      Repo.update_all(
        from(r in Response, where: r.id == ^response.id),
        set: [storage_key: storage_key, state: "ready"]
      )

    {1, _} =
      Repo.update_all(
        from(s in Session, where: s.id == ^session.id),
        set: [state: "ready", completed_at: DateTime.utc_now() |> DateTime.add(-365, :day)]
      )

    %{session: session, response: response, storage_key: storage_key}
  end

  test "scrubs storage and response rows, soft-deletes the session", %{
    session: session,
    response: response,
    storage_key: storage_key
  } do
    artifact_path = Storage.artifact_path(storage_key)
    writer_dir = Path.dirname(Storage.writer_path(response.id, "cap-A"))

    assert File.exists?(artifact_path)

    assert :ok = perform_job(SessionDeletion, %{"session_id" => session.id})

    refute File.exists?(artifact_path)
    refute File.exists?(writer_dir)
    refute Repo.get(Response, response.id)

    final = Repo.get!(Session, session.id)
    assert final.deleted_at
  end

  test "is idempotent — running twice doesn't error", %{session: session} do
    assert :ok = perform_job(SessionDeletion, %{"session_id" => session.id})
    assert :ok = perform_job(SessionDeletion, %{"session_id" => session.id})
  end

  test "fires session.deleted webhook by default and an audit event", %{session: session} do
    assert :ok = perform_job(SessionDeletion, %{"session_id" => session.id})

    deliveries = Repo.all(Interview.Webhooks.Delivery)
    assert Enum.any?(deliveries, &(&1.event_type == "session.deleted"))

    audits =
      Interview.Audit.list_for_subject("session", session.id)
      |> Enum.map(& &1.action)

    assert "session.delete" in audits
  end

  test "skip-webhook flag silences the emit", %{session: session} do
    assert :ok =
             perform_job(SessionDeletion, %{
               "session_id" => session.id,
               "emit_webhook" => false
             })

    assert Repo.all(Interview.Webhooks.Delivery) == []
  end
end
