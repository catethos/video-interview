defmodule InterviewWeb.RecruiterHandoffController do
  @moduledoc """
  Server-to-server recruiter handoff for external systems (e.g. Pulsifi).

  Two endpoints:

    * `POST /api/recruiter-handoffs` — tenant-API-key auth. Picks the
      tenant's deterministic recruiter (alphabetically first), mints a
      short-lived handoff token, returns a `url` the caller embeds in
      their deep-link. The caller never names a recruiter id — the
      server picks it — so a leaked tenant key cannot impersonate an
      arbitrary recruiter outside the tenant's own pool.

    * `GET /auth/handoff?token=...&next=...` — browser-facing. Verifies
      the token, sets the recruiter session cookie, redirects to `next`.
      `next` is restricted to relative paths starting with
      `/recruiter/templates/` so a forged or replayed token cannot
      pivot the browser to an arbitrary URL (open-redirect guard).
  """
  use InterviewWeb, :controller

  alias Interview.Auth.Recruiters
  alias Interview.Auth.Tokens

  # ---- Mint (server-to-server, tenant API key) ----------------------------

  def create(conn, params) do
    tenant = conn.assigns.tenant

    case Recruiters.get_handoff_recruiter(tenant.id) do
      nil ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error: "no_recruiter",
          hint: "tenant has no recruiters; create one in the recruiter dashboard first"
        })

      recruiter ->
        token = Tokens.mint_recruiter_handoff(recruiter.id, tenant.id)

        next =
          case params do
            %{"next" => n} when is_binary(n) and n != "" -> n
            _ -> "/recruiter/templates"
          end

        url = build_handoff_url(token, next)

        expires_at =
          DateTime.utc_now() |> DateTime.add(Tokens.recruiter_handoff_max_age(), :second)

        json(conn, %{url: url, expires_at: DateTime.to_iso8601(expires_at)})
    end
  end

  # ---- Consume (browser-facing) ------------------------------------------

  def consume(conn, params) do
    with token when is_binary(token) <- params["token"] || :missing_token,
         {:ok, %{rid: rid, tid: tid}} <- Tokens.verify_recruiter_handoff(token),
         %Recruiters.User{tenant_id: ^tid} = recruiter <- Recruiters.get_user(rid),
         {:ok, next} <- safe_next(params["next"]) do
      session_token = Tokens.mint_recruiter_session(recruiter.id, recruiter.tenant_id)

      conn
      |> put_session(:recruiter_token, session_token)
      |> configure_session(renew: true)
      |> redirect(to: next)
    else
      _ ->
        conn
        |> put_flash(:error, "That sign-in link is invalid or expired. Please try again.")
        |> redirect(to: ~p"/auth/sign-in")
    end
  end

  # ---- Helpers ------------------------------------------------------------

  defp build_handoff_url(token, next) do
    endpoint_url = InterviewWeb.Endpoint.url()
    query = URI.encode_query(%{"token" => token, "next" => next})
    endpoint_url <> "/auth/handoff?" <> query
  end

  # Open-redirect guard: the `next` URL must be a relative path inside
  # the recruiter dashboard. Reject schemes, hosts, parent-dir tricks.
  # Query strings are allowed (the deep-link target carries return_to+state).
  defp safe_next(nil), do: {:ok, "/recruiter/templates"}
  defp safe_next(""), do: {:ok, "/recruiter/templates"}

  defp safe_next(path) when is_binary(path) do
    cond do
      String.starts_with?(path, "/recruiter/templates") and not String.contains?(path, "..") ->
        {:ok, path}

      true ->
        {:error, :next_not_allowed}
    end
  end

  defp safe_next(_), do: {:error, :next_not_allowed}
end
