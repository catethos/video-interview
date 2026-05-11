defmodule Interview.Workers.FinalizerTest do
  use Interview.DataCase, async: false

  use Oban.Testing, repo: Interview.Repo

  alias Interview.Capture
  alias Interview.Storage
  alias Interview.Workers.Finalizer

  @moduletag :ffmpeg

  setup do
    if System.find_executable("ffmpeg") == nil do
      {:skip, "ffmpeg not installed"}
    else
      %{session: session, question: question} = Interview.Fixtures.graph!()
      {:ok, response, _} = Capture.claim_instance(session, question, 1, "cap-A")

      # Synthesize a tiny WebM-VP9 file (1 second, 320x240) and store it as
      # the writer's bytes for `(response.id, "cap-A")`. The finalizer should
      # pick it up, transcode to MP4-H264, and roll the row to `:ready`.
      writer_path = Storage.writer_path(response.id, "cap-A")
      File.mkdir_p!(Path.dirname(writer_path))
      synthesize_webm!(writer_path)

      on_exit(fn -> Storage.delete_response(response.id) end)

      {:ok, _} =
        Capture.record_capture_complete(response.id, "cap-A", File.stat!(writer_path).size)

      {:ok, response: response}
    end
  end

  test "transcodes the writer file and marks the row ready", %{response: r} do
    assert :ok = perform_job(Finalizer, %{"response_id" => r.id})

    final = Repo.get!(Interview.Capture.Response, r.id)
    assert final.state == "ready"
    assert final.format == "mp4"
    assert final.storage_key
    assert final.duration_ms

    artifact_path = Storage.artifact_path(final.storage_key)
    assert File.exists?(artifact_path)
  end

  test "discards if the response has no writer file" do
    %{session: session, question: question} = Interview.Fixtures.graph!()
    {:ok, r, _} = Capture.claim_instance(session, question, 1, "cap-Z")
    {:ok, _} = Capture.record_capture_complete(r.id, "cap-Z", 0)

    assert {:discard, _} = perform_job(Finalizer, %{"response_id" => r.id})

    failed = Repo.get!(Interview.Capture.Response, r.id)
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
