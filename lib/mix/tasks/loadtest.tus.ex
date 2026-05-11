defmodule Mix.Tasks.Loadtest.Tus do
  @moduledoc """
  Drives N concurrent synthetic uploaders against the running tus ingest
  endpoint and reports throughput + PATCH latency percentiles.

  This is **not** a microbenchmark — it's a smoke test for the ACK-path
  before we lock in the upload model (PLAN §7 Phase 1, §12.2). It uses
  pre-allocated `question_response` rows and pre-claimed
  `capture_instance_id`s, then drives PATCHes at a steady cadence per
  uploader.

  Usage:

      # Make sure Phoenix is running on http://localhost:4000 in another shell.
      mix loadtest.tus --uploaders 50 --duration 30 --patch-bytes 1048576 \\
                      --interval 8000

  Defaults match PLAN §5.2 capture cadence: ~1 PATCH/uploader/8 s,
  ~1 MB/PATCH, 50 uploaders for 30 s.

  The task creates fixtures, starts uploaders, then prints:

      uploaders: 50 | total PATCHes: ... | bytes: ... MB
      throughput: ... PATCH/s | ... MB/s
      latency p50/p95/p99: ... / ... / ... ms
      errors: { 409: ..., 410: ..., other: ... }

  Pass `--keep` to leave fixtures + storage chunks behind for inspection.
  """
  use Mix.Task

  @shortdoc "Load-test the tus ingest with N synthetic uploaders"

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        switches: [
          uploaders: :integer,
          duration: :integer,
          patch_bytes: :integer,
          interval: :integer,
          base_url: :string,
          keep: :boolean
        ]
      )

    Mix.Task.run("app.start")

    uploaders = opts[:uploaders] || 50
    duration_s = opts[:duration] || 30
    patch_bytes = opts[:patch_bytes] || 1024 * 1024
    interval_ms = opts[:interval] || 8000
    base_url = opts[:base_url] || "http://localhost:4000"

    ensure_server_reachable!(base_url)

    Mix.shell().info("""

    tus load test
      target          #{base_url}
      uploaders       #{uploaders}
      duration        #{duration_s}s
      patch size      #{div(patch_bytes, 1024)} KB
      cadence         #{interval_ms} ms / patch / uploader
    """)

    fixtures = build_fixtures!(uploaders)
    Mix.shell().info("Allocated #{length(fixtures)} response rows")

    payload = :crypto.strong_rand_bytes(patch_bytes)
    deadline_ms = duration_s * 1000

    started_at = System.monotonic_time(:millisecond)

    parent = self()

    pids =
      Enum.map(fixtures, fn fix ->
        spawn_link(fn ->
          loop(parent, fix, base_url, payload, interval_ms, started_at + deadline_ms)
        end)
      end)

    refs = Enum.map(pids, fn pid -> {pid, Process.monitor(pid)} end)

    {results, errors} = collect(length(refs), [], %{}, refs)

    elapsed = (System.monotonic_time(:millisecond) - started_at) / 1000.0
    print_results(results, errors, elapsed, patch_bytes)

    if !opts[:keep], do: cleanup(fixtures)
    :ok
  end

  defp ensure_server_reachable!(base_url) do
    case :httpc.request(
           :get,
           {to_charlist(base_url <> "/uploads/tus"), [{~c"Tus-Resumable", ~c"1.0.0"}]},
           [],
           []
         ) do
      {:ok, _} ->
        :ok

      _ ->
        # OPTIONS check via Erlang's :httpc is awkward; fall back to a TCP probe.
        %URI{host: host, port: port} = URI.parse(base_url)
        port = port || 4000

        case :gen_tcp.connect(to_charlist(host), port, [:binary, active: false], 1000) do
          {:ok, sock} ->
            :gen_tcp.close(sock)
            :ok

          {:error, reason} ->
            Mix.raise("server #{base_url} not reachable: #{inspect(reason)}")
        end
    end
  end

  defp build_fixtures!(n) do
    {:ok, _} = Application.ensure_all_started(:inets)

    alias Interview.Repo
    alias Interview.Tenants.Tenant
    alias Interview.Templates.{Template, Version, Question}
    alias Interview.Capture.Session

    {:ok, tenant} =
      %Tenant{}
      |> Tenant.changeset(%{
        name: "loadtest",
        slug: "loadtest-#{System.unique_integer([:positive])}",
        frame_ancestors: ["'self'"]
      })
      |> Repo.insert()

    {:ok, template} =
      %Template{}
      |> Template.changeset(%{tenant_id: tenant.id, name: "loadtest"})
      |> Repo.insert()

    {:ok, version} =
      %Version{}
      |> Version.changeset(%{template_id: template.id, version_number: 1})
      |> Repo.insert()

    {:ok, question} =
      %Question{}
      |> Question.changeset(%{
        template_version_id: version.id,
        position: 1,
        prompt_text: "loadtest"
      })
      |> Repo.insert()

    for _ <- 1..n do
      {:ok, session} =
        %Session{}
        |> Session.changeset(%{
          tenant_id: tenant.id,
          template_version_id: version.id,
          state: "in_progress"
        })
        |> Repo.insert()

      cid = "load-#{System.unique_integer([:positive])}"
      {:ok, response, _} = Interview.Capture.claim_instance(session, question, 1, cid)
      bearer = Interview.Auth.Tokens.mint_upload_bearer(session.id)

      %{
        session_id: session.id,
        response_id: response.id,
        capture_id: cid,
        offset: 0,
        bearer: bearer
      }
    end
  end

  defp loop(parent, fix, base_url, payload, interval_ms, deadline_ms) do
    state = Map.put(fix, :patches, []) |> Map.put(:errors, %{}) |> Map.put(:offset, 0)
    state = run_patches(state, base_url, payload, interval_ms, deadline_ms)
    send(parent, {:result, %{patches: state.patches, errors: state.errors}})
  end

  defp run_patches(state, base_url, payload, interval_ms, deadline_ms) do
    if System.monotonic_time(:millisecond) >= deadline_ms do
      state
    else
      url = base_url <> "/uploads/tus/#{state.response_id}/#{state.capture_id}"

      headers = [
        {~c"tus-resumable", ~c"1.0.0"},
        {~c"content-type", ~c"application/offset+octet-stream"},
        {~c"upload-offset", to_charlist(Integer.to_string(state.offset))},
        {~c"authorization", to_charlist("Bearer " <> state.bearer)}
      ]

      t0 = System.monotonic_time(:millisecond)

      result =
        :httpc.request(
          :patch,
          {to_charlist(url), headers, ~c"application/offset+octet-stream", payload},
          [{:timeout, 30_000}],
          []
        )

      t1 = System.monotonic_time(:millisecond)
      latency = t1 - t0

      state =
        case result do
          {:ok, {{_, 204, _}, _h, _b}} ->
            patches = [latency | state.patches]
            %{state | patches: patches, offset: state.offset + byte_size(payload)}

          # 409 = our local offset disagrees with storage. Resync via HEAD
          # so subsequent PATCHes continue from the server-authoritative
          # offset instead of cascading 409s (Phase-1 carry).
          {:ok, {{_, 409, _}, _h, _b}} ->
            errors = Map.update(state.errors, 409, 1, &(&1 + 1))
            resync_offset(%{state | errors: errors}, base_url)

          {:ok, {{_, status, _}, _h, _b}} ->
            errors = Map.update(state.errors, status, 1, &(&1 + 1))
            %{state | errors: errors}

          # Transport error: socket closed mid-PATCH, server may or may
          # not have committed bytes. Re-HEAD to read the server's
          # offset before the next PATCH (Phase-1 carry).
          {:error, reason} ->
            errors = Map.update(state.errors, :transport, 1, &(&1 + 1))
            require Logger
            Logger.warning("loadtest transport error: #{inspect(reason)}")
            resync_offset(%{state | errors: errors}, base_url)
        end

      Process.sleep(jittered(interval_ms))
      run_patches(state, base_url, payload, interval_ms, deadline_ms)
    end
  end

  # tus HEAD: read the server-authoritative Upload-Offset and update our
  # local cursor. Failure to resync is counted but doesn't kill the
  # uploader — the next PATCH will try again.
  defp resync_offset(state, base_url) do
    url = base_url <> "/uploads/tus/#{state.response_id}/#{state.capture_id}"

    headers = [
      {~c"tus-resumable", ~c"1.0.0"},
      {~c"authorization", to_charlist("Bearer " <> state.bearer)}
    ]

    case :httpc.request(:head, {to_charlist(url), headers}, [{:timeout, 5_000}], []) do
      {:ok, {{_, 200, _}, resp_headers, _body}} ->
        case header_value(resp_headers, ~c"upload-offset") do
          {:ok, n} -> %{state | offset: n}
          :error -> bump(state, :head_no_offset)
        end

      {:ok, {{_, status, _}, _h, _b}} ->
        bump(state, {:head, status})

      {:error, _reason} ->
        bump(state, :head_transport)
    end
  end

  defp header_value(headers, key) do
    case List.keyfind(headers, key, 0) do
      {_, raw} ->
        case Integer.parse(to_string(raw)) do
          {n, _} -> {:ok, n}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp bump(state, code), do: %{state | errors: Map.update(state.errors, code, 1, &(&1 + 1))}

  defp jittered(base), do: max(0, base + :rand.uniform(div(base, 4)) - div(base, 8))

  defp collect(0, results, errors, _refs), do: {results, errors}

  defp collect(remaining, results, errors, refs) do
    receive do
      {:result, %{patches: patches, errors: e}} ->
        merged_errors =
          Enum.reduce(e, errors, fn {k, v}, acc -> Map.update(acc, k, v, &(&1 + v)) end)

        collect(remaining - 1, patches ++ results, merged_errors, refs)

      {:DOWN, _ref, :process, _pid, :normal} ->
        collect(remaining, results, errors, refs)

      {:DOWN, _ref, :process, _pid, reason} ->
        require Logger
        Logger.warning("loadtest worker died: #{inspect(reason)}")
        collect(remaining - 1, results, errors, refs)
    after
      120_000 ->
        Mix.shell().info("loadtest collect timed out with #{remaining} workers outstanding")
        {results, errors}
    end
  end

  defp print_results(latencies, errors, elapsed_s, patch_bytes) do
    total = length(latencies)
    bytes = total * patch_bytes
    mb_per_s = bytes / 1024 / 1024 / max(elapsed_s, 0.001)

    {p50, p95, p99} = percentiles(latencies)

    Mix.shell().info("""

    Results
      uploaders done       #{(length(latencies) > 0 && "yes") || "no"}
      total PATCHes        #{total}
      bytes                #{Float.round(bytes / 1024 / 1024, 1)} MB
      throughput           #{Float.round(total / max(elapsed_s, 0.001), 2)} PATCH/s, #{Float.round(mb_per_s, 2)} MB/s
      latency p50/p95/p99  #{p50} / #{p95} / #{p99} ms
      errors               #{inspect(errors)}
    """)
  end

  defp percentiles([]), do: {0, 0, 0}

  defp percentiles(latencies) do
    sorted = Enum.sort(latencies)
    n = length(sorted)
    pick = fn p -> Enum.at(sorted, max(0, min(n - 1, round(p * (n - 1))))) end
    {pick.(0.50), pick.(0.95), pick.(0.99)}
  end

  defp cleanup(fixtures) do
    Enum.each(fixtures, fn %{response_id: rid} -> Interview.Storage.delete_response(rid) end)
  end
end
