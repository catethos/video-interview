defmodule InterviewWeb.CaptureLive do
  use InterviewWeb, :live_view

  require Logger

  alias Interview.Auth.{Bootstrap, Tokens}
  alias Interview.Capture
  alias Interview.Capture.Session

  # Per-question phase machine (within the candidate flow):
  #   :awaiting_auth     — page shown before bootstrap consumed; hook posts `ready`.
  #   :intro             — welcome screen + AI-evaluation disclosure + "I'm ready" gate.
  #   :permission_denied — candidate denied camera/mic permission; offers retry.
  #   :prep              — prompt visible, optional think-time countdown active.
  #   :recording         — MediaRecorder running.
  #   :draining          — MediaRecorder stopped; uploader still flushing IDB → tus.
  #   :answered          — capture_complete acked; question is done for this attempt.
  #   :review            — past the last question; review + submit screen.
  #   :submitted         — submit accepted by server; session.state = submitted/ready.
  #   :fenced            — another tab/instance took over the writer.

  @impl true
  def mount(%{"session_id" => session_id} = params, _session, socket) do
    socket = assign(socket, :session_id, session_id)

    case authenticate(params, session_id, connected?(socket)) do
      {:ok, %Session{} = session} ->
        {:ok, mount_authenticated(socket, session, connected?(socket))}

      :awaiting_auth ->
        {:ok, mount_awaiting_auth(socket, session_id)}

      :not_found ->
        # Render in-place rather than push_navigate to "/": the home page is
        # on the :browser pipeline and ships X-Frame-Options: DENY, so an
        # iframe redirected there is blocked. Staying on :embed keeps the
        # frame-ancestors CSP that lets the parent display this response.
        {:ok, assign(socket, :not_found, true) |> assign(:rejected, false)}

      {:rejected, reason} ->
        {:ok,
         socket
         |> assign(:not_found, false)
         |> assign(:rejected, true)
         |> assign(:rejected_reason, reason)}
    end
  end

  # ---- Auth ------------------------------------------------------------
  #
  # LiveView mounts twice: the HTTP GET ("disconnected") and the WebSocket
  # connect ("connected"). The bootstrap token is single-use, so we
  # `peek` on the first pass and `consume` on the second. Both reject the
  # same way for stale/consumed tokens.

  defp authenticate(%{"token" => token}, sid, connected?)
       when is_binary(token) and byte_size(token) > 0 do
    op = if connected?, do: &Bootstrap.consume/1, else: &Bootstrap.peek/1

    case op.(token) do
      {:ok, %Session{id: ^sid} = session} -> {:ok, session}
      {:ok, _other_session} -> {:rejected, :sid_mismatch}
      {:error, :session_not_found} -> :not_found
      {:error, reason} -> {:rejected, reason}
    end
  end

  defp authenticate(_params, sid, _connected?) do
    case Capture.fetch_session(sid) do
      {:ok, %Session{}} -> :awaiting_auth
      {:error, :not_found} -> :not_found
    end
  end

  defp mount_authenticated(socket, %Session{} = session, connected? \\ true) do
    Capture.ensure_session_questions(session)
    questions = Capture.list_questions(session)
    version = Capture.get_template_version!(session)
    prompt_asset_kinds = load_prompt_asset_kinds(questions)

    if connected? and not Map.get(socket.assigns, :pubsub_subscribed, false) do
      Phoenix.PubSub.subscribe(Interview.PubSub, Capture.session_topic(session.id))
    end

    upload_bearer =
      if connected? do
        bearer = Tokens.mint_upload_bearer(session.id)

        Interview.Audit.log!(%{
          tenant_id: session.tenant_id,
          actor_kind: "candidate",
          action: "upload_bearer.mint",
          subject_kind: "session",
          subject_id: session.id
        })

        bearer
      else
        nil
      end

    # The hook captures the parent origin from the first inbound v=1
    # postMessage and forwards it on the `auth` event; we keep whatever's
    # already in assigns (set by handle_event "auth") and otherwise nil.
    parent_origin = Map.get(socket.assigns, :parent_origin)

    socket =
      socket
      |> assign(:not_found, false)
      |> assign(:rejected, false)
      |> assign(:session, session)
      |> assign(:session_id, session.id)
      |> assign(:questions, questions)
      |> assign(:total_questions, length(questions))
      |> assign(:template_version, version)
      |> assign(:current_index, 0)
      |> assign(:phase, initial_phase(questions, session))
      |> assign(:permission_state, "idle")
      |> assign(:prompt_expanded, false)
      |> assign(:attachment_expanded, false)
      |> assign(:recorder_state, "idle")
      |> assign(:mime_type, nil)
      |> assign(:capture_instance_id, nil)
      |> assign(:response_id, nil)
      |> assign(:bytes_buffered_locally, 0)
      |> assign(:bytes_uploaded, 0)
      |> assign(:last_error, nil)
      |> assign(:capture_complete_acked, false)
      |> assign(:bitrate_step, 0)
      |> assign(:think_time_remaining, nil)
      |> assign(:last_recording_duration_ms, nil)
      |> assign(:too_short, false)
      |> assign(:submit_error, nil)
      |> assign(:session_state, session.state)
      |> assign(:upload_bearer, upload_bearer)
      |> assign(:parent_origin, parent_origin)
      |> assign(:pubsub_subscribed, connected?)
      |> assign(:prompt_asset_kinds, prompt_asset_kinds)
      |> push_set_question()

    socket =
      if connected? do
        push_event(socket, "auth_acked", %{uploadBearer: upload_bearer})
      else
        socket
      end

    # If the candidate lands on a session that's already past the gate,
    # tell the parent so it can render its `onSubmitted` / `onReady` UI.
    case session.state do
      "submitted" -> post_to_parent(socket, "session_submitted", %{sessionId: session.id})
      "ready" -> post_to_parent(socket, "session_ready", %{sessionId: session.id})
      _ -> socket
    end
  end

  defp mount_awaiting_auth(socket, session_id) do
    socket
    |> assign(:not_found, false)
    |> assign(:rejected, false)
    |> assign(:phase, :awaiting_auth)
    |> assign(:session_id, session_id)
  end

  defp initial_phase([], _session), do: :review
  defp initial_phase(_questions, %Session{state: "submitted"}), do: :submitted
  defp initial_phase(_questions, %Session{state: "ready"}), do: :submitted

  defp initial_phase(_questions, %Session{} = session) do
    # Sessions are inserted with state="in_progress" at /api/sessions
    # time (see session_controller.ex), so we can't use that field to
    # distinguish a fresh landing from a mid-interview reload. Use the
    # presence of recorded responses instead: if the candidate has any
    # answers stored, they've been past the intro gate already and we
    # send them straight to the current question. Otherwise show the
    # intro/disclosure screen.
    if Capture.any_responses?(session.id) do
      :prep
    else
      :intro
    end
  end

  # Map of `prompt_asset_id => "image" | "pdf" | "video" | …`. Used by
  # `render_attachment` to pick the right element (img / iframe / link).
  defp load_prompt_asset_kinds(questions) do
    import Ecto.Query, only: [from: 2]

    ids =
      questions
      |> Enum.flat_map(fn q -> [q.prompt_asset_id, q.attachment_asset_id] end)
      |> Enum.reject(&is_nil/1)

    case ids do
      [] ->
        %{}

      ids ->
        Interview.Repo.all(
          from(a in Interview.Templates.PromptAsset,
            where: a.id in ^ids,
            select: {a.id, a.kind}
          )
        )
        |> Map.new()
    end
  end

  # ---- Hook events ----------------------------------------------------

  @impl true
  def handle_event("auth", %{"token" => token} = payload, socket) do
    sid = socket.assigns.session_id

    socket = capture_parent_origin(socket, payload)

    case socket.assigns[:session] do
      # Phase transition (`:awaiting_auth` → `:prep`) swaps the hook's DOM
      # element, so the hook re-mounts and re-fires `ready`; the SDK
      # responds with another `auth`. Bootstrap is single-use — reuse the
      # bearer already minted on the first auth instead of re-consuming.
      %Session{id: ^sid} ->
        {:reply, %{ok: true, uploadBearer: socket.assigns[:upload_bearer]}, socket}

      _ ->
        case Bootstrap.consume(token) do
          {:ok, %Session{id: ^sid} = session} ->
            socket = mount_authenticated(socket, session)
            {:reply, %{ok: true, uploadBearer: socket.assigns[:upload_bearer]}, socket}

          {:ok, _other_session} ->
            {:reply, %{ok: false, error: "sid_mismatch"},
             assign(socket, :rejected, true) |> assign(:rejected_reason, :sid_mismatch)}

          {:error, reason} ->
            {:reply, %{ok: false, error: to_string(reason)},
             assign(socket, :rejected, true) |> assign(:rejected_reason, reason)}
        end
    end
  end

  def handle_event("refresh_upload_token", _payload, socket) do
    case socket.assigns[:session] do
      %Session{} = session ->
        bearer = Tokens.mint_upload_bearer(session.id)

        Interview.Audit.log!(%{
          tenant_id: session.tenant_id,
          actor_kind: "candidate",
          action: "upload_bearer.refresh",
          subject_kind: "session",
          subject_id: session.id
        })

        {:reply, %{token: bearer}, assign(socket, :upload_bearer, bearer)}

      _ ->
        {:reply, %{error: "not_authenticated"}, socket}
    end
  end

  def handle_event("recorder_ready", %{"mimeType" => mime}, socket) do
    {:noreply, assign(socket, mime_type: mime)}
  end

  def handle_event("toggle_prompt", _params, socket) do
    {:noreply, update(socket, :prompt_expanded, &(not &1))}
  end

  def handle_event("toggle_attachment", _params, socket) do
    {:noreply, update(socket, :attachment_expanded, &(not &1))}
  end

  def handle_event("permission_requesting", _params, socket) do
    {:noreply, assign(socket, :permission_state, "requesting")}
  end

  def handle_event("permission", %{"state" => state} = payload, socket) do
    # A "denied" permission while we're still in the intro/prep gating
    # phases routes the candidate to a dedicated screen with browser-
    # specific re-enable instructions. Once they're recording or past,
    # denial is a more disruptive event (existing flow handles it via
    # recorder_error / fence semantics) and we don't override phase
    # here so we don't yank context out from under an active capture.
    socket =
      socket
      |> assign(:permission_state, state)
      |> assign(:last_error, payload["error"])

    socket =
      if state == "denied" and socket.assigns.phase in [:intro, :prep] do
        assign(socket, :phase, :permission_denied)
      else
        socket
      end

    {:noreply, socket}
  end

  # Tab/window focus telemetry from the JS hook. Recorded only when
  # the candidate is actively recording — outside that window the
  # signal isn't useful (a tab-switch during think-time is just normal
  # multitasking). We never block on persistence: insert is best-effort
  # so a transient DB hiccup doesn't break the take.
  def handle_event("focus_lost", %{"at" => iso8601}, socket) do
    {:noreply, record_focus_event_if_recording(socket, "lost", iso8601)}
  end

  def handle_event("focus_regained", %{"at" => iso8601}, socket) do
    {:noreply, record_focus_event_if_recording(socket, "regained", iso8601)}
  end

  def handle_event("intro_ready", _params, socket) do
    # Candidate accepted the disclosure on the intro screen and is
    # ready to begin. Transition into the standard per-question flow.
    # The recorder hook mounts here for the first time, so we have to
    # re-emit the `set_question` and `auth_acked` events that fired
    # during mount_authenticated — those were pushed before the hook
    # existed in the DOM and have been lost. LiveView delivers events
    # pushed inside this handler AFTER the diff lands and the hook
    # has mounted, so the re-pushes reach the new hook reliably.
    socket =
      socket
      |> assign(:phase, :prep)
      |> push_set_question()

    socket =
      if bearer = socket.assigns[:upload_bearer] do
        push_event(socket, "auth_acked", %{uploadBearer: bearer})
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("permission_denied_retry", _params, socket) do
    # Drop back into :prep so the standard "Open camera" button is
    # available; clearing :last_error keeps the previous denial copy
    # from sticking around if the next request succeeds. We do NOT
    # auto-fire the permission request here — the candidate clicks
    # the camera button themselves so the gesture is browser-trusted
    # (some browsers require a user gesture per request).
    {:noreply,
     socket
     |> assign(:phase, :prep)
     |> assign(:permission_state, "idle")
     |> assign(:last_error, nil)}
  end

  def handle_event(
        "recorder_started",
        %{"captureInstanceId" => cid, "mimeType" => mime},
        socket
      ) do
    :telemetry.execute([:interview, :recorder, :started], %{}, %{
      session_id: socket.assigns[:session_id],
      response_id: socket.assigns[:response_id],
      capture_instance_id: cid,
      mime_type: mime
    })

    {:noreply,
     socket
     |> assign(:phase, :recording)
     |> assign(:recorder_state, "recording")
     |> assign(:capture_instance_id, cid)
     |> assign(:mime_type, mime)
     |> assign(:capture_complete_acked, false)
     |> assign(:too_short, false)
     |> assign(:think_time_remaining, nil)}
  end

  def handle_event(
        "claim_instance",
        %{
          "questionIndex" => qi,
          "attemptNumber" => an,
          "captureInstanceId" => cid
        },
        socket
      ) do
    qi = ensure_int(qi)
    an = ensure_int(an)

    with {:ok, capture_session} <- Capture.fetch_session(socket.assigns.session_id),
         {:ok, question} <- Capture.fetch_question_by_position(capture_session, qi),
         {:ok, response, previous} <- Capture.claim_instance(capture_session, question, an, cid) do
      if previous && previous != cid do
        Logger.info(
          "fence: superseded session=#{capture_session.id} q=#{qi} a=#{an} previous=#{previous} now=#{cid}"
        )
      end

      {:reply,
       %{
         ok: true,
         responseId: response.id,
         tusUrl: "/uploads/tus/#{response.id}/#{cid}",
         captureCompleteUrl:
           "/sessions/#{capture_session.id}/responses/#{response.id}/capture_complete",
         previous: previous
       },
       socket
       |> assign(:response_id, response.id)
       |> assign(:capture_instance_id, cid)}
    else
      {:error, reason} ->
        Logger.warning("claim_instance failed: #{inspect(reason)}")
        {:reply, %{ok: false, error: to_string(reason)}, socket}
    end
  end

  def handle_event(
        "fenced_notice",
        %{"current" => current_id, "yours" => yours},
        socket
      ) do
    msg = "fenced — another tab/instance took over (current=#{current_id}, yours=#{yours})"

    {:noreply,
     socket
     |> assign(:phase, :fenced)
     |> assign(:recorder_state, "fenced")
     |> assign(:last_error, msg)}
  end

  def handle_event("recorder_stopped", payload, socket) do
    duration = payload |> Map.get("durationMs") |> ensure_int_or_nil()

    :telemetry.execute([:interview, :recorder, :stopped], %{duration_ms: duration || 0}, %{
      session_id: socket.assigns[:session_id],
      response_id: socket.assigns[:response_id]
    })

    too_short =
      case current_question(socket) do
        nil -> false
        q -> below_min?(q, duration)
      end

    {:noreply,
     socket
     |> assign(:phase, :draining)
     |> assign(:recorder_state, "stopped")
     |> assign(:last_recording_duration_ms, duration)
     |> assign(:too_short, too_short)}
  end

  def handle_event(
        "buffer_progress",
        %{"bytesBuffered" => buffered, "bytesUploaded" => uploaded},
        socket
      ) do
    :telemetry.execute(
      [:interview, :recorder, :buffer],
      %{bytes_buffered: buffered, bytes_uploaded: uploaded},
      %{session_id: socket.assigns[:session_id], response_id: socket.assigns[:response_id]}
    )

    {:noreply,
     socket
     |> assign(:bytes_buffered_locally, buffered)
     |> assign(:bytes_uploaded, uploaded)}
  end

  def handle_event("capture_complete_acked", payload, socket) do
    drained_bytes = payload |> Map.get("queuedBytes", 0) |> ensure_int()
    drained_count = payload |> Map.get("queuedChunks", 0) |> ensure_int()

    :telemetry.execute(
      [:interview, :recorder, :capture_complete],
      %{queued_bytes: drained_bytes, queued_chunks: drained_count},
      %{session_id: socket.assigns[:session_id], response_id: socket.assigns[:response_id]}
    )

    if drained_bytes > 0 or drained_count > 0 do
      Logger.warning(
        "capture_complete sent with non-empty IDB queue: " <>
          "session=#{socket.assigns.session_id} response=#{socket.assigns.response_id} " <>
          "queued_bytes=#{drained_bytes} queued_chunks=#{drained_count}"
      )
    end

    {:noreply,
     socket
     |> assign(:phase, :answered)
     |> assign(:capture_complete_acked, true)}
  end

  def handle_event("recorder_error", %{"code" => code, "message" => message}, socket) do
    {:noreply, assign(socket, :last_error, "#{code}: #{message}")}
  end

  def handle_event("bitrate_stepped", %{"step" => step, "label" => label}, socket) do
    Logger.info(
      "recorder: bitrate stepped session=#{socket.assigns.session_id} step=#{step} label=#{label}"
    )

    :telemetry.execute([:interview, :recorder, :bitrate], %{step: step}, %{
      session_id: socket.assigns[:session_id],
      label: label
    })

    {:noreply, assign(socket, :bitrate_step, step)}
  end

  def handle_event("email_link_request", %{"email" => email, "url" => url}, socket) do
    Logger.info(
      "email_link_request session=#{socket.assigns.session_id} email=#{email} url=#{url}"
    )

    {:noreply, socket}
  end

  # ---- UI events ------------------------------------------------------

  def handle_event("advance", _payload, socket) do
    {:noreply, advance_or_review(socket)}
  end

  def handle_event("retake", _payload, socket) do
    case current_question(socket) do
      nil ->
        {:noreply, socket}

      q ->
        cap = Capture.max_attempts_for(q, socket.assigns.template_version)
        used = Capture.max_attempt_number(socket.assigns.session_id, q.id)

        if used >= cap do
          {:noreply,
           assign(socket, :last_error, "max attempts (#{cap}) reached for this question")}
        else
          {:noreply,
           socket
           |> assign(:phase, :prep)
           |> assign(:capture_complete_acked, false)
           |> assign(:too_short, false)
           |> assign(:last_recording_duration_ms, nil)
           |> assign(:bytes_buffered_locally, 0)
           |> assign(:bytes_uploaded, 0)
           |> assign(:response_id, nil)
           |> assign(:capture_instance_id, nil)
           |> push_set_question(used + 1)}
        end
    end
  end

  def handle_event("skip", _payload, socket) do
    case current_question(socket) do
      nil ->
        {:noreply, socket}

      %{required: true} ->
        {:noreply, assign(socket, :last_error, "this question is required")}

      _q ->
        {:noreply, advance_or_review(socket)}
    end
  end

  def handle_event("submit", _payload, socket) do
    {:ok, session} = Capture.fetch_session(socket.assigns.session_id)

    case Capture.submit_session(session) do
      {:ok, %Session{} = updated} ->
        socket =
          socket
          |> assign(:session, updated)
          |> assign(:session_state, updated.state)
          |> assign(:phase, :submitted)
          |> assign(:submit_error, nil)
          |> post_to_parent("session_submitted", %{sessionId: updated.id})

        # `submit_session/1` may already roll up to "ready" if every required
        # response was finalized synchronously (which is the test path; in
        # prod the finalizer is async and ready arrives later). Emit the
        # session_ready event in the same turn when the state has advanced.
        socket =
          if updated.state == "ready" do
            post_to_parent(socket, "session_ready", %{sessionId: updated.id})
          else
            socket
          end

        {:noreply, socket}

      {:error, {:required_unmet, qids}} ->
        positions =
          for q <- socket.assigns.questions, q.id in qids, do: q.position

        msg =
          "Please answer the required question" <>
            if(length(positions) > 1, do: "s", else: "") <>
            ": " <> Enum.map_join(positions, ", ", &"Q#{&1}")

        {:noreply, assign(socket, :submit_error, msg)}

      {:error, reason} ->
        {:noreply, assign(socket, :submit_error, to_string(reason))}
    end
  end

  def handle_event("think_time_tick", _payload, socket) do
    case socket.assigns.think_time_remaining do
      n when is_integer(n) and n > 1 ->
        {:noreply, assign(socket, :think_time_remaining, n - 1)}

      _ ->
        {:noreply, assign(socket, :think_time_remaining, 0)}
    end
  end

  # ---- PubSub: async session-state broadcasts ------------------------
  #
  # The finalizer rollup runs in an Oban worker and flips `sessions.state`
  # to `ready` (or `failed`) without a LiveView in the call stack. Before
  # Phase 4 we only emitted `session_ready` to the parent on the synchronous
  # `submit_session` path (the test path). Now `Capture.rollup_session/1`
  # and `Capture.fail_session/2` broadcast on `Capture.session_topic/1`,
  # and we relay the state change to the parent SDK via the same
  # `post_to_parent` push_event the synchronous path uses.
  #
  # Adapter is `Phoenix.PubSub` (PG2) — never the Postgres LISTEN/NOTIFY
  # adapter, per PLAN §12.5 (no LISTEN/NOTIFY over the Neon pooler).
  @impl true
  def handle_info({:session_state, "ready", session_id}, socket) do
    if socket.assigns[:session_id] == session_id do
      {:noreply,
       socket
       |> assign(:session_state, "ready")
       |> post_to_parent("session_ready", %{sessionId: session_id})}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:session_state, "failed", session_id}, socket) do
    if socket.assigns[:session_id] == session_id do
      {:noreply,
       socket
       |> assign(:session_state, "failed")
       |> post_to_parent("error", %{code: "session_failed", message: "session marked failed"})}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:session_state, _other, _session_id}, socket), do: {:noreply, socket}

  # ---- postMessage relay ---------------------------------------------
  #
  # The hook owns the actual `window.parent.postMessage` call (it knows the
  # parent origin). When the LV needs to fire an outbound protocol message
  # — e.g. `session_submitted` after a successful `submit_session` — it
  # `push_event "post_to_parent"` here and the hook relays it.
  #
  # `parent_origin` is captured from the inbound `auth` postMessage payload
  # (see `capture_parent_origin/2`) and stored in assigns purely so tests
  # and observability can verify it; the targetOrigin enforcement happens
  # in JS.

  defp capture_parent_origin(socket, payload) do
    case payload do
      %{"parentOrigin" => o} when is_binary(o) and o != "" and o != "null" ->
        assign(socket, :parent_origin, o)

      _ ->
        socket
    end
  end

  defp post_to_parent(socket, type, fields) when is_binary(type) and is_map(fields) do
    push_event(socket, "post_to_parent", Map.put(fields, :type, type))
  end

  # ---- Helpers --------------------------------------------------------

  defp current_question(%{assigns: a}), do: current_question(a)

  defp current_question(%{questions: qs, current_index: i})
       when i >= 0 and i < length(qs),
       do: Enum.at(qs, i)

  defp current_question(_), do: nil

  # Best-effort persistence of a tab-focus event from the JS hook.
  # Recorded only when the candidate is actively recording — outside
  # that window the signal isn't meaningful (think-time tab-switches
  # are just normal multitasking).
  defp record_focus_event_if_recording(socket, kind, iso8601) do
    with :recording <- socket.assigns.phase,
         rid when is_binary(rid) <- socket.assigns[:response_id],
         {:ok, at, _offset} <- DateTime.from_iso8601(iso8601) do
      _ = Capture.record_focus_event(rid, kind, at)
      socket
    else
      _ -> socket
    end
  end

  defp below_min?(_q, nil), do: false

  defp below_min?(%{min_answer_seconds: nil}, _ms), do: false
  defp below_min?(%{min_answer_seconds: 0}, _ms), do: false

  defp below_min?(%{min_answer_seconds: min_s}, ms) when is_integer(min_s) and min_s > 0 do
    ms < min_s * 1000
  end

  defp advance_or_review(socket) do
    next = socket.assigns.current_index + 1

    if next >= socket.assigns.total_questions do
      socket
      |> assign(:phase, :review)
      |> assign(:current_index, next)
    else
      socket
      |> assign(:current_index, next)
      |> assign(:phase, :prep)
      |> assign(:capture_complete_acked, false)
      |> assign(:too_short, false)
      |> assign(:last_recording_duration_ms, nil)
      |> assign(:response_id, nil)
      |> assign(:capture_instance_id, nil)
      |> assign(:bytes_buffered_locally, 0)
      |> assign(:bytes_uploaded, 0)
      |> push_set_question()
    end
  end

  defp push_set_question(socket, attempt_override \\ nil) do
    case current_question(socket) do
      nil ->
        socket

      q ->
        used = Capture.max_attempt_number(socket.assigns.session_id, q.id)
        attempt = attempt_override || used + 1

        push_event(socket, "set_question", %{
          questionIndex: q.position,
          attemptNumber: attempt,
          maxAnswerSeconds: q.max_answer_seconds,
          minAnswerSeconds: q.min_answer_seconds
        })
    end
  end

  defp ensure_int(v) when is_integer(v), do: v

  defp ensure_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> 1
    end
  end

  defp ensure_int(_), do: 1

  defp ensure_int_or_nil(nil), do: nil
  defp ensure_int_or_nil(v) when is_integer(v), do: v

  defp ensure_int_or_nil(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp ensure_int_or_nil(_), do: nil

  # ---- Render ---------------------------------------------------------

  @impl true
  def render(%{not_found: true} = assigns) do
    ~H"""
    <div class="mx-auto max-w-3xl space-y-4">
      <h1 class="text-xl font-semibold">Session not found</h1>
      <p class="text-sm opacity-70">
        Session <code>{@session_id}</code> doesn't exist or has expired.
      </p>
    </div>
    """
  end

  def render(%{rejected: true} = assigns) do
    assigns = assign_new(assigns, :rejected_reason, fn -> :invalid end)

    ~H"""
    <div class="mx-auto max-w-3xl space-y-4">
      <h1 class="text-xl font-semibold">Session unavailable</h1>
      <p class="text-sm opacity-70">{rejected_message(@rejected_reason)}</p>
      <p class="text-xs opacity-50">
        Session <code>{@session_id}</code>.
      </p>
    </div>
    """
  end

  def render(%{phase: :awaiting_auth} = assigns) do
    ~H"""
    <div
      id="capture-await"
      phx-hook="Recorder"
      phx-update="ignore"
      data-session-id={@session_id}
      data-awaiting-auth="true"
      class="mx-auto max-w-3xl space-y-4"
    >
      <h1 class="text-xl font-semibold">Loading…</h1>
      <p class="text-sm opacity-70">Waiting for the host to authorise this session.</p>
    </div>
    """
  end

  def render(assigns) do
    assigns =
      assigns
      |> assign(:current_question, current_question(assigns))
      |> assign_new(:review_items, fn -> review_items(assigns) end)

    ~H"""
    <div class="mx-auto max-w-4xl px-6 sm:px-10 py-12 sm:py-16 space-y-14">
      <%!--
        Shared aria-live announcement target for time-sensitive
        countdowns (think-time, idle-to-record, recording-time). Hidden
        visually; updated by JS hooks only at milestones (every 10s or
        the final 5s) so screen-reader users get useful cues without
        per-second noise.
      --%>
      <span
        id="countdown-announce"
        data-role="countdown-announce"
        class="sr-only"
        aria-live="polite"
        aria-atomic="true"
      >
      </span>

      <header>
        <div class="flex flex-wrap items-baseline justify-between gap-3">
          <p class="zen-eyebrow">
            <%= cond do %>
              <% @phase == :intro -> %>
                § — Welcome
              <% @phase == :permission_denied -> %>
                § — Camera access
              <% @phase == :review -> %>
                § — Review
              <% @phase == :submitted -> %>
                § — Submitted
              <% @phase == :fenced -> %>
                § — Paused
              <% @total_questions > 0 -> %>
                § — Question {min(@current_index + 1, @total_questions)} of {@total_questions}
              <% true -> %>
                § — Interview
            <% end %>
          </p>
          <p
            class="zen-eyebrow normal-case tracking-[0.06em] text-[10.5px] opacity-55 font-mono"
            title={"Session #{@session_id}"}
          >
            {short_session(@session_id)}
          </p>
        </div>
      </header>

      <%= cond do %>
        <% @phase == :intro -> %>
          {render_intro(assigns)}
        <% @phase == :permission_denied -> %>
          {render_permission_denied(assigns)}
        <% @phase == :review -> %>
          {render_review(assigns)}
        <% @phase == :submitted -> %>
          {render_submitted(assigns)}
        <% @phase == :fenced -> %>
          {render_fenced(assigns)}
        <% @current_question -> %>
          <div class="max-w-xl mx-auto space-y-10">
            <div class="space-y-6 min-w-0">
              {render_question(assigns)}
            </div>

            <div
              class="space-y-7 min-w-0"
              data-camera-state={if @permission_state == "granted", do: "on", else: "off"}
              data-phase={@phase}
            >
              {render_recorder(assigns)}
              {render_actions(assigns)}
            </div>
          </div>
        <% true -> %>
          <p class="text-sm text-base-content/60">No questions in this template.</p>
      <% end %>

      <%= if @phase not in [:intro, :permission_denied, :review, :submitted, :fenced] do %>
        <details class="opacity-50 hover:opacity-100 transition-opacity">
          <summary class="zen-eyebrow text-[10px] cursor-pointer select-none list-none">
            § — Debug
          </summary>
          <div class="mt-5 pt-5 border-t border-base-content/10">
            {render_telemetry(assigns)}
          </div>
        </details>
      <% end %>
    </div>
    """
  end

  defp render_attachment(assigns) do
    kind = Map.get(assigns.prompt_asset_kinds || %{}, assigns.attachment_id, "image")
    assigns = assign(assigns, :kind, kind)

    ~H"""
    <%= case @kind do %>
      <% "image" -> %>
        <img
          src={~p"/capture/#{@session_id}/prompt_assets/#{@attachment_id}"}
          alt="attachment"
          class="max-w-2xl rounded"
        />
      <% "pdf" -> %>
        <iframe
          src={~p"/capture/#{@session_id}/prompt_assets/#{@attachment_id}"}
          class="w-full max-w-2xl h-[420px] rounded border border-base-300"
          title="attachment"
        >
        </iframe>
      <% _ -> %>
        <a
          href={~p"/capture/#{@session_id}/prompt_assets/#{@attachment_id}"}
          class="link text-sm"
        >
          Download attachment
        </a>
    <% end %>
    """
  end

  defp render_question(assigns) do
    ~H"""
    <section class="space-y-6">
      <%= if @current_question.prompt_asset_id do %>
        <div
          class="space-y-3"
          data-prompt-state={prompt_shutter_state(@permission_state, @prompt_expanded)}
        >
          <%= if @permission_state == "granted" do %>
            <button
              type="button"
              phx-click="toggle_prompt"
              class="cursor-pointer select-none zen-link text-base-content/60 hover:text-base-content text-[13.5px] inline-flex items-baseline gap-2"
            >
              <span
                class={[
                  "transition-transform duration-300",
                  if(@prompt_expanded, do: "rotate-90", else: "")
                ]}
                aria-hidden="true"
              >
                ▸
              </span>
              <span>{if @prompt_expanded, do: "Hide the prompt", else: "Re-watch the prompt"}</span>
            </button>
          <% end %>
          <div class="prompt-shutter">
            <div>
              <video
                controls
                preload="auto"
                class="w-full max-w-xl rounded-sm bg-black/95"
                src={~p"/capture/#{@session_id}/prompt_assets/#{@current_question.prompt_asset_id}"}
              >
              </video>
            </div>
          </div>
        </div>
      <% end %>

      <p class="font-display italic text-[clamp(1rem,1.6vw,1.125rem)] leading-[1.7] text-base-content/90 max-w-[48ch]">
        <span
          aria-hidden="true"
          class="float-left mr-3 mt-[-0.05em] text-[3.25rem] leading-[0.95] text-primary/75 select-none"
        >
          Q
        </span>
        {@current_question.prompt_text}
      </p>

      <%= if @current_question.attachment_asset_id do %>
        <div
          class="space-y-3"
          data-section-state={attachment_shutter_state(@permission_state, @attachment_expanded)}
        >
          <%= if @permission_state == "granted" do %>
            <button
              type="button"
              phx-click="toggle_attachment"
              class="cursor-pointer select-none zen-link text-base-content/60 hover:text-base-content text-[13.5px] inline-flex items-baseline gap-2"
            >
              <span
                class={[
                  "transition-transform duration-300",
                  if(@attachment_expanded, do: "rotate-90", else: "")
                ]}
                aria-hidden="true"
              >
                ▸
              </span>
              <span>
                {if @attachment_expanded, do: "Hide the attachment", else: "Re-view the attachment"}
              </span>
            </button>
          <% end %>
          <div class="section-shutter">
            <div>
              {render_attachment(
                assign(assigns, :attachment_id, @current_question.attachment_asset_id)
              )}
            </div>
          </div>
        </div>
      <% end %>

      <p class="text-[13px] text-base-content/55 flex flex-wrap items-baseline gap-x-2 gap-y-1">
        <%= if @current_question.think_time_seconds do %>
          <span>Think-time {@current_question.think_time_seconds}s</span>
          <span class="opacity-40">·</span>
        <% end %>
        <%= if @current_question.max_answer_seconds do %>
          <span>Max answer {@current_question.max_answer_seconds}s</span>
          <span class="opacity-40">·</span>
        <% end %>
        <%= if @current_question.min_answer_seconds do %>
          <span>Min answer {@current_question.min_answer_seconds}s</span>
          <span class="opacity-40">·</span>
        <% end %>
        <span>{if @current_question.required, do: "Required", else: "Optional"}</span>
      </p>

      <%= if @phase == :prep and @current_question.think_time_seconds && @current_question.think_time_seconds > 0 do %>
        <p class="font-display italic text-[14.5px] leading-[1.6] text-base-content/70 max-w-[44ch] think-time-phrase">
          <span
            id={"think-time-#{@current_index}-#{@current_question.id}"}
            phx-hook="ThinkTimeCountdown"
            phx-update="ignore"
            data-think-seconds={@current_question.think_time_seconds}
          >
            Recording begins in {@current_question.think_time_seconds} seconds.
          </span>
        </p>
      <% end %>
    </section>
    """
  end

  defp render_actions(assigns) do
    ~H"""
    <div class="flex flex-wrap items-baseline gap-x-8 gap-y-3 pt-1">
      <%= cond do %>
        <% @phase == :prep -> %>
          <%= unless @current_question.required do %>
            <button
              phx-click="skip"
              class="zen-link text-base-content/55 hover:text-base-content text-[14px]"
            >
              <span class="zen-arrow" aria-hidden="true">→</span>
              <span>Skip this question</span>
            </button>
          <% end %>
        <% @phase == :recording -> %>
          <span class="text-[14px] flex items-center gap-2.5">
            <span class="inline-block w-1.5 h-1.5 rounded-full bg-error animate-pulse"></span>
            <span>Recording</span>
          </span>
        <% @phase == :draining -> %>
          <span class="text-[14px] text-base-content/70">Saving your answer…</span>
        <% @phase == :answered -> %>
          <%= if @too_short do %>
            <span class="text-[14px] text-warning">
              A little shorter than the {@current_question.min_answer_seconds}s suggested.
            </span>
          <% end %>
          <button
            phx-click="advance"
            class="zen-link text-base-content text-[14.5px]"
          >
            <span class="zen-arrow" aria-hidden="true">→</span>
            <span>{advance_label(@current_index, @total_questions)}</span>
          </button>
          <%= if can_retake?(@current_question, @session_id, @template_version) do %>
            <button
              phx-click="retake"
              class="zen-link text-base-content/55 hover:text-base-content text-[14px]"
            >
              <span class="zen-arrow" aria-hidden="true">↺</span>
              <span>Re-record</span>
            </button>
          <% end %>
        <% true -> %>
          <span class="text-[14px] text-base-content/50">…</span>
      <% end %>
    </div>
    """
  end

  defp render_review(assigns) do
    ~H"""
    <section class="space-y-7">
      <div class="space-y-4">
        <p class="zen-eyebrow opacity-50">Review</p>
        <h2 class="font-display text-[clamp(1.6rem,4vw,2.4rem)] leading-[1.18] tracking-[-0.018em] font-light">
          A last <em class="italic font-light text-primary">look</em>.
        </h2>
      </div>

      <ul class="divide-y divide-base-content/10">
        <%= for {q, status} <- @review_items do %>
          <li class="grid grid-cols-[3rem_1fr_max-content] gap-5 py-4 items-baseline">
            <span class="font-display italic text-[1.25rem] text-base-content/40 tabular-nums leading-none">
              {q.position |> Integer.to_string() |> String.pad_leading(2, "0")}
            </span>
            <div class="space-y-1 min-w-0">
              <p class="text-[14.5px] leading-[1.45] truncate">
                {q.prompt_text}
                <span :if={!q.required} class="text-base-content/45 italic">(optional)</span>
              </p>
            </div>
            <span class="zen-eyebrow normal-case tracking-[0.06em] text-[10.5px] opacity-65 whitespace-nowrap">
              {status}
            </span>
          </li>
        <% end %>
      </ul>

      <%= if @submit_error do %>
        <p class="text-[13.5px] text-error">{@submit_error}</p>
      <% end %>

      <div class="pt-2">
        <button phx-click="submit" class="zen-link text-base-content text-[15px]">
          <span class="zen-arrow" aria-hidden="true">→</span>
          <span>Submit interview</span>
        </button>
      </div>
    </section>
    """
  end

  defp review_items(%{questions: questions, session_id: session_id}) do
    Enum.map(questions, fn q -> {q, review_status(session_id, q)} end)
  end

  defp review_items(_), do: []

  defp render_submitted(assigns) do
    ~H"""
    <section class="space-y-5 py-4">
      <p class="zen-eyebrow opacity-55">§ — Submitted</p>
      <h2 class="font-display text-[clamp(1.8rem,4.5vw,2.6rem)] leading-[1.15] tracking-[-0.018em] font-light">
        Thank <em class="italic font-light text-primary">you</em>.
      </h2>
      <p class="text-[15px] leading-[1.65] text-base-content/75 max-w-[40ch]">
        Your interview is being processed
        (<span class="font-mono text-[13px] text-base-content/60">{@session_state}</span>).
        You can close this window.
      </p>
    </section>
    """
  end

  defp render_fenced(assigns) do
    ~H"""
    <section class="space-y-5 py-4">
      <p class="zen-eyebrow opacity-55 text-warning">§ — Paused</p>
      <h2 class="font-display text-[clamp(1.8rem,4.5vw,2.6rem)] leading-[1.15] tracking-[-0.018em] font-light">
        Picked up <em class="italic font-light text-primary">elsewhere</em>.
      </h2>
      <p class="text-[15px] leading-[1.65] text-base-content/75 max-w-[44ch]">
        Another tab or window took over this interview.
        Continue there, or reload to resume here.
      </p>
    </section>
    """
  end

  defp render_intro(assigns) do
    ~H"""
    <div class="max-w-xl mx-auto space-y-10">
      <section class="space-y-5">
        <h2 class="font-display text-[clamp(1.8rem,4.5vw,2.6rem)] leading-[1.15] tracking-[-0.018em] font-light">
          A few <em class="italic font-light text-primary">moments</em> before we begin.
        </h2>
        <p class="text-[15px] leading-[1.65] text-base-content/80 max-w-[44ch]">
          You'll be asked a small number of questions, one at a time. After each
          prompt you'll have a brief think-time, then you record your answer
          straight into the browser.
        </p>
      </section>

      <ul class="space-y-2 text-[14.5px] leading-[1.55] text-base-content/75 max-w-[44ch]">
        <li class="flex gap-3">
          <span class="zen-eyebrow text-[10px] mt-1 opacity-55">01</span>
          <span>Make sure you're somewhere quiet with a steady connection.</span>
        </li>
        <li class="flex gap-3">
          <span class="zen-eyebrow text-[10px] mt-1 opacity-55">02</span>
          <span>Allow camera and microphone access when prompted.</span>
        </li>
        <li class="flex gap-3">
          <span class="zen-eyebrow text-[10px] mt-1 opacity-55">03</span>
          <span>Once you start recording, give the answer in one take.</span>
        </li>
      </ul>

      <p class="text-[12.5px] italic leading-[1.6] text-base-content/55 max-w-[44ch] border-l-2 border-base-content/15 pl-4">
        Your spoken answer will be transcribed and scored by AI against a
        structured rubric. A human recruiter reviews the score and the
        recording before any hiring decision.
      </p>

      <%!--
        Recorder hook mounts here during :intro so the candidate can
        grant camera + mic permission BEFORE the "I'm ready" CTA
        appears. We reuse render_recorder unchanged — the same hook
        instance stays alive across the :intro → :prep transition
        (same #recorder id), so the granted MediaStream survives.
      --%>
      <div
        class="space-y-7 min-w-0"
        data-camera-state={if @permission_state == "granted", do: "on", else: "off"}
        data-phase={@phase}
      >
        {render_recorder(assigns)}
      </div>

      {render_intro_cta(assigns)}
    </div>
    """
  end

  defp render_intro_cta(assigns) do
    ~H"""
    <div class="pt-2">
      <%= cond do %>
        <% @permission_state == "granted" -> %>
          <button
            type="button"
            phx-click="intro_ready"
            class="zen-link text-base-content text-[15px]"
          >
            <span class="zen-arrow" aria-hidden="true">→</span>
            <span>I'm ready</span>
          </button>
        <% @permission_state == "requesting" -> %>
          <p class="text-[13.5px] italic leading-[1.55] text-base-content/65">
            Waiting for your browser to confirm camera and microphone access…
          </p>
        <% true -> %>
          <p class="text-[13.5px] leading-[1.55] text-base-content/65 max-w-[44ch]">
            Allow camera and microphone above. The <em class="italic">"I'm ready"</em>
            button will appear here once
            access is granted.
          </p>
      <% end %>
    </div>
    """
  end

  defp render_permission_denied(assigns) do
    ~H"""
    <section class="max-w-xl mx-auto space-y-8 py-4">
      <div class="space-y-5">
        <p class="zen-eyebrow opacity-55 text-warning">§ — Camera access</p>
        <h2 class="font-display text-[clamp(1.8rem,4.5vw,2.6rem)] leading-[1.15] tracking-[-0.018em] font-light">
          We need <em class="italic font-light text-primary">access</em>
          to your camera and microphone.
        </h2>
        <p class="text-[15px] leading-[1.65] text-base-content/80 max-w-[46ch]">
          Your browser blocked the request. The interview is recorded by
          your own device — without camera and microphone permission, we
          can't capture an answer. Re-enable access in your browser, then
          try again.
        </p>
      </div>

      <details class="text-[13.5px] leading-[1.6] text-base-content/70 max-w-[46ch]">
        <summary class="cursor-pointer select-none zen-link text-base-content/75 hover:text-base-content inline-flex items-baseline gap-2">
          <span class="text-[11px]" aria-hidden="true">▸</span>
          <span>How to re-enable access</span>
        </summary>
        <div class="mt-4 space-y-3 pl-4 border-l border-base-content/10">
          <p>
            <span class="zen-eyebrow text-[10px] opacity-55">Chrome / Edge —</span>
            click the camera icon at the left edge of the address bar,
            choose <em class="italic">Allow</em>, then reload.
          </p>
          <p>
            <span class="zen-eyebrow text-[10px] opacity-55">Safari —</span>
            open <em class="italic">Safari → Settings for This Website…</em>
            and set Camera + Microphone to <em class="italic">Allow</em>.
          </p>
          <p>
            <span class="zen-eyebrow text-[10px] opacity-55">Firefox —</span>
            click the camera icon at the left edge of the address bar and
            remove the blocked permission, then try again.
          </p>
        </div>
      </details>

      <div class="pt-2">
        <button
          type="button"
          phx-click="permission_denied_retry"
          class="zen-link text-base-content text-[15px]"
        >
          <span class="zen-arrow" aria-hidden="true">↺</span>
          <span>I've enabled access — try again</span>
        </button>
      </div>
    </section>
    """
  end

  defp render_recorder(assigns) do
    ~H"""
    <section
      id="recorder"
      phx-hook="Recorder"
      phx-update="ignore"
      data-session-id={@session_id}
      class="space-y-5 min-w-0"
    >
      <div class="preview-shutter">
        <div class="relative">
          <video
            data-role="preview"
            autoplay
            playsinline
            muted
            class="w-full aspect-video rounded-sm bg-black/95"
          >
          </video>
          <span
            data-role="recording-countdown"
            class="absolute bottom-3 right-3 font-display italic text-base text-white/85 tracking-tight recording-countdown"
            aria-hidden="true"
          >
          </span>
          <span
            data-role="cinematic-countdown"
            class="absolute inset-0 flex items-center justify-center font-display italic text-white/55 cinematic-countdown pointer-events-none"
            aria-hidden="true"
          >
          </span>
        </div>
      </div>

      <div class="flex flex-wrap items-baseline gap-x-5 gap-y-3 text-[13px] whitespace-nowrap">
        <button data-action="request" class="zen-link text-base-content">
          <span class="zen-arrow" aria-hidden="true">→</span>
          <span>Open camera</span>
        </button>
        <button data-action="start" class="zen-link text-base-content">
          <span class="zen-arrow" aria-hidden="true">●</span>
          <span>Record</span>
        </button>
        <button data-action="stop" class="zen-link text-base-content/60 hover:text-base-content">
          <span class="zen-arrow" aria-hidden="true">■</span>
          <span>Stop</span>
        </button>
        <span
          data-role="mic-level"
          class="mic-level ml-auto"
          aria-hidden="true"
          title="Microphone input level"
        >
          <span class="mic-level-bar"></span>
          <span class="mic-level-label">Mic</span>
        </span>
      </div>
    </section>
    """
  end

  defp render_telemetry(assigns) do
    ~H"""
    <aside class="space-y-4 min-w-0 pt-8 border-t border-base-content/10 lg:pt-0 lg:border-t-0 lg:pl-8 lg:border-l lg:border-base-content/10">
      <p class="zen-eyebrow opacity-50 text-[10px] tracking-[0.24em]">Status</p>

      <dl class="grid grid-cols-2 gap-x-5 gap-y-3 text-[11px]">
        <div class="col-span-2 space-y-0">
          <dt class="font-mono uppercase tracking-[0.18em] text-[8.5px] text-base-content/45">
            Session
          </dt>
          <dd class="font-mono text-[10.5px] text-base-content/80 break-all leading-snug">
            {@session_id}
          </dd>
        </div>

        <div class="space-y-0">
          <dt class="font-mono uppercase tracking-[0.18em] text-[8.5px] text-base-content/45">
            Phase
          </dt>
          <dd class="font-mono text-base-content/85 break-all">{@phase}</dd>
        </div>

        <div class="space-y-0">
          <dt class="font-mono uppercase tracking-[0.18em] text-[8.5px] text-base-content/45">
            Session state
          </dt>
          <dd class="font-mono text-base-content/85 break-all">{@session_state}</dd>
        </div>

        <div class="space-y-0">
          <dt class="font-mono uppercase tracking-[0.18em] text-[8.5px] text-base-content/45">
            Permission
          </dt>
          <dd class="font-mono text-base-content/85 break-all">{@permission_state}</dd>
        </div>

        <div class="space-y-0">
          <dt class="font-mono uppercase tracking-[0.18em] text-[8.5px] text-base-content/45">
            Recorder
          </dt>
          <dd class="font-mono text-base-content/85 break-all">{@recorder_state}</dd>
        </div>

        <div class="col-span-2 space-y-0">
          <dt class="font-mono uppercase tracking-[0.18em] text-[8.5px] text-base-content/45">
            MIME
          </dt>
          <dd class="font-mono text-base-content/85 break-all">{@mime_type || "—"}</dd>
        </div>

        <div class="space-y-0">
          <dt class="font-mono uppercase tracking-[0.18em] text-[8.5px] text-base-content/45">
            Buffered
          </dt>
          <dd class="font-mono text-base-content/85 tabular-nums">
            {format_bytes(@bytes_buffered_locally)}
          </dd>
        </div>

        <div class="space-y-0">
          <dt class="font-mono uppercase tracking-[0.18em] text-[8.5px] text-base-content/45">
            Uploaded
          </dt>
          <dd class="font-mono text-base-content/85 tabular-nums">{format_bytes(@bytes_uploaded)}</dd>
        </div>

        <div class="space-y-0">
          <dt class="font-mono uppercase tracking-[0.18em] text-[8.5px] text-base-content/45">
            Complete
          </dt>
          <dd class="font-mono text-base-content/85">
            {if @capture_complete_acked, do: "yes", else: "no"}
          </dd>
        </div>

        <div class="space-y-0">
          <dt class="font-mono uppercase tracking-[0.18em] text-[8.5px] text-base-content/45">
            Bitrate step
          </dt>
          <dd class="font-mono text-base-content/85 tabular-nums">{@bitrate_step}</dd>
        </div>

        <div class="col-span-2 space-y-0">
          <dt class="font-mono uppercase tracking-[0.18em] text-[8.5px] text-base-content/45">
            Capture instance
          </dt>
          <dd class="font-mono text-[10.5px] text-base-content/80 break-all leading-snug">
            {@capture_instance_id || "—"}
          </dd>
        </div>

        <div class="col-span-2 space-y-0">
          <dt class="font-mono uppercase tracking-[0.18em] text-[8.5px] text-base-content/45">
            Response id
          </dt>
          <dd class="font-mono text-[10.5px] text-base-content/80 break-all leading-snug">
            {@response_id || "—"}
          </dd>
        </div>

        <%= if @last_recording_duration_ms do %>
          <div class="col-span-2 space-y-0">
            <dt class="font-mono uppercase tracking-[0.18em] text-[8.5px] text-base-content/45">
              Last duration
            </dt>
            <dd class="font-mono text-base-content/85 tabular-nums">
              {@last_recording_duration_ms} ms
            </dd>
          </div>
        <% end %>

        <%= if @last_error do %>
          <div class="col-span-2 space-y-0">
            <dt class="font-mono uppercase tracking-[0.18em] text-[8.5px] text-error">Last error</dt>
            <dd class="font-mono text-error break-words leading-snug">{@last_error}</dd>
          </div>
        <% end %>
      </dl>
    </aside>
    """
  end

  defp short_session(<<head::binary-size(8), _rest::binary>>), do: "Session " <> head <> "…"
  defp short_session(id) when is_binary(id), do: "Session " <> id
  defp short_session(_), do: "Session"

  defp advance_label(idx, total) when idx + 1 >= total, do: "Continue to review"
  defp advance_label(_idx, _total), do: "Next question"

  # Drives `.prompt-shutter` open/closed transitions. Stay open while the
  # candidate is still in the hero/prep mode (camera not requested yet) —
  # collapsing the prompt before they've watched it would hide the only
  # question content. Collapse the moment the candidate commits ("Open
  # camera" click → `permission_requesting`) so the page reacts instantly
  # rather than after the browser permission dialog clears. Once granted,
  # let `prompt_expanded` (the toggle) drive open/closed.
  defp prompt_shutter_state("granted", false), do: "closed"
  defp prompt_shutter_state("granted", true), do: "open"
  defp prompt_shutter_state("requesting", _), do: "closed"
  defp prompt_shutter_state(_, _), do: "open"

  # Same logic as `prompt_shutter_state`, applied independently to the
  # attachment shutter so the candidate can re-open prompt and attachment
  # separately.
  defp attachment_shutter_state("granted", false), do: "closed"
  defp attachment_shutter_state("granted", true), do: "open"
  defp attachment_shutter_state("requesting", _), do: "closed"
  defp attachment_shutter_state(_, _), do: "open"

  defp can_retake?(q, session_id, version) do
    cap = Capture.max_attempts_for(q, version)
    used = Capture.max_attempt_number(session_id, q.id)
    used < cap
  end

  defp review_status(session_id, q) do
    sq = Capture.get_session_question(session_id, q.id)

    cond do
      sq && sq.selected_response_id ->
        "ready"

      sq && Capture.list_responses_for(session_id, q.id) != [] ->
        responses = Capture.list_responses_for(session_id, q.id)
        latest = List.last(responses)
        latest.state

      q.required ->
        "not answered"

      true ->
        "skipped"
    end
  end

  defp format_bytes(0), do: "0 B"
  defp format_bytes(b) when b < 1024, do: "#{b} B"
  defp format_bytes(b) when b < 1024 * 1024, do: "#{Float.round(b / 1024, 1)} KB"
  defp format_bytes(b), do: "#{Float.round(b / 1024 / 1024, 2)} MB"

  defp rejected_message(:expired),
    do: "This sign-in link has expired. Request a new link to continue."

  defp rejected_message(:consumed),
    do: "This sign-in link has already been used. Request a new link to continue."

  defp rejected_message(:sid_mismatch), do: "Sign-in link does not match this session."

  defp rejected_message(_),
    do: "This sign-in link is invalid or expired. Request a new link to continue."
end
