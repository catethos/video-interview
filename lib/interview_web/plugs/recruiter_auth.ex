defmodule InterviewWeb.Plugs.RecruiterAuth do
  @moduledoc """
  Recruiter-only auth (tenant API key CRUD, dashboard mounts, refresh).

  Accepts EITHER:

    * Phoenix session cookie (`get_session(conn, :recruiter_token)`) — set
      on magic-link consume; the canonical path for dashboard navigation.
    * `Authorization: Bearer rk_<...>` — for direct API calls / cli use.

  On success: assigns `:current_recruiter`, `:tenant`, and
  `:current_scope = %{recruiter, tenant}` for `<Layouts.app>`.

  On failure for HTML requests: redirect to `/auth/sign-in`. For JSON: 401.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  alias Interview.Auth.{Recruiters, Tokens}
  alias Interview.Repo
  alias Interview.Tenants.Tenant

  def init(opts), do: opts

  def call(conn, _opts) do
    case resolve(conn) do
      {:ok, recruiter, tenant} ->
        conn
        |> assign(:current_recruiter, recruiter)
        |> assign(:tenant, tenant)
        |> assign(:current_scope, %{recruiter: recruiter, tenant: tenant})

      :error ->
        deny(conn)
    end
  end

  defp resolve(conn) do
    with :error <- from_session(conn),
         :error <- from_bearer(conn) do
      :error
    end
  end

  defp from_session(conn) do
    case get_session(conn, :recruiter_token) do
      token when is_binary(token) -> verify_token(token)
      _ -> :error
    end
  end

  defp from_bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> rest] -> rest |> String.trim() |> verify_token()
      _ -> :error
    end
  end

  defp verify_token(token) do
    with {:ok, %{rid: rid, tid: tid}} <- Tokens.verify_recruiter_session(token),
         %Recruiters.User{} = recruiter <- Recruiters.get_user(rid),
         %Tenant{} = tenant <- Repo.get(Tenant, tid),
         true <- recruiter.tenant_id == tenant.id do
      {:ok, recruiter, tenant}
    else
      _ -> :error
    end
  end

  defp deny(conn) do
    if json_request?(conn) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(401, ~s({"error":"unauthorized"}))
      |> halt()
    else
      conn
      |> redirect(to: "/auth/sign-in")
      |> halt()
    end
  end

  defp json_request?(conn) do
    Enum.any?(get_req_header(conn, "accept"), &String.contains?(&1, "json")) or
      match?(["application/json" <> _], get_req_header(conn, "content-type"))
  end
end
