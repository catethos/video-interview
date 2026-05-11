defmodule InterviewWeb.UserAuth do
  @moduledoc """
  LiveView `on_mount` callback that requires a recruiter session.

  Reads `:recruiter_token` from the LV session, verifies via
  `Interview.Auth.Tokens.verify_recruiter_session/1`, loads the recruiter
  + tenant, and assigns `:current_scope` (Phoenix v1.8 idiom). On miss it
  halts the mount with a redirect to `/auth/sign-in`.
  """
  import Phoenix.Component, only: [assign: 3]

  alias Interview.Auth.{Recruiters, Tokens}
  alias Interview.Repo
  alias Interview.Tenants.Tenant

  def on_mount(:ensure_recruiter, _params, session, socket) do
    case resolve(session) do
      {:ok, recruiter, tenant} ->
        socket =
          socket
          |> assign(:current_recruiter, recruiter)
          |> assign(:tenant, tenant)
          |> assign(:current_scope, %{recruiter: recruiter, tenant: tenant})

        {:cont, socket}

      :error ->
        {:halt, Phoenix.LiveView.redirect(socket, to: "/auth/sign-in")}
    end
  end

  defp resolve(session) when is_map(session) do
    case Map.get(session, "recruiter_token") || Map.get(session, :recruiter_token) do
      token when is_binary(token) ->
        with {:ok, %{rid: rid, tid: tid}} <- Tokens.verify_recruiter_session(token),
             %Recruiters.User{} = recruiter <- Recruiters.get_user(rid),
             %Tenant{} = tenant <- Repo.get(Tenant, tid),
             true <- recruiter.tenant_id == tenant.id do
          {:ok, recruiter, tenant}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp resolve(_), do: :error
end
