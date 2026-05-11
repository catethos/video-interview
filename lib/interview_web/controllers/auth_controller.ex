defmodule InterviewWeb.AuthController do
  @moduledoc """
  Recruiter session refresh + sign-in page.

  * `POST /api/auth/refresh` — RecruiterAuth-pipelined; returns a fresh
    `rk_*` token (and refreshes the cookie if the request used one).

  * `GET  /auth/sign-in` — static HTML page with the magic-link request
    form. Public (no auth).

  * `DELETE /auth/sign-out` — clears the session cookie + redirects.
  """
  use InterviewWeb, :controller

  alias Interview.Auth.Tokens

  def refresh(conn, _params) do
    recruiter = conn.assigns.current_recruiter
    tenant = conn.assigns.tenant
    token = Tokens.mint_recruiter_session(recruiter.id, tenant.id)

    conn
    |> put_session(:recruiter_token, token)
    |> configure_session(renew: true)
    |> json(%{
      token: token,
      expires_in: Tokens.recruiter_session_max_age()
    })
  end

  def sign_in(conn, _params) do
    conn
    |> put_view(html: InterviewWeb.AuthHTML)
    |> render(:sign_in, page_title: "Sign in")
  end

  def request_link_form(conn, %{"email" => email}) do
    requested_ip = conn.remote_ip |> :inet.ntoa() |> to_string()
    _ = Interview.Auth.Recruiters.request_magic_link(email, requested_ip)

    conn
    |> put_view(html: InterviewWeb.AuthHTML)
    |> render(:request_link, page_title: "Check your inbox")
  end

  def sign_out(conn, _params) do
    if user = conn.assigns[:current_recruiter] do
      Interview.Audit.log!(%{
        tenant_id: user.tenant_id,
        actor_kind: "recruiter",
        actor_id: user.id,
        action: "recruiter.sign_out",
        subject_kind: "recruiter_user",
        subject_id: user.id,
        ip_address: conn.remote_ip |> :inet.ntoa() |> to_string()
      })
    end

    conn
    |> clear_session()
    |> configure_session(drop: true)
    |> redirect(to: "/auth/sign-in")
  end
end
