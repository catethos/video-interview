defmodule InterviewWeb.Tus.PromptAssetPlug do
  @moduledoc """
  tus 1.0.0 PATCH/HEAD endpoints for the recruiter prompt-asset pipeline
  (PLAN §3.4 recruiter prompts).

  Mirrors `InterviewWeb.Tus.Plug` (candidate side) but:

    * Scopes to `prompt_assets` rows, not `question_responses`.
    * Authenticates via the recruiter upload bearer
      (`Interview.Auth.Tokens.verify_recruiter_upload_bearer/1`), which
      carries `{rid, tid}`. The plug ensures the addressed asset belongs
      to the tenant in the bearer.

  ## URL scheme

      /uploads/prompt_assets/<asset_id>/<capture_instance_id>

  Encoding the writer token in the URL keeps every PATCH/HEAD implicitly
  attributed to a specific writer; a newer writer claim leaves the URL
  resolvable but the row's `capture_instance_id` no longer matches, and
  we 410 Gone.

  ## Response codes

    * 204 — PATCH success.
    * 200 — HEAD success.
    * 401 — bearer missing/invalid/expired.
    * 403 — bearer's tenant doesn't own the asset.
    * 404 — unknown asset id.
    * 409 — `Upload-Offset` does not match server's view.
    * 410 — fenced.
    * 412 — missing/wrong `Tus-Resumable`.
    * 415 — wrong `Content-Type`.
  """
  import Plug.Conn
  import Ecto.Query, only: [from: 2]

  alias Interview.{PromptAssets, Repo, Storage}
  alias Interview.Auth.Tokens
  alias Interview.Templates.PromptAsset

  @tus_version "1.0.0"
  @body_chunk_bytes 64 * 1024

  def init(opts), do: opts

  def call(conn, _opts) do
    case route(conn) do
      {:options, _aid, _cid} -> handle_options(conn)
      {:head, aid, cid} -> handle_head(conn, aid, cid)
      {:patch, aid, cid} -> handle_patch(conn, aid, cid)
      {:bare_options} -> handle_bare_options(conn)
      :not_tus -> conn |> send_resp(404, "") |> halt()
    end
  end

  defp route(conn) do
    case {conn.method, conn.path_info} do
      {"OPTIONS", []} -> {:bare_options}
      {"OPTIONS", [aid, cid]} -> {:options, aid, cid}
      {"HEAD", [aid, cid]} -> {:head, aid, cid}
      {"GET", [aid, cid]} -> {:head, aid, cid}
      {"PATCH", [aid, cid]} -> {:patch, aid, cid}
      _ -> :not_tus
    end
  end

  # ---- handlers ----------------------------------------------------------

  defp handle_bare_options(conn) do
    conn
    |> put_resp_header("tus-resumable", @tus_version)
    |> put_resp_header("tus-version", @tus_version)
    |> put_resp_header("tus-extension", "")
    |> put_resp_header("tus-max-size", "10737418240")
    |> send_resp(204, "")
    |> halt()
  end

  defp handle_options(conn), do: handle_bare_options(conn)

  defp handle_head(conn, aid, cid) do
    with :ok <- assert_tus_version(conn),
         {:ok, tid} <- assert_recruiter_bearer(conn),
         {:ok, asset} <- find_asset(aid, tid),
         :ok <- assert_writer(asset, cid),
         {:ok, size} <- Storage.prompt_asset_writer_size(aid, cid) do
      conn
      |> put_resp_header("tus-resumable", @tus_version)
      |> put_resp_header("upload-offset", Integer.to_string(size))
      |> maybe_put_upload_length(asset)
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(200, "")
      |> halt()
    else
      {:error, status, reason} -> send_tus_error(conn, status, reason)
    end
  end

  defp handle_patch(conn, aid, cid) do
    with :ok <- assert_tus_version(conn),
         :ok <- assert_patch_content_type(conn),
         {:ok, offset} <- parse_offset(conn),
         {:ok, tid} <- assert_recruiter_bearer(conn),
         {:ok, asset} <- find_asset(aid, tid),
         :ok <- assert_writer(asset, cid),
         {:ok, conn, new_size} <- stream_body_to_storage(conn, aid, cid, offset),
         {:ok, asset} <- maybe_apply_upload_length(conn, asset),
         {:ok, _asset} <- commit_offset(asset, cid, new_size) do
      conn
      |> put_resp_header("tus-resumable", @tus_version)
      |> put_resp_header("upload-offset", Integer.to_string(new_size))
      |> send_resp(204, "")
      |> halt()
    else
      {:error, status, reason} -> send_tus_error(conn, status, reason)
    end
  end

  # ---- pipeline helpers --------------------------------------------------

  defp assert_tus_version(conn) do
    case get_req_header(conn, "tus-resumable") do
      [@tus_version] -> :ok
      _ -> {:error, 412, "tus-resumable header missing or wrong"}
    end
  end

  defp assert_patch_content_type(conn) do
    case get_req_header(conn, "content-type") do
      ["application/offset+octet-stream" <> _] -> :ok
      _ -> {:error, 415, "content-type must be application/offset+octet-stream"}
    end
  end

  defp parse_offset(conn) do
    case get_req_header(conn, "upload-offset") do
      [v] ->
        case Integer.parse(v) do
          {n, ""} when n >= 0 -> {:ok, n}
          _ -> {:error, 400, "bad upload-offset"}
        end

      _ ->
        {:error, 400, "missing upload-offset"}
    end
  end

  defp assert_recruiter_bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> raw] ->
        case Tokens.verify_recruiter_upload_bearer(String.trim(raw)) do
          {:ok, %{tid: tid}} -> {:ok, tid}
          {:error, :expired} -> {:error, 401, "upload bearer expired"}
          _ -> {:error, 401, "upload bearer invalid"}
        end

      _ ->
        {:error, 401, "missing upload bearer"}
    end
  end

  defp find_asset(aid, tid) do
    case PromptAssets.get(tid, aid) do
      nil -> {:error, 404, "asset not found"}
      asset -> {:ok, asset}
    end
  end

  defp assert_writer(%PromptAsset{capture_instance_id: same}, same), do: :ok

  defp assert_writer(%PromptAsset{capture_instance_id: current}, _other) do
    {:error, 410, "fenced; current=#{current}"}
  end

  defp stream_body_to_storage(conn, aid, cid, offset) do
    case Storage.prompt_asset_writer_size(aid, cid) do
      {:ok, ^offset} ->
        do_stream(conn, aid, cid)

      {:ok, current} ->
        if offset < current do
          {:ok, conn} = drain_body(conn)
          {:ok, conn, current}
        else
          {:error, 409, "upload-offset (#{offset}) ahead of stored size (#{current})"}
        end

      {:error, reason} ->
        {:error, 500, "storage error: #{inspect(reason)}"}
    end
  end

  defp do_stream(conn, aid, cid) do
    path = Storage.prompt_asset_writer_path(aid, cid)
    File.mkdir_p!(Path.dirname(path))
    {:ok, fd} = :file.open(path, [:append, :raw, :binary])

    try do
      case consume_into(conn, fd, 0) do
        {:ok, conn, _written} ->
          :ok = :file.sync(fd)
          {:ok, size} = Storage.prompt_asset_writer_size(aid, cid)
          {:ok, conn, size}

        {:error, _, _} = err ->
          err
      end
    after
      :file.close(fd)
    end
  end

  defp consume_into(conn, fd, written) do
    case read_body(conn, length: @body_chunk_bytes, read_length: @body_chunk_bytes) do
      {:ok, "", conn} ->
        {:ok, conn, written}

      {:ok, body, conn} ->
        :ok = :file.write(fd, body)
        {:ok, conn, written + byte_size(body)}

      {:more, body, conn} ->
        :ok = :file.write(fd, body)
        consume_into(conn, fd, written + byte_size(body))

      {:error, reason} ->
        {:error, 500, "body read failed: #{inspect(reason)}"}
    end
  end

  defp drain_body(conn) do
    case read_body(conn, length: @body_chunk_bytes, read_length: @body_chunk_bytes) do
      {:ok, _, conn} -> {:ok, conn}
      {:more, _, conn} -> drain_body(conn)
      {:error, _} = err -> err
    end
  end

  defp commit_offset(%PromptAsset{} = asset, cid, new_size) do
    case PromptAssets.commit_offset(asset.id, cid, new_size) do
      {:ok, updated} -> {:ok, updated}
      {:fenced, current} -> {:error, 410, "fenced during commit; current=#{current}"}
      {:error, reason} -> {:error, 500, "commit failed: #{inspect(reason)}"}
    end
  end

  defp maybe_apply_upload_length(conn, %PromptAsset{} = asset) do
    case get_req_header(conn, "upload-length") do
      [v] ->
        case Integer.parse(v) do
          {n, ""} when n >= 0 ->
            if asset.expected_total_bytes == n do
              {:ok, asset}
            else
              {n_updated, [updated]} =
                from(a in PromptAsset, where: a.id == ^asset.id, select: a)
                |> Repo.update_all(set: [expected_total_bytes: n])

              if n_updated == 1, do: {:ok, updated}, else: {:ok, asset}
            end

          _ ->
            {:error, 400, "bad upload-length"}
        end

      [] ->
        {:ok, asset}

      _ ->
        {:error, 400, "duplicate upload-length"}
    end
  end

  defp maybe_put_upload_length(conn, %PromptAsset{expected_total_bytes: nil}), do: conn

  defp maybe_put_upload_length(conn, %PromptAsset{expected_total_bytes: n}) do
    put_resp_header(conn, "upload-length", Integer.to_string(n))
  end

  defp send_tus_error(conn, status, reason) do
    conn
    |> put_resp_header("tus-resumable", @tus_version)
    |> put_resp_content_type("text/plain")
    |> send_resp(status, reason)
    |> halt()
  end
end
