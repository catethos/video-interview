defmodule InterviewWeb.ApiKeyController do
  @moduledoc """
  Tenant API key management (PLAN §4.2).

  Recruiter-authed via the `:recruiter_only` pipeline. The plaintext
  bearer is returned **only** from `create/2` — the dashboard must capture
  it on issue.
  """
  use InterviewWeb, :controller

  alias Interview.Auth.ApiKeys

  def index(conn, _params) do
    tenant = conn.assigns.tenant
    keys = tenant.id |> ApiKeys.list() |> Enum.map(&render_key/1)
    json(conn, %{api_keys: keys})
  end

  def create(conn, params) do
    tenant = conn.assigns.tenant
    recruiter = conn.assigns.current_recruiter
    name = params["name"] || ""

    if name == "" do
      conn |> put_status(:unprocessable_entity) |> json(%{error: "name_required"})
    else
      case ApiKeys.create(tenant.id, name, recruiter && recruiter.id) do
        {:ok, %{api_key: key, secret: secret}} ->
          conn
          |> put_status(:created)
          |> json(%{api_key: render_key(key), secret: secret})

        {:error, cs} ->
          conn |> put_status(:unprocessable_entity) |> json(changeset_errors(cs))
      end
    end
  end

  def revoke(conn, %{"id" => id}) do
    tenant = conn.assigns.tenant

    case ApiKeys.revoke(tenant.id, id) do
      {:ok, key} -> json(conn, %{api_key: render_key(key)})
      {:error, :not_found} -> conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  defp render_key(k) do
    %{
      id: k.id,
      name: k.name,
      prefix: k.prefix,
      last_used_at: k.last_used_at,
      revoked_at: k.revoked_at,
      created_by_id: k.created_by_id,
      inserted_at: k.inserted_at
    }
  end

  defp changeset_errors(%Ecto.Changeset{} = cs) do
    %{
      errors:
        Enum.map(cs.errors, fn {field, {msg, _}} ->
          %{pointer: "/#{field}", message: msg}
        end)
    }
  end
end
