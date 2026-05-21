defmodule InterviewWeb.RecruiterSessionsLive do
  @moduledoc """
  Recruiter dashboard list of capture sessions for the current tenant
  (PLAN — playback-plan.md §"RecruiterSessionsLive").

  All rows are tenant-scoped through `Interview.Playback.list_sessions/2`;
  no client-side tenant id is trusted. Filters (state, template) are
  reflected in the URL via `handle_params` so back-button works.
  """
  use InterviewWeb, :live_view

  alias Interview.Playback

  @all_states Playback.session_states()

  @impl true
  def mount(_params, _session, socket) do
    tenant_id = socket.assigns.tenant.id

    {:ok,
     socket
     |> assign(:templates, Playback.list_templates_with_sessions(tenant_id))
     |> assign(:state_options, @all_states)
     |> assign(:selected_states, [])
     |> assign(:selected_template_id, nil)
     |> assign(:selected_ids, MapSet.new())
     |> assign(:visible_ids, [])
     |> assign(:sessions, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    selected_states = parse_states(params["states"])
    selected_template_id = parse_template(params["template_id"])

    rows =
      Playback.list_sessions(socket.assigns.tenant.id,
        states: nilify(selected_states),
        template_id: selected_template_id
      )

    visible_ids = Enum.map(rows, & &1.session.id)

    {:noreply,
     socket
     |> assign(:selected_states, selected_states)
     |> assign(:selected_template_id, selected_template_id)
     |> assign(:visible_ids, visible_ids)
     # Filter change can drop rows the user had selected — keep only the
     # ids that are still visible to avoid silently deleting rows the
     # user can't see.
     |> assign(
       :selected_ids,
       MapSet.intersection(socket.assigns.selected_ids, MapSet.new(visible_ids))
     )
     |> assign(:sessions, rows)
     |> assign(:empty?, rows == [])}
  end

  @impl true
  def handle_event("filter_state", %{"state" => state, "_target" => _}, socket) do
    selected = toggle(socket.assigns.selected_states, state)
    {:noreply, push_patch(socket, to: build_path(socket, states: selected))}
  end

  def handle_event("filter_state", %{"state" => state}, socket) do
    selected = toggle(socket.assigns.selected_states, state)
    {:noreply, push_patch(socket, to: build_path(socket, states: selected))}
  end

  def handle_event("filter_template", %{"template_id" => ""}, socket) do
    {:noreply, push_patch(socket, to: build_path(socket, template_id: nil))}
  end

  def handle_event("filter_template", %{"template_id" => template_id}, socket) do
    {:noreply, push_patch(socket, to: build_path(socket, template_id: template_id))}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/recruiter/sessions")}
  end

  def handle_event("toggle_select", %{"id" => id}, socket) do
    {:noreply,
     update(socket, :selected_ids, fn set ->
       if MapSet.member?(set, id), do: MapSet.delete(set, id), else: MapSet.put(set, id)
     end)}
  end

  def handle_event("toggle_select_all", _params, socket) do
    visible = MapSet.new(socket.assigns.visible_ids)

    all_selected? =
      MapSet.subset?(visible, socket.assigns.selected_ids) and MapSet.size(visible) > 0

    {:noreply, assign(socket, :selected_ids, if(all_selected?, do: MapSet.new(), else: visible))}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, :selected_ids, MapSet.new())}
  end

  def handle_event("delete_selected", _params, socket) do
    ids = MapSet.to_list(socket.assigns.selected_ids)
    recruiter = socket.assigns.current_recruiter

    Enum.each(ids, fn id ->
      Interview.Capture.soft_delete_session(id, %{
        actor_kind: "recruiter",
        actor_id: recruiter.id
      })
    end)

    id_set = MapSet.new(ids)
    sessions = Enum.reject(socket.assigns.sessions, &MapSet.member?(id_set, &1.session.id))
    visible = socket.assigns.visible_ids -- ids

    {:noreply,
     socket
     |> assign(:sessions, sessions)
     |> assign(:selected_ids, MapSet.new())
     |> assign(:visible_ids, visible)
     |> assign(:empty?, visible == [])}
  end

  def handle_event("delete_session", %{"id" => id}, socket) do
    recruiter = socket.assigns.current_recruiter

    case Interview.Capture.soft_delete_session(id, %{
           actor_kind: "recruiter",
           actor_id: recruiter.id
         }) do
      {:ok, _} ->
        # Drop the row in place. The async SessionDeletion worker scrubs
        # storage + emits the webhook; the DB row is already flipped
        # (deleted_at) so the next page load won't re-list it either.
        sessions = Enum.reject(socket.assigns.sessions, &(&1.session.id == id))
        visible = socket.assigns.visible_ids -- [id]

        {:noreply,
         socket
         |> assign(:sessions, sessions)
         |> assign(:visible_ids, visible)
         |> assign(:selected_ids, MapSet.delete(socket.assigns.selected_ids, id))
         |> assign(:empty?, visible == [])}

      {:error, :not_found} ->
        {:noreply, socket}
    end
  end

  defp toggle(list, value) do
    if value in list do
      List.delete(list, value)
    else
      Enum.sort([value | list])
    end
  end

  defp build_path(socket, overrides) do
    states =
      Keyword.get_lazy(overrides, :states, fn -> socket.assigns.selected_states end)

    template_id =
      Keyword.get_lazy(overrides, :template_id, fn ->
        socket.assigns.selected_template_id
      end)

    query =
      []
      |> append_if(states != [], {"states", Enum.join(states, ",")})
      |> append_if(template_id, {"template_id", template_id})

    case query do
      [] -> ~p"/recruiter/sessions"
      params -> ~p"/recruiter/sessions?#{params}"
    end
  end

  defp append_if(list, false, _), do: list
  defp append_if(list, nil, _), do: list
  defp append_if(list, _truthy, kv), do: list ++ [kv]

  defp parse_states(nil), do: []
  defp parse_states(""), do: []

  defp parse_states(raw) when is_binary(raw) do
    raw
    |> String.split(",", trim: true)
    |> Enum.filter(&(&1 in @all_states))
    |> Enum.sort()
  end

  defp parse_states(_), do: []

  defp parse_template(nil), do: nil
  defp parse_template(""), do: nil
  defp parse_template(id) when is_binary(id), do: id

  defp nilify([]), do: nil
  defp nilify(list), do: list

  # ---- Render ----------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-6" id="recruiter-sessions">
        <header>
          <h1 class="text-2xl font-semibold">Sessions</h1>
          <p class="text-sm opacity-70">Recordings for {@tenant.name}</p>
        </header>

        <section class="space-y-3" id="filters">
          <div class="flex flex-wrap items-center gap-2 text-sm">
            <span class="opacity-70">State:</span>
            <button
              :for={state <- @state_options}
              type="button"
              phx-click="filter_state"
              phx-value-state={state}
              class={[
                "btn btn-xs",
                state in @selected_states && "btn-primary"
              ]}
              id={"state-filter-#{state}"}
            >
              {state}
            </button>
          </div>

          <form phx-change="filter_template" class="flex items-center gap-2 text-sm">
            <label for="template_id" class="opacity-70">Template:</label>
            <select
              id="template_id"
              name="template_id"
              class="select select-sm"
            >
              <option value="">All</option>
              <option
                :for={t <- @templates}
                value={t.id}
                selected={@selected_template_id == t.id}
              >
                {t.name}
              </option>
            </select>
            <button
              :if={@selected_states != [] or @selected_template_id}
              type="button"
              phx-click="clear_filters"
              class="btn btn-xs btn-ghost"
            >
              Clear
            </button>
          </form>
        </section>

        <section class="space-y-3">
          <div
            :if={MapSet.size(@selected_ids) > 0}
            id="bulk-toolbar"
            class="flex flex-wrap items-baseline justify-between gap-3 text-sm border-b border-base-content/10 pb-2"
          >
            <p>
              <span class="font-medium">{MapSet.size(@selected_ids)}</span>
              <span class="opacity-70">selected</span>
            </p>
            <div class="flex items-baseline gap-5">
              <button
                type="button"
                phx-click="clear_selection"
                class="link opacity-70 hover:opacity-100"
              >
                Clear
              </button>
              <button
                type="button"
                phx-click="delete_selected"
                data-confirm={"Delete #{MapSet.size(@selected_ids)} sessions and their recordings? This can't be undone."}
                class="link text-error/80 hover:text-error"
              >
                Delete selected
              </button>
            </div>
          </div>

          <table class="table table-sm w-full" id="sessions-table">
            <thead>
              <tr>
                <th class="w-8">
                  <input
                    type="checkbox"
                    phx-click="toggle_select_all"
                    checked={
                      @visible_ids != [] and
                        MapSet.subset?(MapSet.new(@visible_ids), @selected_ids)
                    }
                    class="checkbox checkbox-sm"
                    aria-label="Select all visible sessions"
                  />
                </th>
                <th>Candidate</th>
                <th>Template</th>
                <th>State</th>
                <th>Completed</th>
                <th>Questions</th>
                <th>Duration</th>
                <th></th>
              </tr>
            </thead>
            <tbody id="sessions-tbody">
              <tr
                :for={row <- @sessions}
                id={"session-#{row.session.id}"}
                data-session-id={row.session.id}
              >
                <td>
                  <input
                    type="checkbox"
                    phx-click="toggle_select"
                    phx-value-id={row.session.id}
                    checked={MapSet.member?(@selected_ids, row.session.id)}
                    class="checkbox checkbox-sm"
                    aria-label={"Select session #{row.session.id}"}
                  />
                </td>
                <td>{row.session.candidate_email || "—"}</td>
                <td>
                  {row.template_name}
                  <span class="opacity-60">v{row.version_number}</span>
                </td>
                <td>
                  <span class={["badge", state_badge_class(row.session.state)]}>
                    {row.session.state}
                  </span>
                </td>
                <td>{format_time(row.session.completed_at)}</td>
                <td>{row.question_count}</td>
                <td>{format_duration(row.total_duration_ms)}</td>
                <td>
                  <div class="inline-flex items-baseline gap-4">
                    <.link
                      navigate={~p"/recruiter/sessions/#{row.session.id}"}
                      class="link link-primary"
                    >
                      Open
                    </.link>
                    <button
                      type="button"
                      phx-click="delete_session"
                      phx-value-id={row.session.id}
                      data-confirm="Delete this session and its recordings? This can't be undone."
                      class="link text-error/70 hover:text-error"
                    >
                      Delete
                    </button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>

          <p :if={@empty?} class="text-sm opacity-70 mt-4" id="empty-state">
            No sessions match the current filters.
          </p>
        </section>
      </div>
    </Layouts.app>
    """
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
