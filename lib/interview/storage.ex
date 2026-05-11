defmodule Interview.Storage do
  @moduledoc """
  Pluggable backend for tus-style append-only writes and finalised
  artifacts.

  Phase 1 ships `Interview.Storage.Local` (filesystem under `priv/uploads`).
  The same contract drops onto Tigris/S3 via a future `S3` adapter.

  Layout assumed across all adapters:

      writer object: response/<response_id>/<capture_instance_id>.body
      artifact:      artifact/<storage_key>

  ### PLAN §5.1 invariant

  Bytes are durably committed in storage *before* Postgres commits the
  offset. `put_at_offset/4` only returns `{:ok, new_size}` after the
  underlying object has been fsynced (local) or PutObject-acked (S3).
  The tus PATCH handler then opens a small DB transaction to commit
  `bytes_uploaded` — the storage write must precede that.
  """

  @type response_id :: binary()
  @type capture_instance_id :: binary()
  @type artifact_key :: binary()
  @type prompt_asset_id :: binary()

  @doc """
  Append bytes at `offset`. Returns `{:ok, new_size}` if `offset` matched
  the current writer size and the bytes are durable.

  `{:error, {:offset_mismatch, current}}` if the caller's offset is wrong;
  this is the canonical tus-409 path (mismatch → caller resyncs via HEAD).
  """
  @callback put_at_offset(response_id, capture_instance_id, non_neg_integer(), iodata()) ::
              {:ok, non_neg_integer()}
              | {:error, {:offset_mismatch, non_neg_integer()} | term()}

  @callback writer_size(response_id, capture_instance_id) ::
              {:ok, non_neg_integer()} | {:error, term()}

  @callback writer_path(response_id, capture_instance_id) :: Path.t() | binary()

  @callback put_artifact(artifact_key, Path.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  @callback artifact_path(artifact_key) :: Path.t() | binary()
  @callback delete_response(response_id) :: :ok
  @callback delete_artifact(artifact_key) :: :ok

  # Prompt-asset writer object (PLAN §3.4 recruiter prompts). Mirrors the
  # response API but namespaced separately so the candidate and recruiter
  # pipelines can never write to each other's writer files.
  @callback prompt_asset_put_at_offset(
              prompt_asset_id,
              capture_instance_id,
              non_neg_integer(),
              iodata()
            ) ::
              {:ok, non_neg_integer()}
              | {:error, {:offset_mismatch, non_neg_integer()} | term()}

  @callback prompt_asset_writer_size(prompt_asset_id, capture_instance_id) ::
              {:ok, non_neg_integer()} | {:error, term()}

  @callback prompt_asset_writer_path(prompt_asset_id, capture_instance_id) ::
              Path.t() | binary()

  @callback delete_prompt_asset(prompt_asset_id) :: :ok

  # ---- public API ---------------------------------------------------------

  def put_at_offset(rid, cid, offset, body),
    do: adapter().put_at_offset(rid, cid, offset, body)

  def writer_size(rid, cid), do: adapter().writer_size(rid, cid)
  def writer_path(rid, cid), do: adapter().writer_path(rid, cid)
  def put_artifact(key, src), do: adapter().put_artifact(key, src)
  def artifact_path(key), do: adapter().artifact_path(key)
  def delete_response(rid), do: adapter().delete_response(rid)
  def delete_artifact(key), do: adapter().delete_artifact(key)

  def prompt_asset_put_at_offset(aid, cid, offset, body),
    do: adapter().prompt_asset_put_at_offset(aid, cid, offset, body)

  def prompt_asset_writer_size(aid, cid), do: adapter().prompt_asset_writer_size(aid, cid)
  def prompt_asset_writer_path(aid, cid), do: adapter().prompt_asset_writer_path(aid, cid)
  def delete_prompt_asset(aid), do: adapter().delete_prompt_asset(aid)

  def adapter do
    Application.get_env(:interview, __MODULE__, [])
    |> Keyword.get(:adapter, Interview.Storage.Local)
  end
end
