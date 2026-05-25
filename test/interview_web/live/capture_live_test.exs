defmodule InterviewWeb.CaptureLiveTest do
  use InterviewWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Interview.Fixtures

  import Ecto.Query

  alias Interview.Auth.Bootstrap
  alias Interview.Capture
  alias Interview.Capture.Response
  alias Interview.Repo

  defp capture_path(session) do
    token = bootstrap_token!(session)
    ~p"/capture/#{session.id}?token=#{token}"
  end

  # Test helper: seed a `Response` row on the session so that the
  # capture LV's initial_phase/2 (which checks `any_responses?/1`)
  # routes to :prep instead of :intro. Used by tests that want to
  # exercise the question-flow surface and don't care about the
  # intro gate.
  defp seed_existing_response!(session, question) do
    {:ok, _r} =
      %Response{
        session_id: session.id,
        template_question_id: question.id,
        attempt_number: 1,
        state: "pending"
      }
      |> Repo.insert()

    session
  end

  # Test helper: simulate the candidate accepting the intro gate.
  # The intro screen gates the "I'm ready" button behind a granted
  # camera/mic permission, so we simulate that first via the same
  # `permission` hook event the real JS recorder fires after a
  # successful getUserMedia call.
  defp accept_intro!(view) do
    render_hook(view, "permission", %{"state" => "granted"})
    view |> element("button", "I'm ready") |> render_click()
    view
  end

  test "GET /capture/:id lands on the intro gate for a fresh session", %{conn: conn} do
    # Fresh sessions (no responses) drop the candidate on the intro
    # screen with the AI-evaluation disclosure, not Q1 directly.
    %{session: session} = graph!()

    {:ok, _view, html} = live(conn, capture_path(session))
    assert html =~ "Interview"
    assert html =~ session.id
    assert html =~ "Welcome"
    refute html =~ "Question 1 of 1"
  end

  test "GET /capture/:id without token renders awaiting-auth view", %{conn: conn} do
    %{session: session} = graph!()

    {:ok, _view, html} = live(conn, ~p"/capture/#{session.id}")
    assert html =~ "Loading"
    refute html =~ "Question 1"
  end

  test "GET /capture/:id with consumed token renders rejected view", %{conn: conn} do
    %{session: session} = graph!()
    token = bootstrap_token!(session)
    # Consume once via direct call.
    assert {:ok, _} = Bootstrap.consume(token)

    conn = get(conn, ~p"/capture/#{session.id}?token=#{token}")
    body = html_response(conn, 200)
    assert body =~ "Session unavailable"
    assert body =~ "already been used"
    assert conn.status == 200, "must not redirect — iframe etiquette"
  end

  test "auth event consumes token + transitions out of awaiting-auth", %{conn: conn} do
    %{session: session} = graph!()
    token = bootstrap_token!(session)

    {:ok, view, _html} = live(conn, ~p"/capture/#{session.id}")
    assert render(view) =~ "Loading"

    reply = render_hook(view, "auth", %{"token" => token})
    # render_hook does not return :reply payload (per AGENTS.md gotcha) —
    # observe transition via the rendered HTML instead. A fresh session
    # exits :awaiting_auth into :intro (the new disclosure gate); the
    # question screen is one click away.
    _ = reply
    html = render(view)
    refute html =~ "Loading"
    assert html =~ "Welcome"
  end

  test "duplicate auth event after authentication is idempotent (hook remount)", %{conn: conn} do
    # Phase transition `:awaiting_auth` → `:prep` swaps the hook's DOM element,
    # so the hook re-mounts and re-fires `ready`; the SDK responds with a
    # second `auth`. The token is single-use, so re-consume would fail —
    # the LV must dedupe and reuse the already-minted upload bearer.
    %{session: session} = graph!()
    token = bootstrap_token!(session)

    {:ok, view, _html} = live(conn, ~p"/capture/#{session.id}")
    render_hook(view, "auth", %{"token" => token})
    state1 = :sys.get_state(view.pid)
    bearer1 = state1.socket.assigns.upload_bearer
    assert state1.socket.assigns.phase != :awaiting_auth
    refute state1.socket.assigns.rejected

    # Second auth with the same (now-consumed) token must NOT flip to rejected.
    render_hook(view, "auth", %{"token" => token})
    state2 = :sys.get_state(view.pid)
    refute state2.socket.assigns.rejected
    assert state2.socket.assigns.upload_bearer == bearer1
  end

  test "auth event captures parentOrigin from the hook's relayed payload", %{conn: conn} do
    %{session: session} = graph!()
    token = bootstrap_token!(session)

    {:ok, view, _html} = live(conn, ~p"/capture/#{session.id}")
    render_hook(view, "auth", %{"token" => token, "parentOrigin" => "https://customer-a.com"})

    state = :sys.get_state(view.pid)
    assert state.socket.assigns.parent_origin == "https://customer-a.com"
    assert state.socket.assigns.phase != :awaiting_auth
  end

  test "auth event ignores blank/null parentOrigin (URL-fallback path)", %{conn: conn} do
    %{session: session} = graph!()
    token = bootstrap_token!(session)

    {:ok, view, _html} = live(conn, ~p"/capture/#{session.id}")
    render_hook(view, "auth", %{"token" => token, "parentOrigin" => "null"})

    state = :sys.get_state(view.pid)
    refute state.socket.assigns.parent_origin
  end

  test "submit pushes session_submitted/session_ready to the parent", %{conn: conn} do
    %{session: session, questions: [q1]} =
      graph_with_questions!([%{required: true, max_answer_seconds: 60, prompt_text: "Q"}])

    {:ok, view, _html} = live(conn, capture_path(session))

    simulate_answer(view, session, q1, attempt: 1, capture_id: "cap-1")
    render_click(view, "advance")
    render_click(view, "submit")

    assert_push_event(view, "post_to_parent", %{type: "session_submitted", sessionId: _})
    assert_push_event(view, "post_to_parent", %{type: "session_ready", sessionId: _})
  end

  test "async rollup_session broadcast emits session_ready to the parent", %{conn: conn} do
    %{session: session} = graph!(%{question: %{required: false}})
    {:ok, view, _html} = live(conn, capture_path(session))

    # Move the session to submitted manually so rollup_session is allowed
    # to roll it forward when triggered out-of-band.
    Repo.update_all(
      from(s in Interview.Capture.Session, where: s.id == ^session.id),
      set: [state: "submitted"]
    )

    Capture.rollup_session(session.id)

    assert_push_event(view, "post_to_parent", %{type: "session_ready", sessionId: _})
  end

  test "fail_session broadcast emits an error postMessage to the parent", %{conn: conn} do
    %{session: session} = graph!()
    {:ok, view, _html} = live(conn, capture_path(session))

    Capture.fail_session(session.id, "no_bytes")

    assert_push_event(view, "post_to_parent", %{type: "error", code: "session_failed"})
  end

  test "GET /capture/:id renders inline not-found instead of redirecting", %{conn: conn} do
    bogus = "00000000-0000-0000-0000-000000000000"

    conn = get(conn, ~p"/capture/#{bogus}")
    body = html_response(conn, 200)

    assert body =~ "Session not found"
    refute body =~ "Use the recorder controls"
    assert conn.status == 200, "must not redirect — iframe etiquette"

    csp = get_resp_header(conn, "content-security-policy") |> List.first() || ""
    assert csp =~ "frame-ancestors"

    xfo = get_resp_header(conn, "x-frame-options")
    assert xfo == [], "embed pipeline must strip X-Frame-Options"
  end

  describe "disconnected mount (Iron Law fix)" do
    test "disconnected HTTP mount renders a Connecting shell, not the full UI",
         %{conn: conn} do
      # The initial HTTP GET should NOT run ensure_session_questions or
      # any of the heavier DB work. We verify by asserting the rendered
      # HTML is the Connecting shell, not the intro/question UI.
      %{session: session} = graph!()
      conn = get(conn, capture_path(session))
      body = html_response(conn, 200)

      assert body =~ "Connecting"
      assert body =~ "Establishing a secure connection"
      refute body =~ "Welcome"
      refute body =~ "Question 1 of 1"
      # The recorder hook shouldn't be present on this disconnected
      # response — the WebSocket isn't open yet and we don't want a
      # mount/destroy cycle for nothing.
      refute body =~ ~s|phx-hook="Recorder"|
    end

    test "disconnected mount with a bogus token still surfaces rejection", %{conn: conn} do
      # The cheap auth peek runs on disconnected so the candidate sees
      # the rejected state on first paint, not a Connecting→Rejected
      # flash. Verify by hitting a session with a consumed token.
      %{session: session} = graph!()
      token = bootstrap_token!(session)
      assert {:ok, _} = Bootstrap.consume(token)

      conn = get(conn, ~p"/capture/#{session.id}?token=#{token}")
      body = html_response(conn, 200)

      assert body =~ "Session unavailable"
      refute body =~ "Connecting"
    end

    test "connected mount runs the full DB setup and surfaces the intro",
         %{conn: conn} do
      # The LiveViewTest live/2 helper runs both mounts; the connected
      # mount is what populates assigns from the DB. Verify by checking
      # final HTML reflects the fully-loaded state.
      %{session: session} = graph!()
      {:ok, view, _html} = live(conn, capture_path(session))

      # Final connected HTML should be the intro (fresh session) — not
      # the Connecting shell, which only the disconnected pass renders.
      html = render(view)
      assert html =~ "Welcome"
      refute html =~ "Connecting"
    end
  end

  describe "intro / permission-denied gate" do
    test "fresh (pending) session lands on the intro screen, not the recorder",
         %{conn: conn} do
      %{session: session} = graph!(%{session: %{state: "pending"}})
      {:ok, view, html} = live(conn, capture_path(session))

      assert html =~ "Welcome"
      # Apostrophe is HTML-escaped in the rendered output.
      assert html =~ "I&#39;m ready"
      assert html =~ "transcribed and scored by AI"
      refute html =~ "Question 1 of 1"

      state = :sys.get_state(view.pid)
      assert state.socket.assigns.phase == :intro
    end

    test "mid-interview session (existing responses) skips the intro",
         %{conn: conn} do
      # A session with at least one recorded response means the candidate
      # already accepted the gate on a prior page-load. Bouncing them
      # back through it would be annoying.
      %{session: session, question: question} = graph!()
      seed_existing_response!(session, question)

      {:ok, view, html} = live(conn, capture_path(session))

      assert html =~ "Question 1 of 1"
      refute html =~ "Welcome"
      state = :sys.get_state(view.pid)
      assert state.socket.assigns.phase == :prep
    end

    test "clicking 'I'm ready' transitions to :prep", %{conn: conn} do
      %{session: session} = graph!(%{session: %{state: "pending"}})
      {:ok, view, _html} = live(conn, capture_path(session))

      # The "I'm ready" CTA is gated behind a granted camera/mic
      # permission. Simulate the recorder hook's `permission` event
      # firing on a successful getUserMedia call.
      render_hook(view, "permission", %{"state" => "granted"})
      view |> element("button", "I'm ready") |> render_click()

      state = :sys.get_state(view.pid)
      assert state.socket.assigns.phase == :prep
      assert render(view) =~ "Question 1 of 1"
    end

    test "the I'm ready CTA is hidden until permission is granted",
         %{conn: conn} do
      %{session: session} = graph!(%{session: %{state: "pending"}})
      {:ok, view, html} = live(conn, capture_path(session))

      # The button itself is gated; the surrounding intro copy mentions
      # the button text by name, so we check for the actual button
      # element rather than a substring match on the text.
      refute html =~ ~s|phx-click="intro_ready"|
      assert html =~ "Allow camera and microphone above"

      render_hook(view, "permission", %{"state" => "granted"})
      state = :sys.get_state(view.pid)
      assert state.socket.assigns.permission_state == "granted"
      assert render(view) =~ ~s|phx-click="intro_ready"|
    end

    test "permission denied during :intro routes to :permission_denied", %{conn: conn} do
      %{session: session} = graph!(%{session: %{state: "pending"}})
      {:ok, view, _html} = live(conn, capture_path(session))

      render_hook(view, "permission", %{"state" => "denied"})

      state = :sys.get_state(view.pid)
      assert state.socket.assigns.phase == :permission_denied
      assert render(view) =~ "Camera access"
      assert render(view) =~ "How to re-enable access"
    end

    test "permission denied during :prep also routes to :permission_denied",
         %{conn: conn} do
      %{session: session} = graph!()
      {:ok, view, _html} = live(conn, capture_path(session))

      render_hook(view, "permission", %{"state" => "denied"})

      state = :sys.get_state(view.pid)
      assert state.socket.assigns.phase == :permission_denied
    end

    test "permission denied during :recording does NOT change phase", %{conn: conn} do
      # The candidate is mid-take; yanking them out to a denial screen
      # would discard the in-flight capture. Existing recorder_error
      # paths handle this case; the gate-screen handler must not.
      %{session: session} = graph!()
      {:ok, view, _html} = live(conn, capture_path(session))

      render_hook(view, "recorder_started", %{
        "captureInstanceId" => "cap-test",
        "mimeType" => "video/webm"
      })

      assert :sys.get_state(view.pid).socket.assigns.phase == :recording
      render_hook(view, "permission", %{"state" => "denied"})
      assert :sys.get_state(view.pid).socket.assigns.phase == :recording
    end

    test "permission_denied_retry returns to :prep + resets permission_state",
         %{conn: conn} do
      %{session: session} = graph!(%{session: %{state: "pending"}})
      {:ok, view, _html} = live(conn, capture_path(session))

      # Walk: :intro → permission granted → click I'm ready → :prep →
      # then a later permission flip to denied → :permission_denied →
      # retry → :prep.
      render_hook(view, "permission", %{"state" => "granted"})
      view |> element("button", "I'm ready") |> render_click()
      render_hook(view, "permission", %{"state" => "denied"})
      assert :sys.get_state(view.pid).socket.assigns.phase == :permission_denied

      view |> element("button", "try again") |> render_click()

      state = :sys.get_state(view.pid)
      assert state.socket.assigns.phase == :prep
      assert state.socket.assigns.permission_state == "idle"
      assert is_nil(state.socket.assigns.last_error)
    end

    test "Release camera button is not in the recorder UI", %{conn: conn} do
      %{session: session} = graph!()
      {:ok, _view, html} = live(conn, capture_path(session))

      refute html =~ "Release camera"
      refute html =~ ~s|data-action="release"|
    end

    test "intro_ready re-pushes set_question + auth_acked for the recorder hook",
         %{conn: conn} do
      # The recorder hook is now mounted during :intro (so the candidate
      # can grant permission before the gate clears), so set_question
      # and auth_acked emitted at mount_authenticated time already
      # reach it. We still re-push from intro_ready defensively — a
      # reconnect or hook remount between mount and the I'm-ready click
      # could otherwise leave the hook without question metadata.
      %{session: session} = graph!(%{session: %{state: "pending"}})
      {:ok, view, _html} = live(conn, capture_path(session))

      render_hook(view, "permission", %{"state" => "granted"})
      view |> element("button", "I'm ready") |> render_click()

      assert_push_event(view, "set_question", %{questionIndex: _, maxAnswerSeconds: _})
      assert_push_event(view, "auth_acked", %{uploadBearer: bearer})
      assert is_binary(bearer)
    end
  end

  describe "focus telemetry" do
    test "focus_lost during :recording inserts a focus event row", %{conn: conn} do
      %{session: session, question: question} = graph!()
      seed_existing_response!(session, question)
      {:ok, view, _html} = live(conn, capture_path(session))

      # Transition into :recording the same way the real flow does.
      render_hook(view, "recorder_started", %{
        "captureInstanceId" => "cap-test",
        "mimeType" => "video/webm"
      })

      # Need a response_id on the socket for the persistence path.
      :sys.replace_state(view.pid, fn s ->
        # Find any response row to attach for the test.
        r = Repo.one(from(r in Response, where: r.session_id == ^session.id, limit: 1))
        socket = %{s.socket | assigns: Map.put(s.socket.assigns, :response_id, r.id)}
        %{s | socket: socket}
      end)

      iso = DateTime.utc_now() |> DateTime.to_iso8601()
      render_hook(view, "focus_lost", %{"at" => iso})

      response_id = :sys.get_state(view.pid).socket.assigns.response_id
      assert Capture.count_focus_losses(response_id) == 1
    end

    test "focus_lost outside :recording is silently dropped", %{conn: conn} do
      %{session: session, question: question} = graph!()
      seed_existing_response!(session, question)
      {:ok, view, _html} = live(conn, capture_path(session))
      # Stay in :prep — no recording started.

      iso = DateTime.utc_now() |> DateTime.to_iso8601()
      render_hook(view, "focus_lost", %{"at" => iso})

      r = Repo.one(from(r in Response, where: r.session_id == ^session.id, limit: 1))
      assert Capture.count_focus_losses(r.id) == 0
    end

    test "duplicate focus events (same response_id + occurred_at + kind) no-op",
         %{conn: conn} do
      # Browsers (Safari especially) fire blur + visibilitychange in the
      # same tick. The hook coalesces but if a duplicate slips through
      # the server-side unique constraint catches it.
      %{session: session, question: question} = graph!()
      seed_existing_response!(session, question)
      {:ok, view, _html} = live(conn, capture_path(session))

      render_hook(view, "recorder_started", %{
        "captureInstanceId" => "cap-test",
        "mimeType" => "video/webm"
      })

      :sys.replace_state(view.pid, fn s ->
        r = Repo.one(from(r in Response, where: r.session_id == ^session.id, limit: 1))
        socket = %{s.socket | assigns: Map.put(s.socket.assigns, :response_id, r.id)}
        %{s | socket: socket}
      end)

      iso = DateTime.utc_now() |> DateTime.to_iso8601()
      render_hook(view, "focus_lost", %{"at" => iso})
      render_hook(view, "focus_lost", %{"at" => iso})

      response_id = :sys.get_state(view.pid).socket.assigns.response_id
      assert Capture.count_focus_losses(response_id) == 1
    end
  end

  describe "accessibility — aria-live countdown announcements" do
    test "renders a shared aria-live='polite' announcement target on authenticated pages",
         %{conn: conn} do
      %{session: session} = graph!()
      {:ok, _view, html} = live(conn, capture_path(session))

      assert html =~ ~s|id="countdown-announce"|
      assert html =~ ~s|aria-live="polite"|
      assert html =~ ~s|aria-atomic="true"|
      # Should be sr-only so it doesn't visually clutter the page.
      assert html =~ ~s|class="sr-only"|
    end

    test "does NOT render the announcement target while awaiting auth",
         %{conn: conn} do
      # :awaiting_auth uses its own minimal render clause (no shared
      # header), so the countdown target shouldn't bleed in there.
      %{session: session} = graph!()
      {:ok, _view, html} = live(conn, ~p"/capture/#{session.id}")

      refute html =~ ~s|id="countdown-announce"|
    end
  end

  describe "think-time + recording countdowns" do
    test "renders the think-time phrase when the question has think_time_seconds",
         %{conn: conn} do
      %{session: session, question: question} = graph!(%{question: %{think_time_seconds: 30}})
      seed_existing_response!(session, question)
      {:ok, _view, html} = live(conn, capture_path(session))

      assert html =~ ~s|phx-hook="ThinkTimeCountdown"|
      assert html =~ ~s|data-think-seconds="30"|
      assert html =~ "Recording begins in 30 seconds."
    end

    test "does NOT render the think-time phrase when think_time_seconds is nil/0",
         %{conn: conn} do
      %{session: session, question: question} = graph!(%{question: %{think_time_seconds: 0}})
      seed_existing_response!(session, question)
      {:ok, _view, html} = live(conn, capture_path(session))

      refute html =~ ~s|phx-hook="ThinkTimeCountdown"|
      refute html =~ "Recording begins in"
    end

    test "renders the recording-countdown overlay element inside the preview frame",
         %{conn: conn} do
      %{session: session, question: question} = graph!(%{question: %{max_answer_seconds: 90}})
      seed_existing_response!(session, question)
      {:ok, _view, html} = live(conn, capture_path(session))

      assert html =~ ~s|data-role="recording-countdown"|
      # `recording-countdown` is one of multiple class names on the
      # span; just confirm the marker class is present.
      assert html =~ "recording-countdown"
    end
  end

  describe "multi-question iteration" do
    setup do
      %{session: session, version: version, questions: [q1, q2, q3]} =
        graph_with_questions!(
          [
            %{required: true, max_answer_seconds: 60, prompt_text: "Why this role?"},
            %{required: false, max_answer_seconds: 30, prompt_text: "Optional"},
            %{required: true, max_answer_seconds: 90, prompt_text: "Tell me more"}
          ],
          version: %{retake_policy: %{"max_attempts" => 2, "mode" => "last"}}
        )

      {:ok, session: session, version: version, q1: q1, q2: q2, q3: q3}
    end

    test "advance walks through every question, then lands on review", ctx do
      {:ok, view, _html} = live(ctx.conn, capture_path(ctx.session))
      accept_intro!(view)
      assert render(view) =~ "Question 1 of 3"

      simulate_answer(view, ctx.session, ctx.q1, attempt: 1, capture_id: "cap-q1-a1")
      render_click(view, "advance")
      assert render(view) =~ "Question 2 of 3"

      # Skip optional Q2.
      render_click(view, "skip")
      assert render(view) =~ "Question 3 of 3"

      simulate_answer(view, ctx.session, ctx.q3, attempt: 1, capture_id: "cap-q3-a1")
      render_click(view, "advance")

      html = render(view)
      assert html =~ "A last"
      assert html =~ "Submit interview"
    end

    test "skip on a required question is rejected", ctx do
      {:ok, view, _html} = live(ctx.conn, capture_path(ctx.session))
      accept_intro!(view)
      render_click(view, "skip")
      html = render(view)
      assert html =~ "Question 1 of 3"
      assert html =~ "this question is required"
    end

    test "retake creates a new attempt and supersedes the prior on ready", ctx do
      {:ok, view, _html} = live(ctx.conn, capture_path(ctx.session))
      accept_intro!(view)

      simulate_answer(view, ctx.session, ctx.q1, attempt: 1, capture_id: "cap-q1-a1")

      assert render(view) =~ "Re-record"

      render_click(view, "retake")
      assert render(view) =~ "Question 1 of 3"

      simulate_answer(view, ctx.session, ctx.q1, attempt: 2, capture_id: "cap-q1-a2")

      r1 = Repo.get_by!(Response, session_id: ctx.session.id, attempt_number: 1)
      r2 = Repo.get_by!(Response, session_id: ctx.session.id, attempt_number: 2)
      assert r1.state == "superseded"
      assert r2.state == "ready"

      sq = Capture.get_session_question(ctx.session.id, ctx.q1.id)
      assert sq.selected_response_id == r2.id
    end

    test "retake is blocked once max_attempts is reached", ctx do
      {:ok, view, _html} = live(ctx.conn, capture_path(ctx.session))
      accept_intro!(view)

      simulate_answer(view, ctx.session, ctx.q1, attempt: 1, capture_id: "cap-q1-a1")
      render_click(view, "retake")
      simulate_answer(view, ctx.session, ctx.q1, attempt: 2, capture_id: "cap-q1-a2")

      # Hit retake again — version retake_policy max_attempts is 2.
      render_click(view, "retake")
      html = render(view)
      assert html =~ "max attempts (2) reached"
    end

    test "submit refuses when a required question is unanswered", ctx do
      {:ok, view, _html} = live(ctx.conn, capture_path(ctx.session))
      accept_intro!(view)

      simulate_answer(view, ctx.session, ctx.q1, attempt: 1, capture_id: "cap-q1-a1")
      render_click(view, "advance")
      render_click(view, "skip")

      # Q3 required + unanswered: clicking submit must NOT transition the
      # session to `submitted`. Submit handler runs regardless of phase
      # (no client-side gating); the DB state assertion is the load-bearing
      # one — submit_session/1 is the actual gate, and it returns
      # `{:error, {:required_unmet, …}}`.
      render_click(view, "submit")

      session = Repo.get!(Interview.Capture.Session, ctx.session.id)
      assert session.state == "in_progress"
      refute session.completed_at
    end

    test "submit promotes the session to submitted then ready once finalizers run",
         ctx do
      {:ok, view, _html} = live(ctx.conn, capture_path(ctx.session))
      accept_intro!(view)

      simulate_answer(view, ctx.session, ctx.q1, attempt: 1, capture_id: "cap-q1-a1")
      render_click(view, "advance")
      render_click(view, "skip")
      simulate_answer(view, ctx.session, ctx.q3, attempt: 1, capture_id: "cap-q3-a1")
      render_click(view, "advance")

      html = render_click(view, "submit")
      assert html =~ "Submitted"

      session = Repo.get!(Interview.Capture.Session, ctx.session.id)
      assert session.state == "ready"
      assert session.completed_at
    end
  end

  # ---- helpers --------------------------------------------------------

  # Drives the LiveView through the per-question recorder lifecycle without
  # actually running the JS hook: claim → recording → drain → ack. The
  # finalizer is short-circuited by calling Capture.mark_ready/2 directly.
  defp simulate_answer(view, session, question, opts) do
    attempt = Keyword.fetch!(opts, :attempt)
    capture_id = Keyword.fetch!(opts, :capture_id)

    render_hook(view, "claim_instance", %{
      "questionIndex" => question.position,
      "attemptNumber" => attempt,
      "captureInstanceId" => capture_id
    })

    response = Capture.get_response_by_attempt(session.id, question.id, attempt)
    refute is_nil(response), "claim_instance must have inserted a response row"
    rid = response.id

    render_hook(view, "recorder_started", %{
      "captureInstanceId" => capture_id,
      "mimeType" => "video/webm"
    })

    render_hook(view, "recorder_stopped", %{"durationMs" => 60_000})
    {:ok, _} = Capture.commit_offset(rid, capture_id, 1024)
    {:ok, _} = Capture.record_capture_complete(rid, capture_id, 1024)

    {:ok, _} =
      Capture.mark_ready(rid, %{
        storage_key: "k-#{capture_id}",
        duration_ms: 1000,
        format: "mp4"
      })

    # Tell the LiveView the upload acked (would normally come from the hook
    # after sendCaptureComplete returned 200).
    render_hook(view, "capture_complete_acked", %{"queuedBytes" => 0, "queuedChunks" => 0})

    %{response_id: rid, session: session, question: question}
  end
end
