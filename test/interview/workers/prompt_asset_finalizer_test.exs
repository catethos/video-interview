defmodule Interview.Workers.PromptAssetFinalizerTest do
  use Interview.DataCase, async: false

  use Oban.Testing, repo: Interview.Repo

  alias Interview.PromptAssets
  alias Interview.Storage
  alias Interview.Templates.PromptAsset
  alias Interview.Workers.PromptAssetFinalizer

  @moduletag :ffmpeg

  setup do
    if System.find_executable("ffmpeg") == nil do
      {:skip, "ffmpeg not installed"}
    else
      tenant = Interview.Fixtures.tenant!()
      {:ok, asset, cid} = PromptAssets.create_recording(tenant.id, %{kind: "video"})

      writer_path = Storage.prompt_asset_writer_path(asset.id, cid)
      File.mkdir_p!(Path.dirname(writer_path))
      synthesize_webm!(writer_path)

      on_exit(fn -> Storage.delete_prompt_asset(asset.id) end)

      {:ok, _} =
        PromptAssets.record_capture_complete(asset.id, cid, File.stat!(writer_path).size)

      {:ok, asset: asset, cid: cid, tenant: tenant}
    end
  end

  test "transcodes the writer file and marks the asset ready",
       %{asset: a, tenant: t} do
    assert :ok = perform_job(PromptAssetFinalizer, %{"prompt_asset_id" => a.id})

    final = Repo.get!(PromptAsset, a.id)
    assert final.state == "ready"
    assert final.storage_key == "tenants/#{t.id}/prompt_assets/#{a.id}.mp4"
    assert final.mime_type == "video/mp4"
    assert final.duration_ms
    assert final.bytes > 0
    assert File.exists?(Storage.artifact_path(final.storage_key))
  end

  test "discards when the writer file is missing" do
    tenant = Interview.Fixtures.tenant!()
    {:ok, asset, cid} = PromptAssets.create_recording(tenant.id, %{kind: "video"})
    {:ok, _} = PromptAssets.record_capture_complete(asset.id, cid, 0)

    assert {:discard, _} = perform_job(PromptAssetFinalizer, %{"prompt_asset_id" => asset.id})

    failed = Repo.get!(PromptAsset, asset.id)
    assert failed.state == "failed"
    assert failed.last_error_code == "no_bytes"
  end

  defp synthesize_webm!(path) do
    args = [
      "-y",
      "-f",
      "lavfi",
      "-i",
      "testsrc=duration=1:size=320x240:rate=15",
      "-f",
      "lavfi",
      "-i",
      "anullsrc=r=44100:cl=stereo",
      "-shortest",
      "-c:v",
      "libvpx-vp9",
      "-deadline",
      "realtime",
      "-cpu-used",
      "8",
      "-b:v",
      "200k",
      "-c:a",
      "libopus",
      "-b:a",
      "32k",
      "-f",
      "webm",
      path
    ]

    {_out, 0} = System.cmd("ffmpeg", args, stderr_to_stdout: true)
  end
end
