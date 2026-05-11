defmodule InterviewWeb.CaptureSessionController do
  @moduledoc """
  Tiny dev convenience: `GET /capture/new` creates a `Capture.Session` for
  the seeded dev tenant + template and redirects to `/capture/:id`.

  Phase 2 replaces this with the real session-creation API (`POST
  /api/sessions` from a customer backend).
  """
  use InterviewWeb, :controller

  alias Interview.Auth.Bootstrap
  alias Interview.Capture.Session
  alias Interview.Repo
  alias Interview.Templates.Template
  alias Interview.Tenants.Tenant

  def new(conn, _params) do
    with %Tenant{id: tenant_id} <- Repo.get_by(Tenant, slug: "dev"),
         %Template{current_version_id: vid} when not is_nil(vid) <-
           Repo.get_by(Template, tenant_id: tenant_id, name: "Dev Template"),
         {:ok, %Session{} = session} <-
           %Session{}
           |> Session.changeset(%{
             tenant_id: tenant_id,
             template_version_id: vid,
             state: "in_progress"
           })
           |> Repo.insert(),
         {:ok, %{token: token}} <- Bootstrap.mint(session) do
      redirect(conn, to: ~p"/capture/#{session.id}?token=#{token}")
    else
      _ ->
        conn
        |> put_flash(:error, "Run mix run priv/repo/seeds.exs to set up the dev tenant.")
        |> redirect(to: ~p"/")
    end
  end
end
