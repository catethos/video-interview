defmodule Interview.Capture do
  @moduledoc """
  Workflow operations for the candidate capture pipeline (PLAN §3.3, §5.1).

  Authoritative state for fencing, upload offsets, and lifecycle transitions
  lives in Postgres. The tus PATCH handler calls into this module so storage
  ACK + Postgres commit happen in lockstep (PLAN §5.1 invariant).
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Interview.Repo
  alias Interview.Capture.{Response, Session, SessionQuestion}
  alias Interview.Templates.{Question, Version}

  # ---- Sessions ----------------------------------------------------------

  def get_session(id), do: Repo.get(Session, id)
  def get_session!(id), do: Repo.get!(Session, id)

  def fetch_session(id) do
    case get_session(id) do
      nil -> {:error, :not_found}
      session -> {:ok, session}
    end
  end

  def touch_session_seen(%Session{} = session) do
    now = DateTime.utc_now()

    {1, _} =
      from(s in Session, where: s.id == ^session.id)
      |> Repo.update_all(set: [last_client_seen_at: now])

    %{session | last_client_seen_at: now}
  end

  # ---- Question lookup ---------------------------------------------------

  @doc """
  Resolve `(session, position)` → `%Question{}`.

  Phase 0 used a 1-based "question_index" everywhere on the wire; the JS
  hook still does. Server-side we resolve that to the immutable
  `template_question_id` via the session's frozen template_version.
  """
  def fetch_question_by_position(%Session{template_version_id: vid}, position)
      when is_integer(position) do
    case Repo.get_by(Question, template_version_id: vid, position: position) do
      nil -> {:error, :not_found}
      q -> {:ok, q}
    end
  end

  @doc "Questions for a session's frozen template version, ordered by position."
  def list_questions(%Session{template_version_id: vid}) do
    from(q in Question, where: q.template_version_id == ^vid, order_by: q.position)
    |> Repo.all()
  end

  @doc "Returns the session's frozen template_version (with retake_policy)."
  def get_template_version!(%Session{template_version_id: vid}), do: Repo.get!(Version, vid)

  @doc """
  Effective per-question retake cap. `max_attempts_override` wins; otherwise
  the template_version's `retake_policy["max_attempts"]` (default 1).
  """
  def max_attempts_for(%Question{} = q, %Version{} = version) do
    cap =
      cond do
        is_integer(q.max_attempts_override) -> q.max_attempts_override
        true -> version.retake_policy["max_attempts"] || 1
      end

    max(cap, 1)
  end

  # ---- session_questions -------------------------------------------------

  @doc """
  Idempotently materialise a `session_questions` row per `template_question`
  for the session. Called from CaptureLive on mount; safe to call repeatedly.
  """
  def ensure_session_questions(%Session{} = session) do
    questions = list_questions(session)
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    rows =
      Enum.map(questions, fn q ->
        %{
          id: Ecto.UUID.generate(),
          session_id: session.id,
          template_question_id: q.id,
          position: q.position,
          inserted_at: now,
          updated_at: now
        }
      end)

    if rows == [] do
      :ok
    else
      Repo.insert_all(SessionQuestion, rows,
        on_conflict: :nothing,
        conflict_target: [:session_id, :template_question_id]
      )

      :ok
    end
  end

  def list_session_questions(%Session{} = session) do
    from(sq in SessionQuestion,
      where: sq.session_id == ^session.id,
      order_by: sq.position
    )
    |> Repo.all()
  end

  def get_session_question(session_id, template_question_id) do
    Repo.get_by(SessionQuestion,
      session_id: session_id,
      template_question_id: template_question_id
    )
  end

  # ---- Responses ---------------------------------------------------------

  def get_response(id), do: Repo.get(Response, id)
  def get_response!(id), do: Repo.get!(Response, id)

  def get_response_by_attempt(session_id, template_question_id, attempt_number) do
    Repo.get_by(Response,
      session_id: session_id,
      template_question_id: template_question_id,
      attempt_number: attempt_number
    )
  end

  @doc "Highest `attempt_number` so far for `(session, question)`, 0 if none."
  def max_attempt_number(session_id, template_question_id) do
    Repo.one(
      from(r in Response,
        where: r.session_id == ^session_id and r.template_question_id == ^template_question_id,
        select: coalesce(max(r.attempt_number), 0)
      )
    )
  end

  @doc "All response rows for a (session, question), oldest attempt first."
  def list_responses_for(session_id, template_question_id) do
    from(r in Response,
      where: r.session_id == ^session_id and r.template_question_id == ^template_question_id,
      order_by: r.attempt_number
    )
    |> Repo.all()
  end

  @doc """
  Has the candidate begun answering on this session yet?

  Used by the capture LiveView to distinguish a fresh landing (show
  the intro/disclosure gate) from a mid-interview reload (skip the
  gate and go straight to the current question). The session row's
  `state` field is set to `"in_progress"` at creation time so it
  isn't a useful signal on its own — `any_responses?/1` is.
  """
  def any_responses?(session_id) when is_binary(session_id) do
    Repo.exists?(from(r in Response, where: r.session_id == ^session_id))
  end

  # ---- Focus telemetry ----------------------------------------------------
  #
  # Soft cheating signal: how many times did the candidate's tab lose
  # focus while they were recording? Persisted per response so the
  # recruiter dashboard can show "left tab 2× during this answer".
  # NOT used in the AI scoring pipeline — purely informational.

  @doc """
  Record a focus event for a (response, kind, occurred_at). Idempotent
  on the natural key (the JS hook may double-fire on browsers that
  emit blur + visibilitychange together).

  Returns `:ok` on insert, `{:error, :invalid}` on validation failure,
  and `:ok` on conflict (already recorded).
  """
  def record_focus_event(response_id, kind, %DateTime{} = occurred_at)
      when is_binary(response_id) and kind in ["lost", "regained"] do
    changeset =
      Interview.Capture.FocusEvent.changeset(%Interview.Capture.FocusEvent{}, %{
        response_id: response_id,
        kind: kind,
        occurred_at: occurred_at
      })

    case Repo.insert(changeset, on_conflict: :nothing) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :invalid}
    end
  end

  def record_focus_event(_, _, _), do: {:error, :invalid}

  @doc """
  Count "lost" focus events for a response. "Regained" events are
  paired diagnostics, not weighted — what matters is how many times
  the candidate's attention left, not whether they came back.
  """
  def count_focus_losses(response_id) when is_binary(response_id) do
    Repo.aggregate(
      from(f in Interview.Capture.FocusEvent,
        where: f.response_id == ^response_id and f.kind == "lost"
      ),
      :count
    )
  end

  @doc """
  Summary of focus-loss events for a response: count of "lost" events
  + total milliseconds the candidate's tab was unfocused. We walk the
  events in chronological order and pair each "lost" with the next
  "regained"; the duration between them is added to the total.

  Unpaired "lost" events (last event was "lost" with no following
  "regained" — candidate closed the tab, or never returned) still
  count toward the `count` but contribute zero to `total_ms`. We
  could synthesize an end timestamp from the response's
  `finalized_at`, but the count alone is the meaningful signal there.
  """
  def focus_loss_summary(response_id) when is_binary(response_id) do
    events =
      from(f in Interview.Capture.FocusEvent,
        where: f.response_id == ^response_id,
        order_by: f.occurred_at,
        select: {f.kind, f.occurred_at}
      )
      |> Repo.all()

    {count, total_ms, _open_lost_at} =
      Enum.reduce(events, {0, 0, nil}, fn
        {"lost", at}, {count, total, _prev_lost} ->
          {count + 1, total, at}

        {"regained", at}, {count, total, prev_lost} when not is_nil(prev_lost) ->
          diff = DateTime.diff(at, prev_lost, :millisecond)
          {count, total + max(diff, 0), nil}

        {"regained", _at}, acc ->
          # Unpaired "regained" with no prior "lost" — probably a
          # browser event order artifact; ignore.
          acc
      end)

    %{count: count, total_ms: total_ms}
  end

  @doc """
  Claim (or refresh) the writer for a `(session, question, attempt)`.

  Behaviour (PLAN §5.1):

    * No existing row → insert a fresh `recording` row with the given
      `capture_instance_id`.
    * Existing row, same `capture_instance_id` → idempotent.
    * Existing row, different `capture_instance_id` (BFCache / two-tab
      takeover for *the same attempt*) → update the writer; the prior
      writer's in-flight PATCHes will be fenced (HTTP 410) on the next
      offset commit because their captureInstanceId no longer matches.

  Always supersedes earlier attempts for `(session, question)` whose
  attempt_number is lower than this one.

  Returns `{:ok, response, previous_capture_instance_id}` where
  `previous_capture_instance_id` is the prior writer's id (or `nil`).
  """
  def claim_instance(%Session{} = session, %Question{} = question, attempt_number, capture_id)
      when is_integer(attempt_number) and is_binary(capture_id) do
    Multi.new()
    |> Multi.run(:supersede_lower, fn repo, _ ->
      {n, _} =
        from(r in Response,
          where: r.session_id == ^session.id,
          where: r.template_question_id == ^question.id,
          where: r.attempt_number < ^attempt_number,
          where: r.state not in ["ready", "superseded", "failed", "abandoned", "expired"]
        )
        |> repo.update_all(set: [state: "superseded"])

      {:ok, n}
    end)
    |> Multi.run(:upsert, fn repo, _ ->
      now = DateTime.utc_now()

      case repo.get_by(Response,
             session_id: session.id,
             template_question_id: question.id,
             attempt_number: attempt_number
           ) do
        nil ->
          %Response{}
          |> Response.changeset(%{
            session_id: session.id,
            template_question_id: question.id,
            attempt_number: attempt_number,
            state: "recording",
            capture_instance_id: capture_id,
            capture_started_at: now
          })
          |> repo.insert()
          |> case do
            {:ok, r} -> {:ok, {r, nil}}
            err -> err
          end

        %Response{} = existing ->
          previous = existing.capture_instance_id

          updates =
            cond do
              previous == capture_id ->
                # idempotent
                []

              true ->
                base = [capture_instance_id: capture_id, updated_at: now]
                # Re-arm if the prior attempt had completed capture; new writer means new bytes.
                if existing.state in ["pending", "recording"] do
                  base
                else
                  [{:state, "recording"} | base]
                end
            end

          if updates == [] do
            {:ok, {existing, previous}}
          else
            {1, [updated]} =
              from(r in Response, where: r.id == ^existing.id, select: r)
              |> repo.update_all(set: updates)

            {:ok, {updated, previous}}
          end
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{upsert: {response, previous}}} -> {:ok, response, previous}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc """
  Commit a successful tus offset write to Postgres in the same logical
  step that ACKs the bytes durable to storage (PLAN §5.1 invariant).

  Returns:

    * `{:ok, response}` — offset advanced, writer still current.
    * `{:fenced, current_capture_id}` — caller's capture_instance_id is no
      longer the live writer; storage bytes were written (caller must
      decide what to do, but the response row is left alone).
    * `{:error, term}` — DB error.

  Note on storage-ACK ordering: the caller must have written to the storage
  backend FIRST, then call this. If this returns `:fenced`, the storage
  bytes are orphaned — the finalizer for the now-current writer will
  ignore them because they are scoped to the previous writer's prefix.
  """
  def commit_offset(response_id, capture_id, new_offset)
      when is_integer(new_offset) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      response =
        from(r in Response,
          where: r.id == ^response_id,
          lock: "FOR UPDATE"
        )
        |> Repo.one()

      cond do
        is_nil(response) ->
          Repo.rollback(:not_found)

        response.capture_instance_id != capture_id ->
          {:fenced, response.capture_instance_id}

        new_offset < response.bytes_uploaded ->
          # Out-of-order ACK or replay. Treat as success but don't move backwards.
          {:ok, response}

        true ->
          {1, [updated]} =
            from(r in Response, where: r.id == ^response.id, select: r)
            |> Repo.update_all(
              set: [
                bytes_uploaded: new_offset,
                last_upload_ack_at: now,
                state:
                  if(response.state in ["pending", "recording"],
                    do: "recording",
                    else: response.state
                  )
              ]
            )

          {:ok, updated}
      end
    end)
    |> case do
      {:ok, {:ok, response}} -> {:ok, response}
      {:ok, {:fenced, current}} -> {:fenced, current}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Promote a response to `capture_complete` and stamp expected_total_bytes.

  This is the only signal that enqueues finalization (PLAN §5.1).

  Returns `{:ok, response}` once the row is in a finalize-eligible state,
  `{:fenced, current}` if the caller is no longer the writer, or
  `{:error, term}`.
  """
  def record_capture_complete(response_id, capture_id, expected_total_bytes)
      when is_integer(expected_total_bytes) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      response =
        from(r in Response,
          where: r.id == ^response_id,
          lock: "FOR UPDATE"
        )
        |> Repo.one()

      cond do
        is_nil(response) ->
          Repo.rollback(:not_found)

        response.capture_instance_id != capture_id ->
          {:fenced, response.capture_instance_id}

        response.state in [
          "capture_complete",
          "uploading",
          "upload_complete",
          "finalizing",
          "ready"
        ] ->
          {:ok, response}

        true ->
          {1, [updated]} =
            from(r in Response, where: r.id == ^response.id, select: r)
            |> Repo.update_all(
              set: [
                state: "capture_complete",
                expected_total_bytes: expected_total_bytes,
                capture_completed_at: now
              ]
            )

          {:ok, updated}
      end
    end)
    |> case do
      {:ok, {:ok, response}} -> {:ok, response}
      {:ok, {:fenced, current}} -> {:fenced, current}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Mark a response `finalizing` (called by the finalizer worker before it
  runs ffmpeg) so the UI can reflect progress.
  """
  def mark_finalizing(response_id) do
    {1, [updated]} =
      from(r in Response,
        where: r.id == ^response_id and r.state == "capture_complete",
        select: r
      )
      |> Repo.update_all(set: [state: "finalizing"])

    {:ok, updated}
  rescue
    _ in MatchError -> {:error, :wrong_state}
  end

  @doc """
  Mark a response `ready` after a successful finalize, apply the
  template_version retake policy to `session_questions.selected_response_id`,
  then attempt the session-level rollup (PLAN §3.2 state machine, §3.4
  versioning rule).
  """
  def mark_ready(response_id, attrs) when is_map(attrs) do
    now = DateTime.utc_now()

    set =
      attrs
      |> Map.take([:storage_key, :duration_ms, :format])
      |> Map.put(:state, "ready")
      |> Map.put(:finalized_at, now)
      |> Map.put(:upload_completed_at, now)
      |> Enum.to_list()

    {1, [updated]} =
      from(r in Response, where: r.id == ^response_id, select: r)
      |> Repo.update_all(set: set)

    apply_retake_policy(updated)
    rollup_session(updated.session_id)
    maybe_enqueue_transcript(updated)
    {:ok, updated}
  end

  defp maybe_enqueue_transcript(%Response{id: id}) do
    if Interview.Transcripts.enabled?() do
      {:ok, _job} =
        %{"response_id" => id}
        |> Interview.Workers.WhisperTranscript.new()
        |> Oban.insert()
    end

    :ok
  end

  @doc """
  Set the transcript on a `question_response` (PLAN decision #9).
  Idempotent: a non-nil `transcript_ready_at` blocks subsequent writes.
  """
  def set_transcript(response_id, text, provider)
      when is_binary(response_id) and is_binary(text) and is_binary(provider) do
    now = DateTime.utc_now()

    {n, _} =
      from(r in Response,
        where: r.id == ^response_id and is_nil(r.transcript_ready_at)
      )
      |> Repo.update_all(
        set: [
          transcript_text: text,
          transcript_provider: provider,
          transcript_ready_at: now
        ]
      )

    if n > 0, do: :ok, else: :already_set
  end

  # PLAN §3.2: `first_only` keeps the first ready attempt as the selection
  # forever; `last` always points to the most recent ready attempt and
  # supersedes the previous selection so it's no longer pickable. `best`
  # is deferred.
  defp apply_retake_policy(%Response{state: "ready"} = response) do
    session = Repo.get!(Session, response.session_id)
    version = Repo.get!(Version, session.template_version_id)
    mode = (version.retake_policy || %{})["mode"] || "first_only"

    sq =
      get_session_question(session.id, response.template_question_id) ||
        materialise_session_question(session, response.template_question_id)

    case mode do
      "first_only" ->
        if is_nil(sq.selected_response_id) do
          sq
          |> SessionQuestion.changeset(%{selected_response_id: response.id})
          |> Repo.update!()
        end

      "last" ->
        prior = sq.selected_response_id

        sq
        |> SessionQuestion.changeset(%{selected_response_id: response.id})
        |> Repo.update!()

        # The prior selection is no longer the chosen attempt; mark it
        # superseded so retention/UI treats it as such (PLAN §5.1).
        if prior && prior != response.id do
          from(r in Response, where: r.id == ^prior and r.state == "ready")
          |> Repo.update_all(set: [state: "superseded"])
        end

      _other ->
        :ok
    end
  end

  defp apply_retake_policy(_), do: :ok

  defp materialise_session_question(%Session{} = session, template_question_id) do
    question = Repo.get!(Question, template_question_id)

    %SessionQuestion{}
    |> SessionQuestion.changeset(%{
      session_id: session.id,
      template_question_id: question.id,
      position: question.position
    })
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:session_id, :template_question_id]
    )

    get_session_question(session.id, template_question_id)
  end

  @doc """
  Mark a response `failed` (terminal). Records the error message.
  """
  def mark_failed(response_id, code, message) do
    {1, [updated]} =
      from(r in Response, where: r.id == ^response_id, select: r)
      |> Repo.update_all(
        set: [
          state: "failed",
          last_error_code: to_string(code),
          last_error_message: to_string(message)
        ]
      )

    {:ok, updated}
  end

  @doc """
  Promote a session to `failed` and fire the `session.failed` webhook
  (PLAN §3.1, §3.2). Idempotent — if the session is already in a terminal
  state we leave it alone but still de-dupe the webhook by
  `(session_id, event_type)`.
  """
  def fail_session(session_id, reason \\ nil) do
    session = Repo.get(Session, session_id)

    cond do
      is_nil(session) ->
        :ok

      session.state in ["failed", "expired"] ->
        :ok

      true ->
        {n, _} =
          from(s in Session,
            where: s.id == ^session_id and s.state not in ["failed", "expired"]
          )
          |> Repo.update_all(set: [state: "failed", completed_at: DateTime.utc_now()])

        if n > 0 do
          updated = Repo.get!(Session, session_id)
          _ = Interview.Webhooks.enqueue(updated, "session.failed", %{"reason" => reason})
          broadcast_session_state(updated)
        end

        :ok
    end
  end

  # ---- Session rollup / submit ------------------------------------------

  @doc """
  Promote a session from `submitted` → `ready` once every required
  question has at least one `ready` response (PLAN §3.2 state machine).

  Idempotent. Optional questions with no response or with only
  `superseded`/`abandoned` rows do not block rollup.
  """
  def rollup_session(session_id) do
    session = Repo.get(Session, session_id)

    cond do
      is_nil(session) ->
        :ok

      session.state != "submitted" ->
        :ok

      required_questions_all_ready?(session) ->
        {n, _} =
          from(s in Session, where: s.id == ^session_id and s.state == "submitted")
          |> Repo.update_all(set: [state: "ready", completed_at: DateTime.utc_now()])

        if n > 0 do
          updated = Repo.get!(Session, session_id)
          _ = Interview.Webhooks.enqueue(updated, "session.ready")
          broadcast_session_state(updated)
          maybe_enqueue_scoring(updated)
        end

        :ok

      true ->
        :ok
    end
  end

  @doc """
  Phoenix.PubSub topic for session state changes (PLAN §3.3). PG2 adapter
  per PLAN §12.5 — never the Postgres LISTEN/NOTIFY adapter over Neon.
  """
  def session_topic(session_id) when is_binary(session_id), do: "session:" <> session_id

  # Enqueue scoring on the submitted→ready transition (fires once). Whisper
  # transcripts are still landing at this point, so the worker snoozes via
  # ScoringExport :not_ready until they're in — we enqueue here rather than
  # gate on transcript readiness (rollup runs at finalize, before Whisper, so
  # a readiness gate would never fire). Skip entirely when transcripts are
  # off: scoring needs answer_text, so without them the worker would snooze
  # forever. The worker's `unique` collapses any duplicate enqueue.
  defp maybe_enqueue_scoring(%Session{} = session) do
    if Interview.Transcripts.enabled?() do
      _ =
        %{session_id: session.id}
        |> Interview.Workers.ScorePipeline.new()
        |> Oban.insert()
    end

    :ok
  end

  defp broadcast_session_state(%Session{} = session) do
    Phoenix.PubSub.broadcast(
      Interview.PubSub,
      session_topic(session.id),
      {:session_state, session.state, session.id}
    )
  end

  defp required_questions_all_ready?(%Session{} = session) do
    required_qids =
      from(q in Question,
        where: q.template_version_id == ^session.template_version_id and q.required == true,
        select: q.id
      )
      |> Repo.all()

    Enum.all?(required_qids, fn qid ->
      Repo.exists?(
        from(r in Response,
          where:
            r.session_id == ^session.id and
              r.template_question_id == ^qid and
              r.state == "ready"
        )
      )
    end)
  end

  @doc """
  Move a session from `pending`/`in_progress` → `submitted` once every
  required question has a response that has reached `capture_complete` or
  beyond (i.e., the bytes are accepted; finalize may still be running).

  Returns `{:ok, session}` on success, `{:error, {:required_unmet,
  question_ids}}` if any required question still has no acceptable
  response, or `{:error, :wrong_state}` if the session can't transition.
  """
  def submit_session(%Session{} = session) do
    cond do
      session.state in ["submitted", "ready"] ->
        {:ok, session}

      session.state not in ["pending", "in_progress"] ->
        {:error, :wrong_state}

      true ->
        do_submit(session)
    end
  end

  defp do_submit(%Session{} = session) do
    accepted = ~w(capture_complete uploading upload_complete finalizing ready)

    required_qids =
      from(q in Question,
        where: q.template_version_id == ^session.template_version_id and q.required == true,
        select: q.id
      )
      |> Repo.all()

    unmet =
      Enum.filter(required_qids, fn qid ->
        not Repo.exists?(
          from(r in Response,
            where:
              r.session_id == ^session.id and
                r.template_question_id == ^qid and
                r.state in ^accepted
          )
        )
      end)

    if unmet == [] do
      {1, [updated]} =
        from(s in Session,
          where: s.id == ^session.id and s.state in ["pending", "in_progress"],
          select: s
        )
        |> Repo.update_all(set: [state: "submitted"])

      _ = Interview.Webhooks.enqueue(updated, "session.submitted")

      Interview.Audit.log!(%{
        tenant_id: updated.tenant_id,
        actor_kind: "candidate",
        action: "session.submit",
        subject_kind: "session",
        subject_id: updated.id
      })

      # The last finalize may have already finished; rollup may immediately
      # promote to `ready`.
      rollup_session(session.id)
      {:ok, Repo.get!(Session, updated.id)}
    else
      {:error, {:required_unmet, unmet}}
    end
  end

  # ---- Sweepers ----------------------------------------------------------

  @doc """
  Find sessions whose `last_client_seen_at` is older than `cutoff` and
  that have at least one response not in a terminal state. Returns a
  list of (session_id, response_ids_to_abandon) tuples.
  """
  def stale_responses(cutoff) when is_struct(cutoff, DateTime) do
    from(r in Response,
      join: s in Session,
      on: s.id == r.session_id,
      where: r.state in ["pending", "recording", "uploading", "capture_complete", "finalizing"],
      where: not is_nil(s.last_client_seen_at) and s.last_client_seen_at < ^cutoff,
      select: r.id
    )
    |> Repo.all()
  end

  def mark_abandoned(response_ids) when is_list(response_ids) do
    {n, _} =
      from(r in Response, where: r.id in ^response_ids)
      |> Repo.update_all(set: [state: "abandoned"])

    {:ok, n}
  end

  @doc """
  Soft-delete a session: stamp `deleted_at`, enqueue
  `Interview.Workers.SessionDeletion` (which scrubs storage and fires the
  `session.deleted` webhook), and write an audit log entry.

  Required `audit` keys: `:actor_kind` and `:actor_id`. Optional:
  `:ip_address`, `:user_agent`. Idempotent — re-deleting a soft-deleted
  session returns `{:ok, :already_deleted}` without re-enqueuing.

  Returns `{:ok, :deleted}` on the first call, `{:ok, :already_deleted}`
  on subsequent calls, `{:error, :not_found}` if the session id is
  unknown.
  """
  def soft_delete_session(session_id, audit) when is_binary(session_id) and is_map(audit) do
    case Repo.get(Session, session_id) do
      nil ->
        {:error, :not_found}

      %Session{deleted_at: deleted_at} when not is_nil(deleted_at) ->
        {:ok, :already_deleted}

      %Session{} = session ->
        {1, _} =
          from(s in Session, where: s.id == ^session.id and is_nil(s.deleted_at))
          |> Repo.update_all(set: [deleted_at: DateTime.utc_now()])

        {:ok, _job} =
          %{
            "session_id" => session.id,
            "reason" => "right_to_delete",
            "actor_kind" => Map.fetch!(audit, :actor_kind),
            "actor_id" => Map.get(audit, :actor_id),
            "emit_webhook" => true
          }
          |> Interview.Workers.SessionDeletion.new()
          |> Oban.insert()

        Interview.Audit.log!(%{
          tenant_id: session.tenant_id,
          actor_kind: Map.fetch!(audit, :actor_kind),
          actor_id: Map.get(audit, :actor_id),
          action: "session.delete_request",
          subject_kind: "session",
          subject_id: session.id,
          ip_address: Map.get(audit, :ip_address),
          user_agent: Map.get(audit, :user_agent)
        })

        {:ok, :deleted}
    end
  end
end
