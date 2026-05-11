defmodule Interview.Storage.Local do
  @moduledoc """
  Filesystem-backed adapter for `Interview.Storage`.

  Layout under `:root` (config):

      response/<response_id>/<capture_instance_id>.body
      artifact/<storage_key>

  Each writer (one per `capture_instance_id`) gets its own append-only
  file. tus offset is the file size; PATCH appends bytes if the supplied
  offset matches. Each PATCH `:file.sync/1`s before the call returns.
  """
  @behaviour Interview.Storage

  @impl true
  def put_at_offset(rid, cid, offset, body)
      when is_binary(rid) and is_binary(cid) and is_integer(offset) and offset >= 0 do
    put_at_path(writer_path(rid, cid), offset, body)
  end

  defp put_at_path(path, offset, body)
       when is_integer(offset) and offset >= 0 do
    File.mkdir_p!(Path.dirname(path))
    current = current_size(path)

    cond do
      offset == current ->
        do_append(path, body)

      offset < current and offset + IO.iodata_length(body) <= current ->
        {:ok, current}

      true ->
        {:error, {:offset_mismatch, current}}
    end
  end

  @impl true
  def writer_size(rid, cid) when is_binary(rid) and is_binary(cid) do
    {:ok, current_size(writer_path(rid, cid))}
  end

  @impl true
  def writer_path(rid, cid) when is_binary(rid) and is_binary(cid) do
    Path.join([root(), "response", rid, cid <> ".body"])
  end

  @impl true
  def put_artifact(key, src) when is_binary(key) and is_binary(src) do
    dest = artifact_path(key)
    File.mkdir_p!(Path.dirname(dest))
    File.cp!(src, dest)
    fsync(dest)
    %{size: bytes} = File.stat!(dest)
    {:ok, bytes}
  end

  @impl true
  def artifact_path(key) when is_binary(key) do
    Path.join([root(), "artifact", key])
  end

  @impl true
  def delete_response(rid) when is_binary(rid) do
    case File.rm_rf(Path.join([root(), "response", rid])) do
      {:ok, _} -> :ok
      {:error, _, _} -> :ok
    end
  end

  @impl true
  def delete_artifact(key) when is_binary(key) do
    case File.rm(artifact_path(key)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _} -> :ok
    end
  end

  # ---- prompt asset writers ----------------------------------------------

  @impl true
  def prompt_asset_put_at_offset(aid, cid, offset, body)
      when is_binary(aid) and is_binary(cid) and is_integer(offset) and offset >= 0 do
    put_at_path(prompt_asset_writer_path(aid, cid), offset, body)
  end

  @impl true
  def prompt_asset_writer_size(aid, cid) when is_binary(aid) and is_binary(cid) do
    {:ok, current_size(prompt_asset_writer_path(aid, cid))}
  end

  @impl true
  def prompt_asset_writer_path(aid, cid) when is_binary(aid) and is_binary(cid) do
    Path.join([root(), "prompt_asset", aid, cid <> ".body"])
  end

  @impl true
  def delete_prompt_asset(aid) when is_binary(aid) do
    case File.rm_rf(Path.join([root(), "prompt_asset", aid])) do
      {:ok, _} -> :ok
      {:error, _, _} -> :ok
    end
  end

  # ---- helpers ------------------------------------------------------------

  defp current_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      {:error, :enoent} -> 0
    end
  end

  defp do_append(path, body) do
    case :file.open(path, [:append, :raw, :binary]) do
      {:ok, fd} ->
        try do
          :ok = :file.write(fd, body)
          :ok = :file.sync(fd)
          {:ok, current_size(path)}
        after
          :file.close(fd)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fsync(path) do
    case :file.open(path, [:read, :raw, :binary]) do
      {:ok, fd} ->
        _ = :file.sync(fd)
        :file.close(fd)

      _ ->
        :ok
    end
  end

  defp root do
    cfg = Application.get_env(:interview, Interview.Storage, [])
    Keyword.fetch!(cfg, :root) |> Path.expand()
  end
end
