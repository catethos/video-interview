defmodule InterviewWeb.Plugs.TenantAuth do
  @moduledoc """
  Bearer auth for tenant-scoped APIs (`/api/templates*`, `/api/sessions`).

  Accepts EITHER:

    * `Authorization: Bearer tk_<...>` — server-to-server tenant API key
      (`Interview.Auth.ApiKeys.verify/1`).
    * `Authorization: Bearer rk_<...>` — recruiter session token
      (`Interview.Auth.Tokens.verify_recruiter_session/1`).

  On success: assigns `:tenant`, and (for the rk_ path) `:current_recruiter`.
  On failure: 401 + halt.
  """
  import Plug.Conn

  alias Interview.Auth.{ApiKeys, Recruiters, Tokens}
  alias Interview.Repo
  alias Interview.Tenants.Tenant

  def init(opts), do: opts

  def call(conn, _opts) do
    case parse_bearer(conn) do
      {:ok, "tk_" <> _ = bearer} -> resolve_api_key(conn, bearer)
      {:ok, "rk_" <> _ = bearer} -> resolve_recruiter(conn, bearer)
      _ -> deny(conn)
    end
  end

  defp parse_bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> rest] -> {:ok, String.trim(rest)}
      _ -> :error
    end
  end

  defp resolve_api_key(conn, bearer) do
    case ApiKeys.verify(bearer) do
      {:ok, %{tenant: %Tenant{} = tenant}} ->
        conn
        |> assign(:tenant, tenant)
        |> assign(:current_recruiter, nil)

      _ ->
        deny(conn)
    end
  end

  defp resolve_recruiter(conn, bearer) do
    with {:ok, %{rid: rid, tid: tid}} <- Tokens.verify_recruiter_session(bearer),
         %Recruiters.User{} = recruiter <- Recruiters.get_user(rid),
         %Tenant{} = tenant <- Repo.get(Tenant, tid),
         true <- recruiter.tenant_id == tenant.id do
      conn
      |> assign(:tenant, tenant)
      |> assign(:current_recruiter, recruiter)
    else
      _ -> deny(conn)
    end
  end

  defp deny(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, ~s({"error":"unauthorized"}))
    |> halt()
  end
end
