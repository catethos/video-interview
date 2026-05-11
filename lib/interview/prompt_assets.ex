defmodule Interview.PromptAssets do
  @moduledoc """
  Workflow operations for recruiter-authored prompt assets (PLAN §3.4
  recruiter prompts).

  Mirrors the candidate capture pipeline (`Interview.Capture`): the same
  state machine, the same fencing semantics, but tenant-scoped and
  detached from any session.

  State machine (`Interview.Templates.PromptAsset`):

      pending → recording → capture_complete → uploading →
        upload_complete → finalizing → ready | failed | abandoned

  Image/PDF attachments bypass the recording pipeline and land directly
  in `ready` via `create_attachment/2`.
  """
  import Ecto.Query, warn: false

  alias Interview.Repo
  alias Interview.Templates.PromptAsset

  @type tenant_id :: binary()
  @type asset_id :: binary()
  @type capture_instance_id :: binary()

  # ---- Reads -------------------------------------------------------------

  def list(tenant_id, opts \\ []) do
    state = Keyword.get(opts, :state)
    kind = Keyword.get(opts, :kind)

    base =
      from(a in PromptAsset,
        where: a.tenant_id == ^tenant_id,
        order_by: [desc: a.inserted_at]
      )

    base
    |> maybe_filter(:state, state)
    |> maybe_filter(:kind, kind)
    |> Repo.all()
  end

  defp maybe_filter(query, _field, nil), do: query

  defp maybe_filter(query, field, value) do
    from(a in query, where: field(a, ^field) == ^value)
  end

  @doc """
  Fetch an asset scoped to the tenant. Returns `nil` if the id is unknown
  or belongs to a different tenant.
  """
  def get(tenant_id, asset_id) when is_binary(tenant_id) and is_binary(asset_id) do
    Repo.one(
      from(a in PromptAsset,
        where: a.id == ^asset_id and a.tenant_id == ^tenant_id
      )
    )
  end

  def get!(tenant_id, asset_id) do
    case get(tenant_id, asset_id) do
      nil -> raise Ecto.NoResultsError, queryable: PromptAsset
      asset -> asset
    end
  end

  @doc """
  Resolve a prompt asset for candidate playback. Returns the asset only
  if (a) it is `ready` with a storage_key, AND (b) it is referenced as
  the `prompt_asset_id` or `attachment_asset_id` of some question in the
  given session's frozen template_version.

  The session id is the bearer — the candidate has it (it's in the URL
  they're viewing); recruiter content tied to that session's template
  version is fair game to stream back to them.
  """
  def get_for_candidate(session_id, asset_id)
      when is_binary(session_id) and is_binary(asset_id) do
    Repo.one(
      from a in PromptAsset,
        join: s in Interview.Capture.Session,
        on: s.id == ^session_id,
        join: q in Interview.Templates.Question,
        on:
          q.template_version_id == s.template_version_id and
            (q.prompt_asset_id == a.id or q.attachment_asset_id == a.id),
        where:
          a.id == ^asset_id and
            a.state == "ready" and
            not is_nil(a.storage_key) and
            is_nil(s.deleted_at),
        distinct: true,
        select: a
    )
  end

  # ---- Create ------------------------------------------------------------

  @doc """
  Create a fresh recording asset for a tenant. Returns
  `{:ok, asset, capture_instance_id}` — the row is stamped `recording`
  with a freshly-minted `capture_instance_id` so the recruiter recorder
  hook can begin uploading immediately.

  `attrs` must include `:kind` (`"video"` or `"audio"`). Optional:
  `:recorder_mime_type`, `:created_by_user_id`.
  """
  def create_recording(tenant_id, attrs) when is_binary(tenant_id) and is_map(attrs) do
    capture_id = generate_capture_instance_id()
    now = DateTime.utc_now()

    base =
      attrs
      |> Map.put(:tenant_id, tenant_id)
      |> Map.put(:state, "recording")
      |> Map.put(:capture_instance_id, capture_id)
      |> Map.put(:capture_started_at, now)
      |> Map.put_new(:kind, "video")

    case %PromptAsset{} |> PromptAsset.changeset(base) |> Repo.insert() do
      {:ok, asset} -> {:ok, asset, capture_id}
      {:error, cs} -> {:error, cs}
    end
  end

  @doc """
  Create a finalised attachment asset (image/PDF). Skips the recording
  pipeline — the row is inserted directly as `ready` with `storage_key`
  already pointing at the uploaded blob.

  `attrs` must include `:kind` (`"image"` or `"pdf"`), `:storage_key`,
  `:mime_type`, `:bytes`. Optional: `:created_by_user_id`.
  """
  def create_attachment(tenant_id, attrs) when is_binary(tenant_id) and is_map(attrs) do
    now = DateTime.utc_now()

    base =
      attrs
      |> Map.put(:tenant_id, tenant_id)
      |> Map.put(:state, "ready")
      |> Map.put(:finalized_at, now)
      |> Map.put(:upload_completed_at, now)

    %PromptAsset{}
    |> PromptAsset.changeset(base)
    |> Repo.insert()
  end

  # ---- Recording lifecycle ----------------------------------------------

  @doc """
  (Re-)arm an asset as the active recording writer. Returns
  `{:ok, asset, capture_instance_id}` with a freshly-minted writer
  token — any prior writer is fenced on its next PATCH.

  Refuses to claim already-finalized rows (`ready`/`finalizing`/etc.) —
  those would need a brand-new asset.
  """
  def claim(%PromptAsset{state: state} = asset, _opts)
      when state in ["pending", "recording", "failed", "abandoned"] do
    capture_id = generate_capture_instance_id()
    now = DateTime.utc_now()

    {1, [updated]} =
      from(a in PromptAsset, where: a.id == ^asset.id, select: a)
      |> Repo.update_all(
        set: [
          state: "recording",
          capture_instance_id: capture_id,
          capture_started_at: now,
          bytes_uploaded: 0,
          last_error_code: nil,
          last_error_message: nil
        ]
      )

    {:ok, updated, capture_id}
  end

  def claim(%PromptAsset{}, _opts), do: {:error, :wrong_state}

  @doc """
  Commit a successful tus offset write. Mirrors `Capture.commit_offset/3`:
  bytes have already been durably committed to storage; we just bump
  `bytes_uploaded` if the caller is still the live writer.
  """
  def commit_offset(asset_id, capture_id, new_offset)
      when is_integer(new_offset) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      asset =
        from(a in PromptAsset,
          where: a.id == ^asset_id,
          lock: "FOR UPDATE"
        )
        |> Repo.one()

      cond do
        is_nil(asset) ->
          Repo.rollback(:not_found)

        asset.capture_instance_id != capture_id ->
          {:fenced, asset.capture_instance_id}

        new_offset < asset.bytes_uploaded ->
          {:ok, asset}

        true ->
          {1, [updated]} =
            from(a in PromptAsset, where: a.id == ^asset.id, select: a)
            |> Repo.update_all(
              set: [
                bytes_uploaded: new_offset,
                state:
                  if(asset.state in ["pending", "recording"],
                    do: "recording",
                    else: asset.state
                  ),
                updated_at: now
              ]
            )

          {:ok, updated}
      end
    end)
    |> case do
      {:ok, {:ok, asset}} -> {:ok, asset}
      {:ok, {:fenced, current}} -> {:fenced, current}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Promote an asset to `capture_complete` and stamp `expected_total_bytes`.
  Only signal that enqueues finalization (mirrors PLAN §5.1).
  """
  def record_capture_complete(asset_id, capture_id, expected_total_bytes)
      when is_integer(expected_total_bytes) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      asset =
        from(a in PromptAsset,
          where: a.id == ^asset_id,
          lock: "FOR UPDATE"
        )
        |> Repo.one()

      cond do
        is_nil(asset) ->
          Repo.rollback(:not_found)

        asset.capture_instance_id != capture_id ->
          {:fenced, asset.capture_instance_id}

        asset.state in [
          "capture_complete",
          "uploading",
          "upload_complete",
          "finalizing",
          "ready"
        ] ->
          {:ok, asset}

        true ->
          {1, [updated]} =
            from(a in PromptAsset, where: a.id == ^asset.id, select: a)
            |> Repo.update_all(
              set: [
                state: "capture_complete",
                expected_total_bytes: expected_total_bytes,
                capture_completed_at: now
              ]
            )

          {:ok, updated}
      end
    end)
    |> case do
      {:ok, {:ok, asset}} ->
        :telemetry.execute(
          [:interview, :prompt_asset, :captured],
          %{bytes: expected_total_bytes},
          %{prompt_asset_id: asset.id, tenant_id: asset.tenant_id}
        )

        {:ok, asset}

      {:ok, {:fenced, current}} ->
        {:fenced, current}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Move an asset `capture_complete` → `finalizing`. Called by the
  finalizer worker before it runs ffmpeg.
  """
  def mark_finalizing(asset_id) do
    {n, rows} =
      from(a in PromptAsset,
        where: a.id == ^asset_id and a.state == "capture_complete",
        select: a
      )
      |> Repo.update_all(set: [state: "finalizing"])

    case {n, rows} do
      {1, [updated]} -> {:ok, updated}
      {0, _} -> {:error, :wrong_state}
    end
  end

  @doc """
  Mark an asset `ready` after a successful finalize. Stamps the canonical
  `storage_key`, duration, mime_type, and bytes from the published
  artifact.
  """
  def mark_ready(asset_id, attrs) when is_map(attrs) do
    now = DateTime.utc_now()

    set =
      attrs
      |> Map.take([:storage_key, :mime_type, :duration_ms, :bytes])
      |> Map.put(:state, "ready")
      |> Map.put(:finalized_at, now)
      |> Map.put(:upload_completed_at, now)
      |> Enum.to_list()

    {1, [updated]} =
      from(a in PromptAsset, where: a.id == ^asset_id, select: a)
      |> Repo.update_all(set: set)

    :telemetry.execute(
      [:interview, :prompt_asset, :ready],
      %{duration_ms: updated.duration_ms || 0, bytes: updated.bytes || 0},
      %{prompt_asset_id: updated.id, tenant_id: updated.tenant_id}
    )

    {:ok, updated}
  end

  @doc """
  Mark an asset `failed` (terminal).
  """
  def mark_failed(asset_id, code, message) do
    {1, [updated]} =
      from(a in PromptAsset, where: a.id == ^asset_id, select: a)
      |> Repo.update_all(
        set: [
          state: "failed",
          last_error_code: to_string(code),
          last_error_message: to_string(message)
        ]
      )

    :telemetry.execute(
      [:interview, :prompt_asset, :failed],
      %{},
      %{
        prompt_asset_id: updated.id,
        tenant_id: updated.tenant_id,
        code: to_string(code)
      }
    )

    {:ok, updated}
  end

  @doc """
  Mark assets `abandoned` (terminal). Used by the sweeper to clean up
  rows stuck in non-terminal states past the stale cutoff.
  """
  def mark_abandoned(ids) when is_list(ids) do
    {n, _} =
      from(a in PromptAsset, where: a.id in ^ids)
      |> Repo.update_all(set: [state: "abandoned"])

    {:ok, n}
  end

  @doc """
  Find prompt_assets whose `inserted_at` is older than `cutoff` and that
  are still in a non-terminal state. Returns a list of asset ids.
  """
  def stale_in_flight(cutoff) when is_struct(cutoff, DateTime) do
    from(a in PromptAsset,
      where: a.state not in ["ready", "failed", "abandoned"],
      where: a.inserted_at < ^cutoff,
      select: a.id
    )
    |> Repo.all()
  end

  @doc """
  Delete an asset row. Storage cleanup is the caller's responsibility.
  Returns `{:ok, asset}` or `{:error, :not_found}`.
  """
  def delete(tenant_id, asset_id) do
    case get(tenant_id, asset_id) do
      nil -> {:error, :not_found}
      asset -> Repo.delete(asset)
    end
  end

  # ---- Helpers -----------------------------------------------------------

  defp generate_capture_instance_id do
    "pa-" <> (:crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false))
  end
end
