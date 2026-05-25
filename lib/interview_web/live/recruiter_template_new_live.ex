defmodule InterviewWeb.RecruiterTemplateNewLive do
  @moduledoc """
  Entry point for the deep-link template-creation flow.

  External systems (e.g. Pulsifi) send a recruiter to:

      /recruiter/templates/new?return_to=<url>&state=<token>&name=<role>

  This LiveView creates a fresh template + draft version under the
  recruiter's tenant, then redirects (`push_navigate`) to the editor
  with `return_to`/`state` preserved as query params. The editor
  (`RecruiterTemplateLive`) is where the recruiter authors questions and
  publishes — at which point it bounces the browser back to `return_to`.

  Without `return_to`, this still works for plain recruiter-initiated
  template creation — just lands on the editor with a fresh draft.
  """
  use InterviewWeb, :live_view

  alias Interview.Templates

  @impl true
  def mount(params, _session, socket) do
    tenant = socket.assigns.tenant
    recruiter = socket.assigns.current_recruiter
    name = sanitize_name(params["name"])

    attrs = %{
      "tenant_id" => tenant.id,
      "name" => name,
      "created_by_id" => recruiter && recruiter.id
    }

    with {:ok, template} <- Templates.create_template(attrs),
         {:ok, draft} <- Templates.create_draft_version(template),
         {:ok, _stamped} <- stamp_external_return(draft, params) do
      query = passthrough_query(params)
      target = "/recruiter/templates/#{template.id}" <> query
      {:ok, push_navigate(socket, to: target)}
    else
      {:error, changeset} ->
        {:ok,
         socket
         |> put_flash(:error, "Could not create template: #{inspect(changeset.errors)}")
         |> push_navigate(to: ~p"/recruiter/templates")}
    end
  end

  @impl true
  def render(assigns) do
    # No UI — the mount push_navigates immediately. A minimal placeholder
    # in case anyone watches the LiveDashboard or sees a brief flash.
    ~H"""
    <main class="p-8 text-slate-500">Setting up your interview template…</main>
    """
  end

  # Persist return_to/state on the draft so a subsequent re-mount of
  # RecruiterTemplateLive can rebuild external_integration even if an
  # in-LV navigation (e.g. the prompt recorder) stripped them from the
  # URL. No-op when the deep-link wasn't initiated externally.
  defp stamp_external_return(draft, params) do
    return_to = params["return_to"]
    state = params["state"]

    if is_binary(return_to) and return_to != "" do
      Templates.update_draft_version(draft, %{
        "external_return_url" => return_to,
        "external_return_state" => state
      })
    else
      {:ok, draft}
    end
  end

  defp sanitize_name(nil), do: default_name()
  defp sanitize_name(""), do: default_name()

  defp sanitize_name(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.slice(0, 255)
    |> case do
      "" -> default_name()
      trimmed -> trimmed
    end
  end

  defp default_name do
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y-%m-%d %H:%M")
    "Untitled interview — #{stamp}"
  end

  # Forward only the keys the editor cares about; ignore everything else
  # to keep the URL surface tight.
  defp passthrough_query(params) do
    [{"return_to", params["return_to"]}, {"state", params["state"]}]
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> case do
      [] -> ""
      pairs -> "?" <> URI.encode_query(pairs)
    end
  end
end
