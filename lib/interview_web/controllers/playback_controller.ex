defmodule InterviewWeb.PlaybackController do
  @moduledoc """
  Streams a finalized response artifact to the recruiter UI (PLAN —
  playback-plan.md §"Playback controller").

  Sits inside `live_session :recruiter`-style auth: the conn must already
  carry a verified recruiter session (handled by the
  `InterviewWeb.Plugs.RecruiterAuth` pipeline, which puts `:tenant` /
  `:current_recruiter` in the assigns).

  Flow per request:
    1. `Playback.get_response_for_playback/2` — returns nil for any
       cross-tenant or unknown response. We answer 404 (not 403) so we
       don't leak existence.
    2. Response must be in `ready` state with a non-nil `storage_key`,
       else 404 — earlier states have no playable artifact.
    3. Stream the file from disk with HTTP `Range` support so the
       `<video>` element can seek. `Plug.Conn.send_file/5` handles the
       OS-level sendfile; we parse `Range: bytes=a-b` ourselves.

  The Tigris/S3 swap (deferred): when `Interview.Storage` grows a
  `playback_url/2`, this controller's body becomes a redirect to a
  presigned URL. The route shape stays the same.
  """
  use InterviewWeb, :controller

  alias Interview.Auth.Tokens
  alias Interview.Playback
  alias Interview.Storage

  @cache_control "private, max-age=60"
  @content_type "video/mp4"

  @doc """
  Recruiter dashboard playback (cookie-authenticated). The
  `:recruiter_browser` pipeline has already verified the recruiter
  session and populated `conn.assigns.tenant`.
  """
  def show(conn, %{"response_id" => response_id}) do
    serve(conn, conn.assigns.tenant.id, response_id)
  end

  @doc """
  External / signed-URL playback (no cookie required). Verifies the
  `?token=...` query param via `Interview.Auth.Tokens.verify_playback_url_token/1`
  and serves only if the token's `rid` matches the requested response id
  AND the token's tenant matches the response's tenant.

  A stolen token cannot be repurposed for a different response: the
  controller checks `token.rid == path :response_id` before serving.
  """
  def show_signed(conn, %{"response_id" => response_id} = params) do
    with token when is_binary(token) <- params["token"] || :missing_token,
         {:ok, %{rid: rid, tid: tid}} <- Tokens.verify_playback_url_token(token),
         true <- rid == response_id do
      serve(conn, tid, response_id)
    else
      _ -> not_found(conn)
    end
  end

  defp serve(conn, tenant_id, response_id) do
    with %{state: "ready", storage_key: key} = response when is_binary(key) <-
           Playback.get_response_for_playback(tenant_id, response_id),
         path = Storage.artifact_path(key),
         {:ok, %{size: size}} <- File.stat(path) do
      send_artifact(conn, path, size, response)
    else
      _ -> not_found(conn)
    end
  end

  defp send_artifact(conn, path, size, _response) do
    conn =
      conn
      |> put_resp_content_type(@content_type)
      |> put_resp_header("accept-ranges", "bytes")
      |> put_resp_header("cache-control", @cache_control)

    case parse_range(get_req_header(conn, "range"), size) do
      :no_range ->
        conn
        |> put_resp_header("content-length", Integer.to_string(size))
        |> send_file(200, path)

      {:ok, first, last} ->
        length = last - first + 1

        conn
        |> put_resp_header(
          "content-range",
          "bytes #{first}-#{last}/#{size}"
        )
        |> put_resp_header("content-length", Integer.to_string(length))
        |> send_file(206, path, first, length)

      :unsatisfiable ->
        conn
        |> put_resp_header("content-range", "bytes */#{size}")
        |> send_resp(416, "")
    end
  end

  defp not_found(conn) do
    conn
    |> put_status(404)
    |> put_resp_content_type("text/plain")
    |> send_resp(404, "not found")
  end

  # Parses a single-range `Range: bytes=a-b` header. Multi-range requests
  # (e.g. `bytes=0-10,20-30`) are uncommon for `<video>` and we treat them
  # as "no range" so we just return the full body.
  defp parse_range([], _size), do: :no_range

  defp parse_range([raw | _], size) when is_binary(raw) do
    case String.split(raw, "=", parts: 2) do
      ["bytes", spec] ->
        spec |> String.split(",") |> List.first() |> parse_byte_spec(size)

      _ ->
        :no_range
    end
  end

  defp parse_range(_, _), do: :no_range

  defp parse_byte_spec(spec, size) when is_binary(spec) do
    case String.split(String.trim(spec), "-", parts: 2) do
      ["", suffix] ->
        case Integer.parse(suffix) do
          {n, ""} when n > 0 ->
            first = max(size - n, 0)
            {:ok, first, size - 1}

          _ ->
            :unsatisfiable
        end

      [first_str, ""] ->
        case Integer.parse(first_str) do
          {first, ""} when first >= 0 and first < size ->
            {:ok, first, size - 1}

          _ ->
            :unsatisfiable
        end

      [first_str, last_str] ->
        with {first, ""} <- Integer.parse(first_str),
             {last, ""} <- Integer.parse(last_str),
             true <- first >= 0,
             true <- first < size,
             true <- first <= last do
          {:ok, first, min(last, size - 1)}
        else
          _ -> :unsatisfiable
        end

      _ ->
        :unsatisfiable
    end
  end

  defp parse_byte_spec(_, _), do: :unsatisfiable
end
