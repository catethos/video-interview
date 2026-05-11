defmodule Interview.CaptureTest do
  use Interview.DataCase, async: true

  alias Interview.Capture
  alias Interview.Capture.Response
  alias Interview.Repo

  setup do
    %{session: session, question: question, version: version} = Interview.Fixtures.graph!()
    {:ok, session: session, question: question, version: version}
  end

  describe "claim_instance/4" do
    test "creates a fresh row on first claim", %{session: s, question: q} do
      assert {:ok, %Response{} = r, nil} = Capture.claim_instance(s, q, 1, "cap-A")
      assert r.capture_instance_id == "cap-A"
      assert r.state == "recording"
      assert r.attempt_number == 1
    end

    test "is idempotent for the same capture_instance_id", %{session: s, question: q} do
      {:ok, r1, nil} = Capture.claim_instance(s, q, 1, "cap-A")
      assert {:ok, r2, "cap-A"} = Capture.claim_instance(s, q, 1, "cap-A")
      assert r2.id == r1.id
      assert r2.capture_instance_id == "cap-A"
    end

    test "same-attempt different-instance updates the writer (BFCache resume)",
         %{session: s, question: q} do
      {:ok, r1, nil} = Capture.claim_instance(s, q, 1, "cap-A")
      {:ok, r2, "cap-A"} = Capture.claim_instance(s, q, 1, "cap-B")
      assert r2.id == r1.id
      assert r2.capture_instance_id == "cap-B"
    end

    test "newer attempt supersedes prior attempts on same (session, question)",
         %{session: s, question: q} do
      {:ok, r1, nil} = Capture.claim_instance(s, q, 1, "cap-A")
      {:ok, r2, nil} = Capture.claim_instance(s, q, 2, "cap-B")

      r1 = Repo.get!(Response, r1.id)
      assert r1.state == "superseded"
      assert r2.attempt_number == 2
      assert r2.capture_instance_id == "cap-B"
    end
  end

  describe "commit_offset/3" do
    test "advances bytes_uploaded and stamps last_upload_ack_at",
         %{session: s, question: q} do
      {:ok, r, _} = Capture.claim_instance(s, q, 1, "cap-A")
      {:ok, r2} = Capture.commit_offset(r.id, "cap-A", 1024)
      assert r2.bytes_uploaded == 1024
      assert r2.last_upload_ack_at
    end

    test "fences a stale writer", %{session: s, question: q} do
      {:ok, r, _} = Capture.claim_instance(s, q, 1, "cap-A")
      {:ok, _r, _} = Capture.claim_instance(s, q, 1, "cap-B")
      assert {:fenced, "cap-B"} = Capture.commit_offset(r.id, "cap-A", 999)
    end

    test "does not move the offset backwards on replay",
         %{session: s, question: q} do
      {:ok, r, _} = Capture.claim_instance(s, q, 1, "cap-A")
      {:ok, r2} = Capture.commit_offset(r.id, "cap-A", 5000)
      {:ok, r3} = Capture.commit_offset(r.id, "cap-A", 1000)
      assert r2.bytes_uploaded == 5000
      assert r3.bytes_uploaded == 5000
    end
  end

  describe "record_capture_complete/3" do
    test "moves to capture_complete when current writer", %{session: s, question: q} do
      {:ok, r, _} = Capture.claim_instance(s, q, 1, "cap-A")
      {:ok, r2} = Capture.record_capture_complete(r.id, "cap-A", 4096)
      assert r2.state == "capture_complete"
      assert r2.expected_total_bytes == 4096
      assert r2.capture_completed_at
    end

    test "fences a stale writer", %{session: s, question: q} do
      {:ok, r, _} = Capture.claim_instance(s, q, 1, "cap-A")
      {:ok, _r, _} = Capture.claim_instance(s, q, 1, "cap-B")
      assert {:fenced, "cap-B"} = Capture.record_capture_complete(r.id, "cap-A", 4096)
    end

    test "is idempotent if already capture_complete", %{session: s, question: q} do
      {:ok, r, _} = Capture.claim_instance(s, q, 1, "cap-A")
      {:ok, _} = Capture.record_capture_complete(r.id, "cap-A", 4096)
      {:ok, r2} = Capture.record_capture_complete(r.id, "cap-A", 9999)
      # idempotent: expected_total_bytes was set on the first call, not overwritten
      assert r2.state == "capture_complete"
      assert r2.expected_total_bytes == 4096
    end
  end

  describe "rollup_session/1" do
    test "in_progress sessions are not promoted by mark_ready alone",
         %{session: s, question: q} do
      # PLAN §3.2 state machine: pending → in_progress → submitted → ready.
      # mark_ready alone is no longer enough; a session must be `submitted`
      # before rollup can promote it. The candidate clicking Submit is the
      # gate.
      {:ok, r, _} = Capture.claim_instance(s, q, 1, "cap-A")
      {:ok, _} = Capture.mark_ready(r.id, %{storage_key: "k", duration_ms: 1000, format: "mp4"})
      session = Repo.get!(Interview.Capture.Session, s.id)
      assert session.state == "in_progress"
      refute session.completed_at
    end

    test "submit + mark_ready promotes a submitted session to ready",
         %{session: s, question: q} do
      {:ok, r, _} = Capture.claim_instance(s, q, 1, "cap-A")
      {:ok, _} = Capture.record_capture_complete(r.id, "cap-A", 1024)
      assert {:ok, %{state: "submitted"}} = Capture.submit_session(s)

      {:ok, _} = Capture.mark_ready(r.id, %{storage_key: "k", duration_ms: 1000, format: "mp4"})

      session = Repo.get!(Interview.Capture.Session, s.id)
      assert session.state == "ready"
      assert session.completed_at
    end

    test "submit_session immediately promotes when all responses are already ready",
         %{session: s, question: q} do
      # Late-arriving Submit click after every finalize already finished.
      {:ok, r, _} = Capture.claim_instance(s, q, 1, "cap-A")
      {:ok, _} = Capture.record_capture_complete(r.id, "cap-A", 1024)
      {:ok, _} = Capture.mark_ready(r.id, %{storage_key: "k", duration_ms: 1000, format: "mp4"})
      assert {:ok, %{state: "ready"}} = Capture.submit_session(s)
    end
  end

  describe "submit_session/1" do
    test "rejects when a required question has no acceptable response",
         %{session: s} do
      assert {:error, {:required_unmet, [_]}} = Capture.submit_session(s)
    end

    test "ignores optional questions with no response", %{session: s, question: q, version: v} do
      {:ok, r1, _} = Capture.claim_instance(s, q, 1, "cap-1")
      {:ok, _} = Capture.record_capture_complete(r1.id, "cap-1", 256)

      _q2 =
        Interview.Fixtures.question!(v.id, 2, %{
          required: false,
          prompt_text: "Optional"
        })

      assert {:ok, %{state: "submitted"}} = Capture.submit_session(s)
    end
  end

  describe "retake_policy / mark_ready / selected_response_id" do
    setup %{session: _s} do
      %{
        session: session,
        question: question,
        version: version
      } =
        Interview.Fixtures.graph_with_questions!([%{required: true}],
          version: %{retake_policy: %{"max_attempts" => 3, "mode" => "last"}}
        )

      Capture.ensure_session_questions(session)
      {:ok, session: session, question: question, version: version}
    end

    test "first_only keeps the first ready attempt as the selection" do
      %{session: s, question: q} =
        Interview.Fixtures.graph_with_questions!([%{required: true}],
          version: %{retake_policy: %{"max_attempts" => 3, "mode" => "first_only"}}
        )

      Capture.ensure_session_questions(s)

      {:ok, r1, _} = Capture.claim_instance(s, q, 1, "cap-1")
      {:ok, _} = Capture.mark_ready(r1.id, %{storage_key: "k1", duration_ms: 1, format: "mp4"})

      sq = Capture.get_session_question(s.id, q.id)
      assert sq.selected_response_id == r1.id
    end

    test "last selects the most recent ready attempt and supersedes the prior",
         %{session: s, question: q} do
      {:ok, r1, _} = Capture.claim_instance(s, q, 1, "cap-1")
      {:ok, _} = Capture.mark_ready(r1.id, %{storage_key: "k1", duration_ms: 1, format: "mp4"})
      sq1 = Capture.get_session_question(s.id, q.id)
      assert sq1.selected_response_id == r1.id

      {:ok, r2, _} = Capture.claim_instance(s, q, 2, "cap-2")
      {:ok, _} = Capture.mark_ready(r2.id, %{storage_key: "k2", duration_ms: 1, format: "mp4"})

      sq2 = Capture.get_session_question(s.id, q.id)
      assert sq2.selected_response_id == r2.id

      r1_after = Repo.get!(Response, r1.id)
      assert r1_after.state == "superseded"
    end

    test "max_attempts_for honours max_attempts_override over policy default",
         %{session: _s, version: v} do
      q =
        Interview.Fixtures.question!(v.id, 9, %{
          required: true,
          max_attempts_override: 5
        })

      assert Capture.max_attempts_for(q, v) == 5
    end
  end

  describe "ensure_session_questions/1" do
    test "is idempotent and creates one row per question", %{session: s} do
      :ok = Capture.ensure_session_questions(s)
      :ok = Capture.ensure_session_questions(s)

      sqs = Capture.list_session_questions(s)
      assert length(sqs) == 1
    end
  end
end
