defmodule Interview.Workers.AbandonedSessionSweeperTest do
  use Interview.DataCase, async: false

  use Oban.Testing, repo: Interview.Repo

  alias Interview.Capture
  alias Interview.Capture.Response
  alias Interview.Repo
  alias Interview.Workers.AbandonedSessionSweeper

  test "marks responses on stale sessions as abandoned" do
    %{session: stale, question: q1} = Interview.Fixtures.graph!()
    %{session: fresh, question: q2} = Interview.Fixtures.graph!()

    {:ok, stale_resp, _} = Capture.claim_instance(stale, q1, 1, "cap-stale")
    {:ok, fresh_resp, _} = Capture.claim_instance(fresh, q2, 1, "cap-fresh")

    long_ago = DateTime.add(DateTime.utc_now(), -5 * 60 * 60, :second)
    just_now = DateTime.add(DateTime.utc_now(), -1, :second)

    {1, _} =
      from(s in Interview.Capture.Session, where: s.id == ^stale.id)
      |> Repo.update_all(set: [last_client_seen_at: long_ago])

    {1, _} =
      from(s in Interview.Capture.Session, where: s.id == ^fresh.id)
      |> Repo.update_all(set: [last_client_seen_at: just_now])

    assert :ok = perform_job(AbandonedSessionSweeper, %{})

    assert Repo.get!(Response, stale_resp.id).state == "abandoned"
    assert Repo.get!(Response, fresh_resp.id).state == "recording"
  end

  test "ignores already-terminal responses" do
    %{session: s, question: q} = Interview.Fixtures.graph!()
    {:ok, r, _} = Capture.claim_instance(s, q, 1, "cap-X")
    {:ok, _} = Capture.mark_ready(r.id, %{storage_key: "k", duration_ms: 1, format: "mp4"})

    long_ago = DateTime.add(DateTime.utc_now(), -5 * 60 * 60, :second)

    {1, _} =
      from(sess in Interview.Capture.Session, where: sess.id == ^s.id)
      |> Repo.update_all(set: [last_client_seen_at: long_ago])

    assert :ok = perform_job(AbandonedSessionSweeper, %{})
    assert Repo.get!(Response, r.id).state == "ready"
  end
end
