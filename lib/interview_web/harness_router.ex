defmodule InterviewWeb.HarnessRouter do
  @moduledoc """
  Tiny Plug-only router used by the Phase-0 third-party iframe harness.

  Serves a static HTML page that embeds the recorder iframe from a *different*
  hostname than the recorder. This is what we need to validate IndexedDB
  partitioning, postMessage origin handling, and Permissions-Policy
  inheritance — all of which behave differently in cross-site iframes.

  Bound to 127.0.0.1:5174; the recorder lives on localhost:4000. Same machine,
  different hosts → different storage-partition sites.

  Doubles as a stand-in **customer backend**: `POST /session` mints a fresh
  session + bootstrap token against the seeded dev tenant, so the demo
  page can hand the iframe a valid token without baking the dev API key
  into the HTML. `POST /session/:id/bootstrap` re-mints (used by the
  pop-out + duplicate-tab buttons; PLAN §5.5).
  """
  use Plug.Router

  alias Interview.Auth.Bootstrap
  alias Interview.Capture.Session
  alias Interview.Repo
  alias Interview.Templates.Template
  alias Interview.Tenants.Tenant

  plug :match
  plug Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason
  plug :dispatch

  get "/" do
    path = Path.join(:code.priv_dir(:interview), "harness/index.html")

    case File.read(path) do
      {:ok, html} ->
        conn
        |> put_resp_header("content-type", "text/html; charset=utf-8")
        # Aggressive cache-bust during dev.
        |> put_resp_header("cache-control", "no-cache, no-store, must-revalidate")
        # The harness is a "customer" page; the recorder is in a cross-site iframe.
        # Customer pages have to advertise Permissions-Policy that delegates camera
        # and microphone to the recorder origin or the iframe permission grant fails.
        |> put_resp_header(
          "permissions-policy",
          "camera=(self \"http://localhost:4000\"), microphone=(self \"http://localhost:4000\"), autoplay=(self \"http://localhost:4000\")"
        )
        |> send_resp(200, html)

      {:error, reason} ->
        send_resp(conn, 500, "harness page missing: #{inspect(reason)}")
    end
  end

  post "/session" do
    case mint_for_dev_tenant() do
      {:ok, session, token} ->
        json_resp(conn, 200, %{session_id: session.id, bootstrap_token: token})

      {:error, reason} ->
        json_resp(conn, 500, %{error: to_string(reason)})
    end
  end

  post "/session/:id/bootstrap" do
    with {:ok, %Tenant{id: tid}} <- fetch_dev_tenant(),
         %Session{tenant_id: ^tid} = session <- Repo.get(Session, id),
         {:ok, %{token: token}} <- Bootstrap.mint(session) do
      json_resp(conn, 200, %{session_id: session.id, bootstrap_token: token})
    else
      _ -> json_resp(conn, 404, %{error: "session_not_found_for_dev_tenant"})
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # ---- helpers -------------------------------------------------------

  defp mint_for_dev_tenant do
    with {:ok, tenant} <- fetch_dev_tenant(),
         {:ok, template} <- fetch_dev_template(tenant.id),
         {:ok, session} <- create_session(tenant.id, template.current_version_id),
         {:ok, %{token: token}} <- Bootstrap.mint(session) do
      {:ok, session, token}
    end
  end

  defp fetch_dev_tenant do
    case Repo.get_by(Tenant, slug: "dev") do
      %Tenant{} = t -> {:ok, t}
      _ -> {:error, :dev_tenant_missing}
    end
  end

  defp fetch_dev_template(tenant_id) do
    case Repo.get_by(Template, tenant_id: tenant_id, name: "Dev Template") do
      %Template{current_version_id: vid} = t when not is_nil(vid) -> {:ok, t}
      %Template{} -> {:error, :dev_template_unpublished}
      _ -> {:error, :dev_template_missing}
    end
  end

  defp create_session(tenant_id, template_version_id) do
    %Session{}
    |> Session.changeset(%{
      tenant_id: tenant_id,
      template_version_id: template_version_id,
      state: "in_progress"
    })
    |> Repo.insert()
  end

  defp json_resp(conn, status, body) do
    conn
    |> put_resp_header("content-type", "application/json; charset=utf-8")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, Jason.encode!(body))
  end
end
