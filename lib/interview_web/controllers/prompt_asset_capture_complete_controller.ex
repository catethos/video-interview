defmodule InterviewWeb.PromptAssetCaptureCompleteController do
  @moduledoc """
  Explicit `capture_complete` endpoint for recruiter prompt-asset
  recordings (PLAN §3.4 recruiter prompts, §5.1 invariant).

      POST /api/prompt_assets/:id/capture_complete
        body: { captureInstanceId: "<uuid>", expectedTotalBytes: 12345 }

  This is the only signal that moves a `prompt_asset` to
  `capture_complete` and enqueues the prompt-asset finalizer. Server
  never finalizes on idle inference.

  Returns:

    * 200 — finalizer enqueued; asset now `capture_complete` (or past it).
    * 410 — caller's captureInstanceId is no longer the writer.
    * 404 — unknown asset id or wrong tenant.
    * 401 — bearer missing/invalid.
    * 422 — bad payload.
  """
  use InterviewWeb, :controller

  alias Interview.Auth.Tokens
  alias Interview.PromptAssets
  alias Interview.Templates.PromptAsset

  def create(conn, params) do
    with {:ok, aid} <- fetch(params, "id"),
         {:ok, tid} <- assert_recruiter_bearer(conn),
         {:ok, cid} <- fetch_body(params, "captureInstanceId"),
         {:ok, total} <- fetch_int(params, "expectedTotalBytes"),
         {:ok, asset} <- find_asset(tid, aid),
         {:ok, asset} <- PromptAssets.record_capture_complete(asset.id, cid, total),
         {:ok, _job} <- enqueue_finalizer(asset) do
      json(conn, %{
        ok: true,
        promptAssetId: asset.id,
        state: asset.state,
        expectedTotalBytes: asset.expected_total_bytes
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

  defp assert_recruiter_bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> raw] ->
        case Tokens.verify_recruiter_upload_bearer(String.trim(raw)) do
          {:ok, %{tid: tid}} -> {:ok, tid}
          _ -> {:error, :unauthorized}
        end

      _ ->
        {:error, :unauthorized}
    end
  end

  defp find_asset(tid, aid) do
    case PromptAssets.get(tid, aid) do
      %PromptAsset{} = asset -> {:ok, asset}
      nil -> {:error, :not_found}
    end
  end

  defp fetch(params, key) do
    case Map.get(params, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, "missing_#{key}"}
    end
  end

  defp fetch_body(params, key), do: fetch(params, key)

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

  defp enqueue_finalizer(%PromptAsset{} = asset) do
    %{prompt_asset_id: asset.id}
    |> Interview.Workers.PromptAssetFinalizer.new(queue: :finalize)
    |> Oban.insert()
  end
end
