defmodule Interview.Workers.WhisperTranscriptTest do
  use Interview.DataCase, async: false
  use Oban.Testing, repo: Interview.Repo

  alias Interview.Capture
  alias Interview.Capture.Response
  alias Interview.Repo
  alias Interview.Storage
  alias Interview.Workers.WhisperTranscript

  setup do
    tenant = Interview.Fixtures.tenant!()
    version = Interview.Fixtures.version!(Interview.Fixtures.template!(tenant.id).id)
    q = Interview.Fixtures.question!(version.id, 1, %{required: true})
    session = Interview.Fixtures.session!(tenant.id, version.id, %{state: "in_progress"})
    {:ok, response, _} = Capture.claim_instance(session, q, 1, "cap-A")
    {:ok, _} = Capture.record_capture_complete(response.id, "cap-A", 100)
    %{response: response}
  end

  defp put_artifact!(storage_key) do
    src =
      Path.join(System.tmp_dir!(), "interview_test_audio_#{System.unique_integer([:positive])}.mp4")

    File.write!(src, "fake mp4 bytes")
    {:ok, _} = Storage.put_artifact(storage_key, src)
    File.rm(src)
  end

  defp mark_ready!(response) do
    storage_key = "tests/#{response.id}.mp4"
    put_artifact!(storage_key)

    {:ok, _} =
      Capture.mark_ready(response.id, %{
        storage_key: storage_key,
        duration_ms: 1234,
        format: "mp4"
      })
  end

  test "mark_ready enqueues a Whisper job when transcripts are enabled", %{response: response} do
    mark_ready!(response)

    assert_enqueued(worker: WhisperTranscript, args: %{"response_id" => response.id})
  end

  test "performs the job: calls the adapter, sets transcript on the row", %{response: response} do
    Interview.TranscriptsStub.program([
      {:ok, %{text: "hello world", provider: "stub-v1"}}
    ])

    mark_ready!(response)

    assert :ok = perform_job(WhisperTranscript, %{"response_id" => response.id})

    [{:transcribe_call, %{audio_path: path}}] = Interview.TranscriptsStub.calls()
    assert is_binary(path)

    r = Repo.get!(Response, response.id)
    assert r.transcript_text == "hello world"
    assert r.transcript_provider == "stub-v1"
    assert %DateTime{} = r.transcript_ready_at
  end

  test "is idempotent — second perform is a no-op", %{response: response} do
    Interview.TranscriptsStub.program([
      {:ok, %{text: "first", provider: "stub-v1"}}
    ])

    mark_ready!(response)
    assert :ok = perform_job(WhisperTranscript, %{"response_id" => response.id})

    # Second run finds transcript_ready_at non-nil and bails before calling the adapter.
    assert :ok = perform_job(WhisperTranscript, %{"response_id" => response.id})

    [_one_call] = Interview.TranscriptsStub.calls()

    r = Repo.get!(Response, response.id)
    assert r.transcript_text == "first"
  end

  test "discards when API key is missing (permafail)", %{response: response} do
    Interview.TranscriptsStub.program([{:error, :missing_api_key}])

    mark_ready!(response)

    assert {:discard, _} = perform_job(WhisperTranscript, %{"response_id" => response.id})

    r = Repo.get!(Response, response.id)
    assert is_nil(r.transcript_ready_at)
  end

  test "discards when OpenAI returns 401", %{response: response} do
    Interview.TranscriptsStub.program([{:error, :unauthorized}])

    mark_ready!(response)

    assert {:discard, _} = perform_job(WhisperTranscript, %{"response_id" => response.id})
  end

  test "retries on rate-limit", %{response: response} do
    Interview.TranscriptsStub.program([{:error, :rate_limited}])

    mark_ready!(response)

    assert {:error, :rate_limited} = perform_job(WhisperTranscript, %{"response_id" => response.id})

    r = Repo.get!(Response, response.id)
    assert is_nil(r.transcript_ready_at)
  end

  test "retries on transport error", %{response: response} do
    Interview.TranscriptsStub.program([{:error, {:transport, :timeout}}])

    mark_ready!(response)

    assert {:error, _} = perform_job(WhisperTranscript, %{"response_id" => response.id})
  end

  test "discards when artifact file is missing", %{response: response} do
    {:ok, _} =
      Capture.mark_ready(response.id, %{
        storage_key: "tests/never-written.mp4",
        duration_ms: 1,
        format: "mp4"
      })

    assert {:discard, _} = perform_job(WhisperTranscript, %{"response_id" => response.id})
  end

  test "skips enqueue when transcripts disabled", %{response: response} do
    prev = Application.get_env(:interview, Interview.Transcripts, [])
    Application.put_env(:interview, Interview.Transcripts, Keyword.put(prev, :enabled, false))
    on_exit(fn -> Application.put_env(:interview, Interview.Transcripts, prev) end)

    mark_ready!(response)

    refute_enqueued(worker: WhisperTranscript, args: %{"response_id" => response.id})
  end
end
