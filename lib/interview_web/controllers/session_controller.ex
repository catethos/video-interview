defmodule InterviewWeb.SessionController do
  @moduledoc """
  Server-to-server session creation (PLAN §4.2 step 1).

  Authenticated via `InterviewWeb.Plugs.TenantAuth` (api key OR recruiter
  bearer). The chosen `template_version_id` is **frozen** on the row at
  creation per PLAN §3.4 versioning rule.

  Routes:

    * `POST /api/sessions`               — create + mint bootstrap
    * `POST /api/sessions/:id/bootstrap` — re-mint bootstrap (rotates jti)
  """
  use InterviewWeb, :controller

  alias Interview.Auth.Bootstrap
  alias Interview.Capture.Session
  alias Interview.Repo
  alias Interview.Templates
  alias Interview.Templates.{Template, Version}

  def create(conn, params) do
    tenant = conn.assigns.tenant
    candidate_email = params["candidate_email"]

    with {:ok, version} <- resolve_version(tenant, params),
         {:ok, session} <- insert_session(tenant, version, candidate_email, params),
         {:ok, %{token: token}} <- Bootstrap.mint(session) do
      Interview.Audit.log!(%{
        tenant_id: tenant.id,
        actor_kind: actor_kind(conn),
        actor_id: actor_id(conn),
        action: "session.create",
        subject_kind: "session",
        subject_id: session.id,
        ip_address: client_ip(conn),
        user_agent: user_agent(conn),
        metadata: %{
          "template_version_id" => version.id,
          "external_id" => session.external_id
        }
      })

      conn
      |> put_status(:created)
      |> json(%{
        id: session.id,
        bootstrap_token: token,
        template_version_id: version.id
      })
    else
      {:error, :template_not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "template_not_found"})

      {:error, :no_current_version} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "template_has_no_published_version"})

      {:error, :version_not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "template_version_not_found"})

      {:error, :missing_template_ref} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "template_id_or_template_version_id_required"})

      {:error, %Ecto.Changeset{} = cs} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          errors: Enum.map(cs.errors, fn {f, {msg, _}} -> %{pointer: "/#{f}", message: msg} end)
        })
    end
  end

  def rebootstrap(conn, %{"id" => id}) do
    tenant = conn.assigns.tenant

    case Repo.get(Session, id) do
      %Session{tenant_id: tid} = session when tid == tenant.id ->
        {:ok, %{token: token}} = Bootstrap.mint(session)
        json(conn, %{id: session.id, bootstrap_token: token})

      _ ->
        conn |> put_status(:not_found) |> json(%{error: "session_not_found"})
    end
  end

  @doc """
  Right-to-delete (PLAN §7 Phase 4, §8.3). Soft-deletes the session row
  immediately and enqueues `Interview.Workers.SessionDeletion` to scrub
  storage. Fires `session.deleted` webhook on completion.
  """
  def delete(conn, %{"id" => id}) do
    tenant = conn.assigns.tenant

    case Repo.get(Session, id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "session_not_found"})

      %Session{tenant_id: tid} when tid != tenant.id ->
        conn |> put_status(:not_found) |> json(%{error: "session_not_found"})

      %Session{} = session ->
        audit = %{
          actor_kind: actor_kind(conn),
          actor_id: actor_id(conn),
          ip_address: client_ip(conn),
          user_agent: user_agent(conn)
        }

        case Interview.Capture.soft_delete_session(session.id, audit) do
          {:ok, :already_deleted} ->
            json(put_status(conn, :accepted), %{id: session.id, status: "already_deleted"})

          {:ok, :deleted} ->
            json(put_status(conn, :accepted), %{id: session.id, status: "accepted"})
        end
    end
  end

  # ---- helpers -----------------------------------------------------------

  defp resolve_version(tenant, %{"template_version_id" => vid}) when is_binary(vid) do
    with %Version{template_id: tpl_id} = version <- Repo.get(Version, vid),
         %Template{tenant_id: tid} <- Repo.get(Template, tpl_id),
         true <- tid == tenant.id do
      {:ok, version}
    else
      _ -> {:error, :version_not_found}
    end
  end

  defp resolve_version(tenant, %{"template_id" => tid}) when is_binary(tid) do
    case Repo.get(Template, tid) do
      %Template{tenant_id: tenant_id} = template when tenant_id == tenant.id ->
        if is_nil(template.current_version_id) do
          {:error, :no_current_version}
        else
          {:ok, Templates.get_version!(template.current_version_id)}
        end

      _ ->
        {:error, :template_not_found}
    end
  end

  defp resolve_version(_tenant, _), do: {:error, :missing_template_ref}

  defp insert_session(tenant, version, candidate_email, params) do
    %Session{}
    |> Session.changeset(%{
      tenant_id: tenant.id,
      template_version_id: version.id,
      candidate_email: candidate_email,
      external_id: params["external_id"],
      job_role: params["job_role"],
      job_description: params["job_description"],
      state: "in_progress"
    })
    |> Repo.insert()
  end

  defp client_ip(conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [value | _] -> value |> String.split(",") |> List.first() |> String.trim()
      _ -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end

  defp user_agent(conn) do
    case Plug.Conn.get_req_header(conn, "user-agent") do
      [ua | _] -> ua
      _ -> nil
    end
  end

  defp actor_kind(%Plug.Conn{assigns: %{current_recruiter: %{id: _}}}), do: "recruiter"
  defp actor_kind(_), do: "tenant_api_key"

  defp actor_id(%Plug.Conn{assigns: %{current_recruiter: %{id: id}}}), do: id
  defp actor_id(_), do: nil
end
