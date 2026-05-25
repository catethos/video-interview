defmodule Interview.Workers.PromptAssetCaptionTest do
  use Interview.DataCase, async: false

  use Oban.Testing, repo: Interview.Repo

  alias Interview.PromptAssets
  alias Interview.Storage
  alias Interview.Templates.PromptAsset
  alias Interview.TranscriptsStub
  alias Interview.Workers.PromptAssetCaption

  setup do
    # Process-local stub avoids the real OpenAI call.
    TranscriptsStub.clear()

    tenant = Interview.Fixtures.tenant!()
    {:ok, asset, _cid} = PromptAssets.create_recording(tenant.id, %{kind: "video"})

    # Forge a ready state with a real artifact file so the worker has
    # something to "transcribe". The MP4 contents are bogus but the
    # stubbed transcripts adapter never reads the bytes.
    storage_key = "tenants/#{tenant.id}/prompt_assets/#{asset.id}.mp4"
    artifact_path = Storage.artifact_path(storage_key)
    File.mkdir_p!(Path.dirname(artifact_path))
    File.write!(artifact_path, "stub bytes")

    {:ok, ready_asset} =
      PromptAssets.mark_ready(asset.id, %{
        storage_key: storage_key,
        mime_type: "video/mp4",
        duration_ms: 5_000,
        bytes: 10
      })

    on_exit(fn -> Storage.delete_prompt_asset(asset.id) end)

    {:ok, asset: ready_asset, tenant: tenant, storage_key: storage_key}
  end

  test "stamps caption fields after a successful transcribe_vtt", %{asset: a} do
    TranscriptsStub.program([
      {:ok, %{vtt: "WEBVTT\n\n00:00:00.000 --> 00:00:01.500\nHello\n", provider: "stub"}}
    ])

    assert :ok = perform_job(PromptAssetCaption, %{"prompt_asset_id" => a.id})

    final = Repo.get!(PromptAsset, a.id)
    assert final.caption_storage_key == "tenants/#{a.tenant_id}/prompt_assets/#{a.id}.vtt"
    assert final.caption_provider == "stub"
    assert %DateTime{} = final.caption_ready_at
    # The VTT file is on disk under the canonical caption key.
    assert File.exists?(Storage.artifact_path(final.caption_storage_key))
  end

  test "is idempotent — a second perform is a no-op", %{asset: a} do
    TranscriptsStub.program([
      {:ok, %{vtt: "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nHi\n", provider: "stub"}}
    ])

    assert :ok = perform_job(PromptAssetCaption, %{"prompt_asset_id" => a.id})
    first_ready_at = Repo.get!(PromptAsset, a.id).caption_ready_at

    # Second perform with no programmed response would default to the
    # stub's default VTT — but we expect the worker to short-circuit
    # before the adapter is called, so caption_ready_at must not advance.
    assert :ok = perform_job(PromptAssetCaption, %{"prompt_asset_id" => a.id})

    assert Repo.get!(PromptAsset, a.id).caption_ready_at == first_ready_at
  end

  test "discards image/pdf assets (no audio to caption)" do
    tenant = Interview.Fixtures.tenant!()

    {:ok, asset} =
      PromptAssets.create_attachment(tenant.id, %{
        kind: "image",
        mime_type: "image/png",
        storage_key: "tenants/#{tenant.id}/prompt_assets/test.png",
        bytes: 100
      })

    on_exit(fn -> Storage.delete_prompt_asset(asset.id) end)

    assert {:discard, _} = perform_job(PromptAssetCaption, %{"prompt_asset_id" => asset.id})
    refute Repo.get!(PromptAsset, asset.id).caption_ready_at
  end

  test "discards when asset state isn't ready", %{tenant: tenant} do
    {:ok, asset, _cid} = PromptAssets.create_recording(tenant.id, %{kind: "video"})

    on_exit(fn -> Storage.delete_prompt_asset(asset.id) end)

    assert {:discard, _} = perform_job(PromptAssetCaption, %{"prompt_asset_id" => asset.id})
    refute Repo.get!(PromptAsset, asset.id).caption_ready_at
  end

  test "permafails on missing OpenAI key", %{asset: a} do
    TranscriptsStub.program([{:error, :missing_api_key}])

    assert {:discard, _} = perform_job(PromptAssetCaption, %{"prompt_asset_id" => a.id})
    refute Repo.get!(PromptAsset, a.id).caption_ready_at
  end

  test "retries on rate-limit", %{asset: a} do
    TranscriptsStub.program([{:error, :rate_limited}])

    assert {:error, :rate_limited} =
             perform_job(PromptAssetCaption, %{"prompt_asset_id" => a.id})
  end
end
