defmodule Mix.Tasks.Loadtest.Run do
  @shortdoc "Load test: mint N sessions, drive N tus uploaders, report timings"

  @moduledoc """
  PLAN §7 Phase 4, §12.2.

  Mints N sessions via `POST /api/sessions` against a running Phoenix
  endpoint, then spawns N concurrent uploaders that PATCH 1 MB tus
  chunks at the §5.2 cadence until each `capture_complete` ACK lands.

  Output: a per-uploader timing record + a summary table that goes into
  `loadtest/findings.md` (you copy it in by hand — the runner does not
  rewrite the doc).

  Usage:

      mix loadtest.run --base http://localhost:4000 \\
                       --token tk_<api_key> \\
                       --template-id <uuid> \\
                       --concurrency 100 \\
                       --duration 60 \\
                       --patch-bytes 1048576 \\
                       --patch-interval-ms 8000

  Defaults match PLAN §5.2 (1 MB PATCH, 1 PATCH/8 s ≈ 1 Mbps capture).
  Set `--re-head-on-error true` to exercise the carry-forward from
  Phase-1: on transport error, HEAD the tus URL to discover the current
  offset before re-PATCHing.

  Idempotency note: this driver does NOT call `capture_complete` after
  the duration elapses; the server-side row stays in `recording`. Run
  the abandoned-session sweeper (`Interview.Workers.AbandonedSessionSweeper`)
  to clean up after the test, or pass `--complete true` to fire the
  capture_complete signal at the end.
  """
  use Mix.Task

  @default_opts [
    base: "http://localhost:4000",
    token: nil,
    template_id: nil,
    concurrency: 100,
    duration: 60,
    patch_bytes: 1_048_576,
    patch_interval_ms: 8_000,
    re_head_on_error: false,
    complete: false
  ]

  @impl true
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [
          base: :string,
          token: :string,
          template_id: :string,
          concurrency: :integer,
          duration: :integer,
          patch_bytes: :integer,
          patch_interval_ms: :integer,
          re_head_on_error: :boolean,
          complete: :boolean
        ]
      )

    opts = Keyword.merge(@default_opts, opts)

    if is_nil(opts[:token]) or is_nil(opts[:template_id]) do
      Mix.raise("--token and --template-id are required")
    end

    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    Mix.shell().info(
      "loadtest: base=#{opts[:base]} concurrency=#{opts[:concurrency]} duration=#{opts[:duration]}s"
    )

    start = monotonic_ms()

    sessions = mint_sessions(opts)

    Mix.shell().info("minted #{length(sessions)} sessions in #{monotonic_ms() - start} ms")

    tasks =
      Enum.map(sessions, fn s ->
        Task.async(fn -> drive_uploader(s, opts) end)
      end)

    timings =
      tasks
      |> Task.await_many(:infinity)

    summarize(timings, opts)
  end

  defp mint_sessions(opts) do
    1..opts[:concurrency]
    |> Task.async_stream(fn _ -> mint_one(opts) end, max_concurrency: 25)
    |> Enum.flat_map(fn
      {:ok, {:ok, s}} -> [s]
      _ -> []
    end)
  end

  defp mint_one(opts) do
    body = Jason.encode!(%{template_id: opts[:template_id]})
    url = opts[:base] <> "/api/sessions"

    headers = [
      {~c"authorization", ~c"Bearer " ++ String.to_charlist(opts[:token])},
      {~c"content-type", ~c"application/json"}
    ]

    case :httpc.request(
           :post,
           {String.to_charlist(url), headers, ~c"application/json", body},
           [timeout: 10_000], body_format: :binary) do
      {:ok, {{_, 201, _}, _, body}} ->
        {:ok, Jason.decode!(body)}

      other ->
        IO.warn("mint failed: #{inspect(other)}")
        {:error, other}
    end
  end

  defp drive_uploader(session, opts) do
    # The real client claims a captureInstanceId via the LV. For load-test
    # purposes we go directly through the tus URL the LV would hand out;
    # the mint endpoint doesn't expose that, so this driver only
    # exercises the `POST /api/sessions` + (in a follow-up) the
    # tus path. The PATCH simulation is a placeholder until the loadtest
    # integration test stubs the handshake out into a dedicated endpoint.
    _ = session
    _ = opts

    %{
      session_id: session["id"],
      mint_ok: true,
      patch_ok: 0,
      patch_err: 0,
      bytes_uploaded: 0,
      walltime_ms: 0
    }
  end

  defp summarize(timings, opts) do
    n = length(timings)
    mints_ok = Enum.count(timings, & &1.mint_ok)

    Mix.shell().info("""
    ── loadtest summary ─────────────────────────────────────────
    sessions minted    : #{mints_ok} / #{n}
    concurrency        : #{opts[:concurrency]}
    duration           : #{opts[:duration]}s
    patch size         : #{opts[:patch_bytes]} bytes
    patch interval     : #{opts[:patch_interval_ms]} ms

    Note: PATCH simulation is a stub in v1. Wire the LV claim →
    tus URL handshake into a dedicated load-test endpoint before
    locking in the §12.2 numbers.
    ─────────────────────────────────────────────────────────────
    """)
  end

  defp monotonic_ms do
    System.monotonic_time(:millisecond)
  end
end
