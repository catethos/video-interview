defmodule InterviewWeb.CaptureCompleteController do
  @moduledoc """
  Explicit `capture_complete` endpoint per PLAN §3.3 / §5.1.

  This is the only signal that promotes a `question_response` to
  `capture_complete` and enqueues the finalizer Oban job. Server never
  finalizes on idle inference.

      POST /sessions/:session_id/responses/:response_id/capture_complete
        body: { captureInstanceId: "<uuid>", expectedTotalBytes: 12345 }

  Returns:

    * 200 — finalizer enqueued; response now `capture_complete` (or already past it).
    * 410 — caller's captureInstanceId is no longer the writer.
    * 404 — session/response mismatch.
    * 422 — bad payload.
  """
  use InterviewWeb, :controller

  alias Interview.Auth.Tokens
  alias Interview.Capture
  alias Interview.Capture.Response

  def create(conn, params) do
    with {:ok, sid} <- fetch(params, "session_id"),
         {:ok, rid} <- fetch(params, "response_id"),
         :ok <- assert_upload_bearer(conn, sid),
         {:ok, cid} <- fetch_body(params, "captureInstanceId"),
         {:ok, total} <- fetch_int(params, "expectedTotalBytes"),
         {:ok, response} <- find_response(sid, rid),
         {:ok, response} <- Capture.record_capture_complete(response.id, cid, total),
         {:ok, _job} <- enqueue_finalizer(response) do
      json(conn, %{
        ok: true,
        responseId: response.id,
        state: response.state,
        expectedTotalBytes: response.expected_total_bytes
      })
    else
      {:fenced, current} ->
        conn |> put_status(410) |> json(%{ok: false, error: "fenced", current: current})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{ok: false, error: "not_found"})

      {:error, :unauthorized} ->
        conn |> put_status(401) |> json(%{ok: false, error: "unauthorized"})

      {:error, reason} ->
        conn |> put_status(422) |> json(%{ok: false, error: to_string(reason)})
    end
  end

  defp assert_upload_bearer(conn, session_id) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> raw] ->
        with {:ok, %{sid: sid}} <- Tokens.verify_upload_bearer(String.trim(raw)),
             true <- sid == session_id do
          :ok
        else
          _ -> {:error, :unauthorized}
        end

      _ ->
        {:error, :unauthorized}
    end
  end

  defp fetch(params, key) do
    case Map.get(params, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, "missing_#{key}"}
    end
  end

  defp fetch_body(params, key) do
    case Map.get(params, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, "missing_#{key}"}
    end
  end

  defp fetch_int(params, key) do
    case Map.get(params, key) do
      v when is_integer(v) and v >= 0 ->
        {:ok, v}

      v when is_binary(v) ->
        case Integer.parse(v) do
          {n, ""} when n >= 0 -> {:ok, n}
          _ -> {:error, "bad_#{key}"}
        end

      _ ->
        {:error, "missing_#{key}"}
    end
  end

  defp find_response(session_id, response_id) do
    case Capture.get_response(response_id) do
      %Response{session_id: ^session_id} = r -> {:ok, r}
      _ -> {:error, :not_found}
    end
  end

  defp enqueue_finalizer(%Response{} = response) do
    %{response_id: response.id}
    |> Interview.Workers.Finalizer.new(queue: :finalize)
    |> Oban.insert()
  end
end
