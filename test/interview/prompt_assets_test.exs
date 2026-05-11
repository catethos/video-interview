defmodule Interview.PromptAssetsTest do
  use Interview.DataCase, async: true

  alias Interview.PromptAssets
  alias Interview.Templates.PromptAsset
  alias Interview.Repo

  setup do
    tenant = Interview.Fixtures.tenant!()
    {:ok, tenant: tenant}
  end

  describe "create_recording/2" do
    test "stamps state=recording and returns capture_instance_id", %{tenant: t} do
      assert {:ok, %PromptAsset{} = asset, capture_id} =
               PromptAssets.create_recording(t.id, %{
                 kind: "video",
                 recorder_mime_type: "video/webm;codecs=vp9"
               })

      assert asset.state == "recording"
      assert asset.tenant_id == t.id
      assert asset.kind == "video"
      assert asset.capture_instance_id == capture_id
      assert is_binary(capture_id)
      assert asset.capture_started_at
    end

    test "defaults kind to video when omitted", %{tenant: t} do
      assert {:ok, asset, _cid} = PromptAssets.create_recording(t.id, %{})
      assert asset.kind == "video"
    end

    test "rejects invalid kind", %{tenant: t} do
      assert {:error, cs} = PromptAssets.create_recording(t.id, %{kind: "movie"})
      assert "is invalid" in errors_on(cs).kind
    end
  end

  describe "create_attachment/2" do
    test "inserts a ready row with a storage_key", %{tenant: t} do
      assert {:ok, %PromptAsset{} = asset} =
               PromptAssets.create_attachment(t.id, %{
                 kind: "image",
                 mime_type: "image/png",
                 storage_key: "tenants/#{t.id}/prompt_assets/a.png",
                 bytes: 4096
               })

      assert asset.state == "ready"
      assert asset.kind == "image"
      assert asset.storage_key
      assert asset.finalized_at
    end

    test "rejects ready row without storage_key", %{tenant: t} do
      assert {:error, cs} =
               PromptAssets.create_attachment(t.id, %{
                 kind: "image",
                 mime_type: "image/png"
               })

      assert "is required when state is ready" in errors_on(cs).storage_key
    end
  end

  describe "claim/2" do
    test "always issues a new capture_instance_id (fencing the prior writer)",
         %{tenant: t} do
      {:ok, asset, original_cid} = PromptAssets.create_recording(t.id, %{kind: "video"})
      assert {:ok, %PromptAsset{} = updated, new_cid} = PromptAssets.claim(asset, [])
      assert new_cid != original_cid
      assert updated.capture_instance_id == new_cid
      assert updated.state == "recording"
    end

    test "re-arms a failed asset with a fresh capture_instance_id", %{tenant: t} do
      {:ok, asset, _cid} = PromptAssets.create_recording(t.id, %{kind: "video"})
      {:ok, _} = PromptAssets.mark_failed(asset.id, "ffmpeg_failed", "x")
      asset = Repo.get!(PromptAsset, asset.id)

      assert {:ok, %PromptAsset{} = updated, new_cid} = PromptAssets.claim(asset, [])
      assert updated.state == "recording"
      assert updated.capture_instance_id == new_cid
      assert new_cid != asset.capture_instance_id
      assert updated.bytes_uploaded == 0
      assert is_nil(updated.last_error_code)
    end

    test "refuses to claim a ready asset", %{tenant: t} do
      asset = Interview.Fixtures.prompt_asset!(t.id, %{state: "ready"})
      assert {:error, :wrong_state} = PromptAssets.claim(asset, [])
    end
  end

  describe "commit_offset/3" do
    test "advances bytes_uploaded when writer is current", %{tenant: t} do
      {:ok, asset, cid} = PromptAssets.create_recording(t.id, %{kind: "video"})
      assert {:ok, updated} = PromptAssets.commit_offset(asset.id, cid, 4096)
      assert updated.bytes_uploaded == 4096
      assert updated.state == "recording"
    end

    test "fences a stale writer", %{tenant: t} do
      {:ok, asset, _cid} = PromptAssets.create_recording(t.id, %{kind: "video"})
      {:ok, _, new_cid} = PromptAssets.claim(asset, [])
      assert {:fenced, ^new_cid} = PromptAssets.commit_offset(asset.id, "stale-cid", 4096)
    end

    test "does not move offset backwards on replay", %{tenant: t} do
      {:ok, asset, cid} = PromptAssets.create_recording(t.id, %{kind: "video"})
      {:ok, _} = PromptAssets.commit_offset(asset.id, cid, 5000)
      assert {:ok, again} = PromptAssets.commit_offset(asset.id, cid, 1000)
      assert again.bytes_uploaded == 5000
    end
  end

  describe "record_capture_complete/3" do
    test "transitions to capture_complete with expected_total_bytes", %{tenant: t} do
      {:ok, asset, cid} = PromptAssets.create_recording(t.id, %{kind: "video"})
      assert {:ok, updated} = PromptAssets.record_capture_complete(asset.id, cid, 8192)
      assert updated.state == "capture_complete"
      assert updated.expected_total_bytes == 8192
      assert updated.capture_completed_at
    end

    test "fences a stale writer", %{tenant: t} do
      {:ok, asset, _cid} = PromptAssets.create_recording(t.id, %{kind: "video"})
      {:ok, _, new_cid} = PromptAssets.claim(asset, [])
      assert {:fenced, ^new_cid} = PromptAssets.record_capture_complete(asset.id, "stale", 1)
    end

    test "is idempotent once capture_complete", %{tenant: t} do
      {:ok, asset, cid} = PromptAssets.create_recording(t.id, %{kind: "video"})
      {:ok, _} = PromptAssets.record_capture_complete(asset.id, cid, 8192)
      assert {:ok, again} = PromptAssets.record_capture_complete(asset.id, cid, 9999)
      assert again.state == "capture_complete"
      assert again.expected_total_bytes == 8192
    end
  end

  describe "mark_finalizing/1 + mark_ready/2 + mark_failed/3" do
    test "happy-path finalize", %{tenant: t} do
      {:ok, asset, cid} = PromptAssets.create_recording(t.id, %{kind: "video"})
      {:ok, _} = PromptAssets.record_capture_complete(asset.id, cid, 8192)

      assert {:ok, fin} = PromptAssets.mark_finalizing(asset.id)
      assert fin.state == "finalizing"

      assert {:ok, ready} =
               PromptAssets.mark_ready(asset.id, %{
                 storage_key: "tenants/#{t.id}/prompt_assets/#{asset.id}.mp4",
                 mime_type: "video/mp4",
                 duration_ms: 3_000,
                 bytes: 8_192
               })

      assert ready.state == "ready"
      assert ready.storage_key
      assert ready.finalized_at
    end

    test "mark_finalizing/1 refuses wrong state", %{tenant: t} do
      {:ok, asset, _cid} = PromptAssets.create_recording(t.id, %{kind: "video"})
      assert {:error, :wrong_state} = PromptAssets.mark_finalizing(asset.id)
    end

    test "mark_failed/3 stamps terminal state and error", %{tenant: t} do
      {:ok, asset, _cid} = PromptAssets.create_recording(t.id, %{kind: "video"})
      assert {:ok, updated} = PromptAssets.mark_failed(asset.id, :ffmpeg_failed, "oops")
      assert updated.state == "failed"
      assert updated.last_error_code == "ffmpeg_failed"
      assert updated.last_error_message == "oops"
    end
  end

  describe "stale_in_flight/1 + mark_abandoned/1" do
    test "returns non-terminal assets older than cutoff", %{tenant: t} do
      {:ok, fresh, _} = PromptAssets.create_recording(t.id, %{kind: "video"})
      {:ok, stale, _} = PromptAssets.create_recording(t.id, %{kind: "video"})

      # Backdate the stale asset
      ago = NaiveDateTime.utc_now() |> NaiveDateTime.add(-3_600, :second)
      Repo.update_all(
        from(a in PromptAsset, where: a.id == ^stale.id),
        set: [inserted_at: ago]
      )

      ready = Interview.Fixtures.prompt_asset!(t.id, %{state: "ready"})

      Repo.update_all(
        from(a in PromptAsset, where: a.id == ^ready.id),
        set: [inserted_at: ago]
      )

      cutoff = DateTime.add(DateTime.utc_now(), -1_800, :second)
      ids = PromptAssets.stale_in_flight(cutoff)

      assert stale.id in ids
      refute fresh.id in ids
      refute ready.id in ids
    end

    test "mark_abandoned/1 promotes rows to abandoned", %{tenant: t} do
      {:ok, a, _} = PromptAssets.create_recording(t.id, %{kind: "video"})
      assert {:ok, 1} = PromptAssets.mark_abandoned([a.id])
      assert Repo.get!(PromptAsset, a.id).state == "abandoned"
    end
  end

  describe "get/2" do
    test "is tenant-scoped", %{tenant: t} do
      other = Interview.Fixtures.tenant!()
      mine = Interview.Fixtures.prompt_asset!(t.id)
      theirs = Interview.Fixtures.prompt_asset!(other.id)

      assert %PromptAsset{id: id} = PromptAssets.get(t.id, mine.id)
      assert id == mine.id
      assert is_nil(PromptAssets.get(t.id, theirs.id))
    end
  end
end
