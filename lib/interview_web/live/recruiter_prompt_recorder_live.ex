defmodule InterviewWeb.RecruiterPromptRecorderLive do
  @moduledoc """
  Full-page recruiter recorder for a single template question's prompt
  (PLAN §3.4 recruiter prompts).

  Mount path: `/recruiter/templates/:tid/questions/:qid/prompt`. The
  page mounts under the `:recruiter` `live_session` so
  `current_scope.{recruiter, tenant}` is already in scope.

  Behaviour:

    1. Mount creates a fresh `prompt_asset` (`pending`) and claims it
       as the recording writer, minting a `capture_instance_id`.
    2. Pushes `init` to the `RecruiterRecorder` hook with the tus URL,
       capture-complete URL, capture_instance_id, and a short-lived
       recruiter upload bearer.
    3. On `capture_complete_acked` the finalizer is already running;
       the LV polls the asset row by id to render state.
    4. On "Set as prompt" the LV writes `prompt_asset_id` on the
       template question. The plan calls for an explicit swap step —
       see plan risk list #1.

  No think-time, no retake-policy, no session rollup — those are
  candidate-side concerns. A re-record on this page navigates back to
  this same route and creates a fresh asset id.
  """
  use InterviewWeb, :live_view

  alias Interview.Auth.Tokens
  alias Interview.PromptAssets
  alias Interview.Repo
  alias Interview.Templates
  alias Interview.Templates.{PromptAsset, Question}

  @impl true
  def mount(%{"tid" => template_id, "qid" => question_id}, _session, socket) do
    tenant = socket.assigns.tenant
    recruiter = socket.assigns.current_recruiter

    with %Templates.Template{tenant_id: tid} = template when tid == tenant.id <-
           Templates.get_template!(template_id),
         %Question{} = question <- Repo.get(Question, question_id),
         %Templates.Version{} = version <-
           Repo.get(Templates.Version, question.template_version_id),
         true <- version.template_id == template.id do
      socket =
        socket
        |> assign(:template, template)
        |> assign(:question, question)
        |> assign(:not_found, false)
        |> assign(:bytes_uploaded, 0)
        |> assign(:bytes_buffered, 0)

      socket =
        if connected?(socket) do
          {:ok, asset, capture_id} =
            PromptAssets.create_recording(tenant.id, %{
              kind: "video",
              created_by_user_id: recruiter.id
            })

          bearer = Tokens.mint_recruiter_upload_bearer(recruiter.id, tenant.id)

          socket
          |> assign(:asset, asset)
          |> assign(:capture_instance_id, capture_id)
          |> assign(:upload_bearer, bearer)
          |> assign(:state, asset.state)
          |> push_init()
        else
          socket
          |> assign(:asset, nil)
          |> assign(:capture_instance_id, nil)
          |> assign(:upload_bearer, nil)
          |> assign(:state, "pending")
        end

      {:ok, socket}
    else
      _ -> {:ok, assign(socket, :not_found, true)}
    end
  end

  defp push_init(socket) do
    asset = socket.assigns.asset
    cid = socket.assigns.capture_instance_id

    push_event(socket, "init", %{
      tenantId: socket.assigns.tenant.id,
      promptAssetId: asset.id,
      captureInstanceId: cid,
      tusUrl: "/uploads/prompt_assets/#{asset.id}/#{cid}",
      captureCompleteUrl: "/api/prompt_assets/#{asset.id}/capture_complete",
      uploadBearer: socket.assigns.upload_bearer
    })
  end

  # ---- Hook events -----------------------------------------------------

  @impl true
  def handle_event("recorder_ready", _payload, socket), do: {:noreply, socket}

  def handle_event("permission", _payload, socket), do: {:noreply, socket}

  def handle_event("recorder_started", _payload, socket) do
    {:noreply, assign(socket, :state, "recording")}
  end

  def handle_event("recorder_stopped", _payload, socket) do
    # The hook will drain its IDB queue and then POST capture_complete;
    # we wait for `capture_complete_acked` before refreshing state.
    {:noreply, socket}
  end

  def handle_event(
        "buffer_progress",
        %{"bytesBuffered" => bytes_b, "bytesUploaded" => bytes_u},
        socket
      ) do
    {:noreply,
     socket
     |> assign(:bytes_buffered, bytes_b)
     |> assign(:bytes_uploaded, bytes_u)}
  end

  def handle_event("buffer_progress", _payload, socket), do: {:noreply, socket}

  def handle_event("capture_complete_acked", _payload, socket) do
    {:noreply,
     socket
     |> assign(:state, refresh_state(socket))
     |> schedule_state_poll()}
  end

  def handle_event("fenced_notice", _payload, socket) do
    {:noreply,
     socket
     |> put_flash(:error, "Another writer took over this recording.")
     |> assign(:state, refresh_state(socket))}
  end

  def handle_event("recorder_error", %{"code" => code, "message" => msg}, socket) do
    {:noreply, put_flash(socket, :error, "Recorder error (#{code}): #{msg}")}
  end

  def handle_event("recorder_error", _payload, socket), do: {:noreply, socket}

  def handle_event("refresh_upload_token", _payload, socket) do
    recruiter = socket.assigns.current_recruiter
    bearer = Tokens.mint_recruiter_upload_bearer(recruiter.id, socket.assigns.tenant.id)
    {:reply, %{token: bearer}, assign(socket, :upload_bearer, bearer)}
  end

  def handle_event("set_as_prompt", _params, socket) do
    asset = refresh_asset(socket)
    question = socket.assigns.question

    cond do
      asset.state != "ready" ->
        {:noreply, put_flash(socket, :error, "Asset is not ready yet (#{asset.state}).")}

      true ->
        case Templates.update_draft_question(question, %{"prompt_asset_id" => asset.id}) do
          {:ok, _} ->
            Interview.Audit.log!(%{
              tenant_id: socket.assigns.tenant.id,
              actor_kind: "recruiter",
              actor_id: socket.assigns.current_recruiter.id,
              action: "prompt_asset.attach",
              subject_kind: "template_question",
              subject_id: question.id,
              metadata: %{
                "prompt_asset_id" => asset.id,
                "template_id" => socket.assigns.template.id
              }
            })

            {:noreply,
             socket
             |> put_flash(:info, "Prompt asset attached.")
             |> push_navigate(to: ~p"/recruiter/templates/#{socket.assigns.template.id}")}

          {:error, :published_immutable} ->
            {:noreply, put_flash(socket, :error, "This version is published — open a new draft.")}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Failed to attach prompt asset.")}
        end
    end
  end

  def handle_event("poll_state", _params, socket) do
    asset = refresh_asset(socket)

    socket =
      socket
      |> assign(:asset, asset)
      |> assign(:state, asset.state)

    if asset.state not in ["ready", "failed", "abandoned"] do
      {:noreply, schedule_state_poll(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:poll_state, socket) do
    asset = refresh_asset(socket)

    socket =
      socket
      |> assign(:asset, asset)
      |> assign(:state, asset.state)

    if asset.state not in ["ready", "failed", "abandoned"] do
      {:noreply, schedule_state_poll(socket)}
    else
      {:noreply, socket}
    end
  end

  defp refresh_asset(socket) do
    Repo.get!(PromptAsset, socket.assigns.asset.id)
  end

  defp refresh_state(socket), do: refresh_asset(socket).state

  defp schedule_state_poll(socket) do
    Process.send_after(self(), :poll_state, 1_500)
    socket
  end

  # ---- Render ---------------------------------------------------------

  @impl true
  def render(%{not_found: true} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <h1 class="text-2xl">Question not found</h1>
      <p class="text-sm opacity-70">No question matched that template + id.</p>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-5">
        <p class="text-xs">
          <.link
            navigate={~p"/recruiter/templates/#{@template.id}"}
            class="link"
          >
            ← Back to template
          </.link>
        </p>
        <header>
          <h1 class="text-2xl font-semibold">Record prompt</h1>
          <p class="text-sm opacity-70">
            Question {@question.position}: {@question.prompt_text}
          </p>
        </header>

        <section
          id="recruiter-recorder"
          phx-hook="RecruiterRecorder"
          phx-update="ignore"
          class="space-y-4"
          data-asset-id={@asset && @asset.id}
        >
          <video
            data-role="preview"
            autoplay
            playsinline
            muted
            class="w-full max-w-2xl aspect-video rounded bg-black/90"
          >
          </video>

          <div class="flex flex-wrap gap-3 text-sm">
            <button data-action="request" class="btn btn-sm">Open camera</button>
            <button data-action="start" class="btn btn-sm btn-primary">Start recording</button>
            <button data-action="stop" class="btn btn-sm">Stop</button>
            <button data-action="release" class="btn btn-sm">Release camera</button>
          </div>
        </section>

        <section class="text-xs space-y-1" id="recorder-status">
          <dl class="grid grid-cols-[max-content,1fr] gap-x-3 gap-y-1">
            <dt class="opacity-60">State</dt>
            <dd class="font-mono">{@state}</dd>
            <dt class="opacity-60">Uploaded</dt>
            <dd class="font-mono">{@bytes_uploaded} bytes</dd>
            <dt class="opacity-60">Buffered (IDB)</dt>
            <dd class="font-mono">{@bytes_buffered} bytes</dd>
            <dt class="opacity-60">Asset id</dt>
            <dd class="font-mono">{@asset && @asset.id}</dd>
          </dl>
        </section>

        <section class="space-y-3">
          <button
            class="btn btn-sm btn-primary"
            phx-click="set_as_prompt"
            disabled={@state != "ready"}
            id="set-as-prompt-btn"
          >
            Set as prompt for question {@question.position}
          </button>
          <p :if={@state != "ready"} class="text-xs opacity-70">
            Wait for the asset to reach <code>ready</code> before attaching.
          </p>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
