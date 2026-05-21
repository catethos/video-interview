defmodule InterviewWeb.RecruiterSessionLive do
  @moduledoc """
  Per-session playback page (PLAN — playback-plan.md §"RecruiterSessionLive").

  Layout: header (candidate, template, state) + one card per template
  question. Each card shows the selected response's `<video>` whose `src`
  points at `/recruiter/playback/<response_id>`. Same-origin cookie auth
  makes the playback request work without any extra wiring.
  """
  use InterviewWeb, :live_view

  alias Interview.Capture
  alias Interview.Playback

  @impl true
  def mount(%{"id" => session_id}, _session, socket) do
    tenant_id = socket.assigns.tenant.id

    case Playback.get_session(tenant_id, session_id) do
      nil ->
        {:ok,
         socket
         |> assign(:not_found, true)
         |> assign(:session_id, session_id)}

      detail ->
        recruiter = socket.assigns.current_recruiter
        tenant = socket.assigns.tenant

        {:ok,
         socket
         |> assign(:not_found, false)
         |> assign(:detail, detail)
         |> assign(:show_debug, dev_recruiter?(recruiter, tenant))
         |> assign(:expanded_transcripts, MapSet.new())}
    end
  end

  @impl true
  def handle_event("toggle_transcript", %{"qid" => qid}, socket) do
    expanded =
      if MapSet.member?(socket.assigns.expanded_transcripts, qid) do
        MapSet.delete(socket.assigns.expanded_transcripts, qid)
      else
        MapSet.put(socket.assigns.expanded_transcripts, qid)
      end

    {:noreply, assign(socket, :expanded_transcripts, expanded)}
  end

  def handle_event("delete_session", _params, socket) do
    session = socket.assigns.detail.session
    recruiter = socket.assigns.current_recruiter

    audit = %{actor_kind: "recruiter", actor_id: recruiter.id}

    case Capture.soft_delete_session(session.id, audit) do
      {:ok, _status} ->
        {:noreply,
         socket
         |> put_flash(:info, "Session deleted. Storage scrub enqueued.")
         |> push_navigate(to: ~p"/recruiter/sessions")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  # ---- Render ----------------------------------------------------------

  @impl true
  def render(%{not_found: true} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <h1 class="text-2xl">Session not found</h1>
      <p class="text-sm opacity-70">
        No session with id <code>{@session_id}</code> exists for this tenant.
      </p>
      <p class="mt-4">
        <.link navigate={~p"/recruiter/sessions"} class="link link-primary">
          ← Back to sessions
        </.link>
      </p>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-6" id={"recruiter-session-#{@detail.session.id}"}>
        <p>
          <.link navigate={~p"/recruiter/sessions"} class="link text-sm">
            ← All sessions
          </.link>
        </p>

        <header class="space-y-1">
          <div class="flex items-baseline justify-between">
            <h1 class="text-2xl font-semibold">
              {@detail.template.name}
              <span class="font-normal opacity-50">v{@detail.version.version_number}</span>
            </h1>
            <button
              type="button"
              phx-click="delete_session"
              data-confirm="Delete this session? Recordings will be scrubbed from storage and a session.deleted webhook will fire. This cannot be undone."
              class="btn btn-sm btn-error"
              id="delete-session"
            >
              Delete
            </button>
          </div>
          <p class="text-sm opacity-70">
            <span class={["badge", state_badge_class(@detail.session.state)]}>
              {@detail.session.state}
            </span>
            · completed {format_time(@detail.session.completed_at)}
            <%= if @detail.session.candidate_email do %>
              · {@detail.session.candidate_email}
            <% end %>
          </p>
          <p :if={@detail.webhook_summary != %{}} class="text-xs opacity-60">
            Webhooks:
            <span :for={{event, states} <- @detail.webhook_summary} class="mr-2">
              {event}
              <span :for={{state, n} <- states} class="opacity-80">
                {n} {state}
              </span>
            </span>
          </p>
        </header>

        <ol class="space-y-6" id="question-cards">
          <li
            :for={card <- @detail.questions}
            class="border border-base-300 rounded p-4 space-y-3"
            id={"question-#{card.template_question.id}"}
            data-question-id={card.template_question.id}
          >
            <div class="flex items-baseline justify-between">
              <h2 class="font-semibold">
                Question {card.template_question.position}
              </h2>
              <span class="text-xs opacity-70">
                {attempt_summary(card.attempts)}
              </span>
            </div>

            <div class="prose prose-sm max-w-none whitespace-pre-line">
              {card.template_question.prompt_text}
            </div>

            <div :if={card.selected_response} class="space-y-2">
              <video
                controls
                preload="metadata"
                src={~p"/recruiter/playback/#{card.selected_response.id}"}
                class="w-full max-w-2xl rounded bg-black"
                data-response-id={card.selected_response.id}
              >
              </video>
              <p class="text-xs opacity-70">
                Duration {format_duration(card.selected_response.duration_ms)} · attempt {card.selected_response.attempt_number} of {length(
                  card.attempts
                )} · state {card.selected_response.state}
              </p>

              <div
                :if={card.selected_response.transcript_text}
                class="text-sm"
                id={"transcript-#{card.template_question.id}"}
              >
                <button
                  type="button"
                  phx-click="toggle_transcript"
                  phx-value-qid={card.template_question.id}
                  class="link text-xs opacity-70"
                >
                  {if MapSet.member?(
                        @expanded_transcripts,
                        card.template_question.id
                      ),
                      do: "Hide transcript",
                      else: "Show transcript"}
                </button>
                <p
                  :if={MapSet.member?(@expanded_transcripts, card.template_question.id)}
                  class="mt-1 whitespace-pre-line opacity-90 border-l-2 border-base-300 pl-3"
                >
                  {card.selected_response.transcript_text}
                </p>
              </div>
            </div>

            <p
              :if={is_nil(card.selected_response)}
              class="text-sm opacity-70 italic"
            >
              No playable response yet.
              <span :if={card.attempts != []}>
                ({length(card.attempts)} attempt(s) recorded but none ready)
              </span>
            </p>
          </li>
        </ol>

        <details :if={@show_debug} class="text-xs opacity-70" id="debug-panel">
          <summary>Debug · all attempts</summary>
          <ul class="mt-2 space-y-2">
            <li :for={card <- @detail.questions}>
              <strong>Q{card.template_question.position}</strong>
              <ul class="ml-4">
                <li
                  :for={r <- card.attempts}
                  class={
                    card.selected_response && r.id == card.selected_response.id &&
                      "font-semibold"
                  }
                >
                  attempt={r.attempt_number} state={r.state} duration={format_duration(r.duration_ms)} storage_key={r.storage_key ||
                    "—"}
                </li>
              </ul>
            </li>
          </ul>
        </details>
      </div>
    </Layouts.app>
    """
  end

  defp dev_recruiter?(recruiter, tenant) do
    cond do
      is_nil(recruiter) or is_nil(recruiter.email) ->
        false

      is_binary(tenant.slug) and String.starts_with?(tenant.slug, "dev") ->
        true

      String.contains?(recruiter.email, "@dev.") ->
        true

      true ->
        false
    end
  end

  defp attempt_summary([]), do: "no attempts"
  defp attempt_summary([_]), do: "1 attempt"

  defp attempt_summary(attempts) when is_list(attempts) do
    "#{length(attempts)} attempts"
  end

  defp state_badge_class("ready"), do: "badge-success"
  defp state_badge_class("submitted"), do: "badge-info"
  defp state_badge_class("failed"), do: "badge-error"
  defp state_badge_class("expired"), do: "badge-warning"
  defp state_badge_class(_), do: "badge-ghost"

  defp format_time(nil), do: "—"

  defp format_time(%DateTime{} = dt) do
    dt |> DateTime.truncate(:second) |> DateTime.to_string()
  end

  defp format_duration(nil), do: "—"
  defp format_duration(0), do: "—"

  defp format_duration(ms) when is_integer(ms) and ms > 0 do
    seconds = div(ms, 1000)
    minutes = div(seconds, 60)
    s = rem(seconds, 60)
    "#{minutes}:#{String.pad_leading(Integer.to_string(s), 2, "0")}"
  end

  defp format_duration(_), do: "—"
end
