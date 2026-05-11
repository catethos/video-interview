defmodule InterviewWeb.Plugs.EmbedCSP do
  @moduledoc """
  Sets the headers required for the recorder LiveView to be embedded
  cross-origin. Per PLAN §4.4:

    * `Content-Security-Policy: frame-ancestors …` per-tenant, looked up
      from `tenants.frame_ancestors` via the URL session_id.
    * `Referrer-Policy: strict-origin-when-cross-origin`.
    * `Permissions-Policy: camera=(self), microphone=(self), autoplay=(self)`.
    * No `X-Frame-Options` — would override `frame-ancestors` in older browsers.

  Lookup order:

    1. If the URL has a `session_id` path param → fetch session → tenant
       → `tenant.frame_ancestors`.
    2. If the tenant exists but has no configured ancestors → `'self'`
       (deny external embedding by default; PLAN §4.4 wildcards-disallowed).
    3. If no session resolves → fall back to the legacy app-config list
       (used by tests + the Phase-0 harness) or `'self'` if no config.
  """
  import Plug.Conn

  alias Interview.Capture.Session
  alias Interview.Repo
  alias Interview.Tenants.Tenant

  def init(opts), do: opts

  def call(conn, _opts) do
    ancestors = resolve_ancestors(conn) |> Enum.join(" ")

    conn
    |> delete_resp_header("x-frame-options")
    |> put_resp_header("content-security-policy", "frame-ancestors #{ancestors}")
    |> put_resp_header("referrer-policy", "strict-origin-when-cross-origin")
    |> put_resp_header(
      "permissions-policy",
      "camera=(self), microphone=(self), autoplay=(self)"
    )
  end

  defp resolve_ancestors(conn) do
    case conn.path_params["session_id"] do
      sid when is_binary(sid) ->
        ancestors_for_session(sid) || fallback_ancestors()

      _ ->
        fallback_ancestors()
    end
  end

  defp ancestors_for_session(sid) do
    case Repo.get(Session, sid) do
      %Session{tenant_id: tid} ->
        case Repo.get(Tenant, tid) do
          %Tenant{frame_ancestors: list} when is_list(list) and list != [] -> list
          %Tenant{} -> ["'self'"]
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp fallback_ancestors do
    Application.get_env(:interview, :embed_frame_ancestors, ["'self'"])
  end
end
