defmodule InterviewWeb.PlaybackUrlController do
  @moduledoc """
  Mints short-lived signed playback URLs for embedding a response's MP4
  in an external recruiter dashboard (PLAN §8.5 change 3).

  Route:

    * `POST /api/responses/:id/playback_url`

  Authenticated via `InterviewWeb.Plugs.TenantAuth`. The response must
  belong to the caller's tenant and be in the `ready` state — earlier
  states have no playable artifact yet, so minting a URL would just hand
  out a 404.

  Token TTL is 1 hour (`Interview.Auth.Tokens.playback_url_max_age/0`).
  The URL is self-contained: drop the returned `url` into a `<video src>`
  and it plays without cookies. After expiry, the URL stops working —
  leaked URLs die on their own, no revocation surface.
  """
  use InterviewWeb, :controller

  alias Interview.Auth.Tokens
  alias Interview.Playback

  def create(conn, %{"id" => response_id}) do
    tenant = conn.assigns.tenant

    case Playback.get_response_for_playback(tenant.id, response_id) do
      %{state: "ready", storage_key: key} when is_binary(key) ->
        token = Tokens.mint_playback_url_token(response_id, tenant.id)
        url = build_url(conn, response_id, token)
        expires_at = DateTime.utc_now() |> DateTime.add(Tokens.playback_url_max_age(), :second)

        json(conn, %{
          url: url,
          expires_at: DateTime.to_iso8601(expires_at)
        })

      %{} ->
        # Response exists but isn't playable yet — finalizer in flight.
        conn
        |> put_status(:conflict)
        |> json(%{
          error: "response_not_ready",
          hint: "the response is still being finalized; wait for session.ready"
        })

      nil ->
        # Either missing or belongs to another tenant. Don't leak existence.
        conn |> put_status(:not_found) |> json(%{error: "response_not_found"})
    end
  end

  # Build a fully-qualified URL using the endpoint's configured host so
  # the returned link works outside this server's context. Phoenix's
  # ~p sigil yields a path-only URL; we prepend the endpoint's URL.
  defp build_url(conn, response_id, token) do
    endpoint_url = InterviewWeb.Endpoint.url()
    path = ~p"/playback/#{response_id}"
    query = URI.encode_query(%{"token" => token})

    # If endpoint_url already encodes the host, just concatenate. If we're
    # running behind a reverse proxy, the endpoint config should set
    # url:[host:, scheme:, port:] so this still produces the public URL.
    _ = conn
    endpoint_url <> path <> "?" <> query
  end
end
