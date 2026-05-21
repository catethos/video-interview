defmodule InterviewWeb.RecruiterTemplatesLive do
  @moduledoc """
  Recruiter dashboard list of templates for the current tenant. Click a
  row to drop into `RecruiterTemplateLive` for editing; or hit "New
  template" to mint a fresh one and immediately edit it.
  """
  use InterviewWeb, :live_view

  alias Interview.Templates

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_templates(socket)}
  end

  defp assign_templates(socket) do
    tenant_id = socket.assigns.tenant.id
    templates = Templates.list_templates(tenant_id)

    rows =
      Enum.map(templates, fn template ->
        current =
          template.current_version_id && Templates.get_version(template.current_version_id)

        versions = Templates.list_versions(template.id)

        %{
          template: template,
          current_version: current,
          version_count: length(versions),
          published_count: Enum.count(versions, & &1.published_at)
        }
      end)

    socket
    |> assign(:rows, rows)
    |> assign(:empty?, rows == [])
    |> assign(:new_name, "")
  end

  @impl true
  def handle_event("update_new_name", %{"name" => name}, socket) do
    {:noreply, assign(socket, :new_name, name)}
  end

  def handle_event("create", %{"name" => name}, socket) do
    name = String.trim(name)

    cond do
      name == "" ->
        {:noreply, put_flash(socket, :error, "Name is required")}

      true ->
        attrs = %{tenant_id: socket.assigns.tenant.id, name: name}

        case Templates.create_template(attrs) do
          {:ok, template} ->
            {:noreply,
             socket
             |> push_navigate(to: ~p"/recruiter/templates/#{template.id}")}

          {:error, changeset} ->
            {:noreply,
             put_flash(socket, :error, "Failed to create: #{inspect(changeset.errors)}")}
        end
    end
  end

  # ---- Render ----------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-6" id="recruiter-templates">
        <header>
          <h1 class="text-2xl font-semibold">Templates</h1>
          <p class="text-sm opacity-70">Question sets for {@tenant.name}</p>
        </header>

        <section>
          <form
            phx-submit="create"
            phx-change="update_new_name"
            class="flex items-end gap-2"
            id="create-template-form"
          >
            <label class="flex-1">
              <span class="text-xs opacity-70">New template name</span>
              <input
                type="text"
                name="name"
                value={@new_name}
                placeholder="e.g. SDR phone screen"
                class="input input-sm w-full"
                autocomplete="off"
              />
            </label>
            <button type="submit" class="btn btn-sm btn-primary" id="create-template">
              Create
            </button>
          </form>
        </section>

        <section>
          <table class="table table-sm w-full" id="templates-table">
            <thead>
              <tr>
                <th>Name</th>
                <th>Current version</th>
                <th>Versions</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={row <- @rows}
                id={"template-#{row.template.id}"}
                data-template-id={row.template.id}
              >
                <td>
                  <div class="font-semibold">{row.template.name}</div>
                  <div :if={row.template.description} class="text-xs opacity-70">
                    {row.template.description}
                  </div>
                </td>
                <td>
                  <span :if={row.current_version}>
                    v{row.current_version.version_number}
                    <span class="opacity-60 text-xs">
                      published {format_time(row.current_version.published_at)}
                    </span>
                  </span>
                  <span :if={is_nil(row.current_version)} class="opacity-70 italic">
                    no published version
                  </span>
                </td>
                <td>
                  {row.published_count} published / {row.version_count} total
                </td>
                <td>
                  <.link
                    navigate={~p"/recruiter/templates/#{row.template.id}"}
                    class="link link-primary"
                  >
                    Edit
                  </.link>
                </td>
              </tr>
            </tbody>
          </table>

          <p :if={@empty?} class="text-sm opacity-70 mt-4" id="empty-state">
            No templates yet. Create one above to get started.
          </p>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp format_time(nil), do: "—"

  defp format_time(%DateTime{} = dt) do
    dt |> DateTime.truncate(:second) |> DateTime.to_string()
  end
end
