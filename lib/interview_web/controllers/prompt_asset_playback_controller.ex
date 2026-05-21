defmodule InterviewWeb.PromptAssetPlaybackController do
  @moduledoc """
  Stream a prompt-asset artifact to the candidate page (PLAN §3.4
  recruiter prompts, R5).

  The candidate already has the session_id in their URL; we treat
  knowledge of the session_id (plus its undeleted, non-expired status)
  as the bearer. To prevent cross-session enumeration, the asset must
  be referenced by some question in the session's frozen
  `template_version` — recruiter content unrelated to this session is
  not served.

      GET /capture/:session_id/prompt_assets/:asset_id

  Supports HTTP Range requests so the `<video>` element can seek.
  Responds with `image/png|jpeg|webp|gif|application/pdf` or `video/mp4`
  according to the asset's `mime_type`.
  """
  use InterviewWeb, :controller

  alias Interview.PromptAssets
  alias Interview.Storage
  alias Interview.Templates.PromptAsset

  @default_content_type "application/octet-stream"
  @cache_control "private, max-age=300"

  def show(conn, %{"session_id" => session_id, "asset_id" => asset_id}) do
    with %PromptAsset{storage_key: key, mime_type: mime} = asset when is_binary(key) <-
           PromptAssets.get_for_candidate(session_id, asset_id),
         path = Storage.artifact_path(key),
         {:ok, %{size: size}} <- File.stat(path) do
      send_artifact(conn, path, size, asset, mime)
    else
      _ -> not_found(conn)
    end
  end

  @doc """
  Stream the auto-generated WebVTT caption track for a prompt video.
  Same auth model as `show/2` (knowledge of the session_id is the
  bearer; the asset must be referenced from this session's template
  version). Returns 404 if captions haven't been generated yet — the
  candidate-side `<track>` element handles that gracefully (just
  shows the video without subtitles).

      GET /capture/:session_id/prompt_assets/:asset_id/captions.vtt
  """
  def captions(conn, %{"session_id" => session_id, "asset_id" => asset_id}) do
    with %PromptAsset{caption_storage_key: key} when is_binary(key) <-
           PromptAssets.get_for_candidate(session_id, asset_id),
         path = Storage.artifact_path(key),
         {:ok, %{size: size}} <- File.stat(path) do
      conn
      |> put_resp_content_type("text/vtt")
      |> put_resp_header("cache-control", @cache_control)
      |> put_resp_header("content-length", Integer.to_string(size))
      |> send_file(200, path)
    else
      _ -> not_found(conn)
    end
  end

  defp send_artifact(conn, path, size, _asset, mime) do
    conn =
      conn
      |> put_resp_content_type(mime || @default_content_type)
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
        |> put_resp_header("content-range", "bytes #{first}-#{last}/#{size}")
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
          {n, ""} when n > 0 -> {:ok, max(size - n, 0), size - 1}
          _ -> :unsatisfiable
        end

      [first_str, ""] ->
        case Integer.parse(first_str) do
          {first, ""} when first >= 0 and first < size -> {:ok, first, size - 1}
          _ -> :unsatisfiable
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
