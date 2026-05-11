defmodule InterviewWeb.Tus.Plug do
  @moduledoc """
  tus 1.0.0 PATCH/HEAD endpoints for the candidate recorder pipeline.

  ## URL scheme

      /uploads/tus/<response_id>/<capture_instance_id>

  `response_id` is a `question_responses` UUID; `capture_instance_id` is
  the writer's fencing token (PLAN §5.1). Encoding it in the URL means
  every PATCH/HEAD is implicitly attributed to a specific writer; if a
  newer writer has claimed the row, the URL the old writer is hitting
  still resolves but the row's `capture_instance_id` no longer matches,
  and we 410 Gone.

  ## Creation

  v1 does not implement the tus `creation` extension here. Resources are
  pre-created via `Interview.Capture.claim_instance/4` (the LiveView
  surface). Future work: bolt POST creation onto this same plug for
  compatibility with stock `tus-js-client`.

  ## Headers we honour

  Required:

    * `Tus-Resumable: 1.0.0`
    * `Upload-Offset: <N>` on PATCH

  Optional:

    * `Upload-Length: <N>` on PATCH (final-byte declaration); we treat
      this as authoritative for `expected_total_bytes` if present.
    * `Content-Type: application/offset+octet-stream` on PATCH (required
      by spec; we 415 otherwise).

  ## Response codes

    * 204 — PATCH success, with `Upload-Offset: <new>`.
    * 200 — HEAD success, with `Upload-Offset` + `Upload-Length` (if known).
    * 404 — unknown response_id.
    * 410 — fenced (capture_instance_id is no longer the writer).
    * 409 — `Upload-Offset` does not match server's view of the offset.
    * 412 — missing/wrong `Tus-Resumable`.
    * 415 — wrong `Content-Type`.

  ## PLAN §5.1 invariant

  Order of operations on PATCH:
    1. Validate fence (DB read).
    2. Validate Upload-Offset against storage writer size.
    3. Stream body to storage; fsync.
    4. `Capture.commit_offset/3` — DB transaction commits new offset.
    5. Reply.

  Storage is written *before* the DB commit. If the DB commit fails
  (fence raced, etc.), the bytes are orphaned in storage but no
  inconsistency: the row's `bytes_uploaded` reflects what is actually
  durable for the *current* writer, not us.
  """
  import Plug.Conn
  import Ecto.Query, only: [from: 2]

  alias Interview.{Capture, Repo, Storage}
  alias Interview.Auth.Tokens
  alias Interview.Capture.Response

  @tus_version "1.0.0"
  @body_chunk_bytes 64 * 1024

  def init(opts), do: opts

  def call(conn, _opts) do
    case route(conn) do
      {:options, _rid, _cid} -> handle_options(conn)
      {:head, rid, cid} -> handle_head(conn, rid, cid)
      {:patch, rid, cid} -> handle_patch(conn, rid, cid)
      {:bare_options} -> handle_bare_options(conn)
      :not_tus -> conn |> send_resp(404, "") |> halt()
    end
  end

  defp route(conn) do
    # `forward` strips the mount prefix, so `path_info` here is what's
    # left under `/uploads/tus`. `Plug.Head` (mounted on the endpoint)
    # rewrites HEAD → GET before we run, so we accept either.
    case {conn.method, conn.path_info} do
      {"OPTIONS", []} -> {:bare_options}
      {"OPTIONS", [rid, cid]} -> {:options, rid, cid}
      {"HEAD", [rid, cid]} -> {:head, rid, cid}
      {"GET", [rid, cid]} -> {:head, rid, cid}
      {"PATCH", [rid, cid]} -> {:patch, rid, cid}
      _ -> :not_tus
    end
  end

  # ---- handlers -----------------------------------------------------------

  defp handle_bare_options(conn) do
    conn
    |> put_resp_header("tus-resumable", @tus_version)
    |> put_resp_header("tus-version", @tus_version)
    |> put_resp_header("tus-extension", "")
    |> put_resp_header("tus-max-size", "10737418240")
    |> send_resp(204, "")
    |> halt()
  end

  defp handle_options(conn) do
    handle_bare_options(conn)
  end

  defp handle_head(conn, rid, cid) do
    with :ok <- assert_tus_version(conn),
         {:ok, response} <- find_response(rid),
         :ok <- assert_upload_bearer(conn, response),
         :ok <- assert_writer(response, cid),
         {:ok, size} <- Storage.writer_size(rid, cid) do
      conn
      |> put_resp_header("tus-resumable", @tus_version)
      |> put_resp_header("upload-offset", Integer.to_string(size))
      |> maybe_put_upload_length(response)
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(200, "")
      |> halt()
    else
      {:error, status, reason} ->
        send_tus_error(conn, status, reason)
    end
  end

  defp handle_patch(conn, rid, cid) do
    with :ok <- assert_tus_version(conn),
         :ok <- assert_patch_content_type(conn),
         {:ok, offset} <- parse_offset(conn),
         {:ok, response} <- find_response(rid),
         :ok <- assert_upload_bearer(conn, response),
         :ok <- assert_writer(response, cid),
         {:ok, conn, new_size} <- stream_body_to_storage(conn, rid, cid, offset),
         {:ok, response} <- maybe_apply_upload_length(conn, response),
         {:ok, response} <- commit_offset(response, cid, new_size) do
      Capture.touch_session_seen(%Interview.Capture.Session{id: response.session_id})

      conn
      |> put_resp_header("tus-resumable", @tus_version)
      |> put_resp_header("upload-offset", Integer.to_string(new_size))
      |> send_resp(204, "")
      |> halt()
    else
      {:error, status, reason} -> send_tus_error(conn, status, reason)
    end
  end

  # ---- pipeline helpers ---------------------------------------------------

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

  defp find_response(rid) do
    case Capture.get_response(rid) do
      nil -> {:error, 404, "response not found"}
      %Response{} = r -> {:ok, r}
    end
  end

  defp assert_writer(%Response{capture_instance_id: same}, same), do: :ok

  defp assert_writer(%Response{capture_instance_id: current}, _other) do
    {:error, 410, "fenced; current=#{current}"}
  end

  defp assert_upload_bearer(conn, %Response{session_id: session_id}) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> raw] ->
        with {:ok, %{sid: sid}} <- Tokens.verify_upload_bearer(String.trim(raw)),
             true <- sid == session_id do
          :ok
        else
          {:error, :expired} -> {:error, 401, "upload bearer expired"}
          _ -> {:error, 401, "upload bearer invalid"}
        end

      _ ->
        {:error, 401, "missing upload bearer"}
    end
  end

  defp stream_body_to_storage(conn, rid, cid, offset) do
    case Storage.writer_size(rid, cid) do
      {:ok, ^offset} ->
        do_stream(conn, rid, cid)

      {:ok, current} ->
        if offset < current do
          # Re-uploading bytes already on disk. Drain the body so the
          # connection is clean, but write nothing. The new authoritative
          # size remains `current`.
          {:ok, conn} = drain_body(conn)
          {:ok, conn, current}
        else
          {:error, 409, "upload-offset (#{offset}) ahead of stored size (#{current})"}
        end

      {:error, reason} ->
        {:error, 500, "storage error: #{inspect(reason)}"}
    end
  end

  defp do_stream(conn, rid, cid) do
    path = Storage.writer_path(rid, cid)
    File.mkdir_p!(Path.dirname(path))
    {:ok, fd} = :file.open(path, [:append, :raw, :binary])

    try do
      case consume_into(conn, fd, 0) do
        {:ok, conn, written} ->
          :ok = :file.sync(fd)
          {:ok, size} = Storage.writer_size(rid, cid)
          # Defensive: writer_size should equal pre + written. Trust storage.
          _ = written
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

  defp commit_offset(%Response{} = response, cid, new_size) do
    case Capture.commit_offset(response.id, cid, new_size) do
      {:ok, updated} -> {:ok, updated}
      {:fenced, current} -> {:error, 410, "fenced during commit; current=#{current}"}
      {:error, reason} -> {:error, 500, "commit failed: #{inspect(reason)}"}
    end
  end

  defp maybe_apply_upload_length(conn, %Response{} = response) do
    case get_req_header(conn, "upload-length") do
      [v] ->
        case Integer.parse(v) do
          {n, ""} when n >= 0 ->
            if response.expected_total_bytes == n do
              {:ok, response}
            else
              {n_updated, [updated]} =
                from(r in Response, where: r.id == ^response.id, select: r)
                |> Repo.update_all(set: [expected_total_bytes: n])

              if n_updated == 1, do: {:ok, updated}, else: {:ok, response}
            end

          _ ->
            {:error, 400, "bad upload-length"}
        end

      [] ->
        {:ok, response}

      _ ->
        {:error, 400, "duplicate upload-length"}
    end
  end

  defp maybe_put_upload_length(conn, %Response{expected_total_bytes: nil}), do: conn

  defp maybe_put_upload_length(conn, %Response{expected_total_bytes: n}) do
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
