defmodule InterviewWeb.MagicLinkController do
  @moduledoc """
  Magic-link sign-in (PLAN §11 #8).

  * `POST /api/auth/magic-links` — request a link by email. Always 202
    regardless of email validity (no enumeration). The link is logged via
    `Logger.info` (no SMTP in v1).

  * `GET  /auth/magic-link/:token` — consume. On success: mints a recruiter
    session JWT, sets `:recruiter_token` in the Phoenix session cookie,
    redirects to the dashboard. On failure: renders a static error page.
  """
  use InterviewWeb, :controller

  alias Interview.Auth.{Recruiters, Tokens}

  def request(conn, params) do
    email = params["email"] || ""

    if is_binary(email) and email != "" do
      requested_ip = conn.remote_ip |> :inet.ntoa() |> to_string()
      _ = Recruiters.request_magic_link(email, requested_ip)
    end

    conn
    |> put_status(:accepted)
    |> json(%{status: "accepted"})
  end

  def consume(conn, %{"token" => raw}) do
    case Recruiters.consume_magic_link(raw) do
      {:ok, user} ->
        token = Tokens.mint_recruiter_session(user.id, user.tenant_id)

        Interview.Audit.log!(%{
          tenant_id: user.tenant_id,
          actor_kind: "recruiter",
          actor_id: user.id,
          action: "recruiter.sign_in",
          subject_kind: "recruiter_user",
          subject_id: user.id,
          ip_address: conn.remote_ip |> :inet.ntoa() |> to_string(),
          user_agent: conn |> Plug.Conn.get_req_header("user-agent") |> List.first(),
          metadata: %{"source" => "magic_link"}
        })

        conn
        |> put_session(:recruiter_token, token)
        |> configure_session(renew: true)
        |> redirect(to: "/recruiter/templates")

      {:error, reason} ->
        conn
        |> put_status(:unauthorized)
        |> render_error(reason)
    end
  end

  defp render_error(conn, reason) do
    msg =
      case reason do
        :consumed -> "This sign-in link has already been used. Request a new one."
        :expired -> "This sign-in link has expired. Request a new one."
        _ -> "This sign-in link is invalid. Request a new one."
      end

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(401, """
    <!doctype html>
    <html>
    <head><meta charset="utf-8"><title>Sign-in link error</title></head>
    <body style="font-family: system-ui; max-width: 480px; margin: 4rem auto; padding: 0 1rem;">
      <h1>Sign-in link error</h1>
      <p>#{msg}</p>
      <p><a href="/auth/sign-in">Request a new sign-in link</a></p>
    </body>
    </html>
    """)
  end
end
