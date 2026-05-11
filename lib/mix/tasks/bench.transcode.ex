defmodule Mix.Tasks.Bench.Transcode do
  @moduledoc """
  Transcode benchmark (PLAN §12.3, originally Phase 0.5; Phase 1 expects
  a re-bench against a real talking-head clip — see "Capturing a real
  clip" below).

  Synthesises a short 720p VP9 sample (or accepts one via `--input`),
  transcodes it to H.264/AAC with libx264 `-preset veryfast`, and reports
  the realtime ratio. The result is what we plug into the finalizer
  cores-per-thousand-answers math.

  Usage:

      mix bench.transcode                         # synth 60s 720p VP9, transcode
      mix bench.transcode --duration 30
      mix bench.transcode --input /path/to/sample.webm
      mix bench.transcode --preset ultrafast
      mix bench.transcode --runs 3                # average across runs

  This is **not** a microbenchmark. The number you want is "how many cores
  would I need to keep up with N answers/hour at this preset" — that's
  `1 / realtime_ratio` cores per active answer.

  ## Capturing a real clip from the spike app (Phase 1)

  Phase 0 used `testsrc=` (synthetic test pattern), which is *much*
  easier to encode than real talking-head footage. PLAN §12.3 budgets
  ~1–2× realtime per modern core for real content; the synthetic ratio
  was ~16× and **must not** be used for sizing.

  To grab a real clip:

  1. `mix phx.server` (with `mix run priv/repo/seeds.exs` once first to
     populate the dev tenant/template).
  2. Visit `http://localhost:4000/capture/new` → it creates a session and
     redirects to `/capture/<session_id>`.
  3. Click "Open camera", "Start recording", record ~5 minutes of
     talking-head, "Stop & finalize". The recorder writes bytes via tus
     PATCH into `priv/uploads/response/<response_id>/<capture_id>.body`.
  4. Find the writer file (look at the LiveView's "Response id" + the
     captureInstanceId UUID) — that's the raw VP9/Opus WebM clip.
  5. `mix bench.transcode --input priv/uploads/response/.../capture-id.body`.

  Re-run on `shared-cpu-2x` and `dedicated-cpu-2x` Fly machines once we
  deploy; record the realtime ratios in PLAN §12.3 / §12.7 sizing notes.
  """
  use Mix.Task

  @shortdoc "Bench VP9→H.264 transcode realtime ratio"

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        switches: [
          input: :string,
          duration: :integer,
          preset: :string,
          height: :integer,
          runs: :integer,
          keep: :boolean
        ]
      )

    duration = opts[:duration] || 60
    preset = opts[:preset] || "veryfast"
    height = opts[:height] || 720
    runs = opts[:runs] || 1

    ensure_ffmpeg!()

    {input_path, generated?} =
      case opts[:input] do
        nil -> {synthesize_sample(duration, height), true}
        p -> {p, false}
      end

    info = ffprobe(input_path)
    Mix.shell().info("\nInput: #{input_path}")
    Mix.shell().info("  duration   #{format_seconds(info.duration)}")
    Mix.shell().info("  resolution #{info.width}x#{info.height}")
    Mix.shell().info("  codec      #{info.codec}")
    Mix.shell().info("  bitrate    #{format_bitrate(info.bitrate)}\n")

    results =
      for run <- 1..runs do
        out_path =
          Path.join(
            System.tmp_dir!(),
            "bench_out_#{run}_#{System.unique_integer([:positive])}.mp4"
          )

        Mix.shell().info("Run #{run}/#{runs} — preset=#{preset} → #{out_path}")
        result = transcode(input_path, out_path, preset)
        Mix.shell().info(format_result(result, info.duration))
        if !opts[:keep], do: File.rm(out_path)
        result
      end

    if runs > 1, do: print_summary(results, info.duration)

    if generated? and !opts[:keep], do: File.rm(input_path)
    :ok
  end

  defp ensure_ffmpeg! do
    case System.find_executable("ffmpeg") do
      nil ->
        Mix.raise(
          "ffmpeg not found in PATH; install via `brew install ffmpeg` or your package manager"
        )

      _ ->
        :ok
    end
  end

  defp synthesize_sample(duration, height) do
    width = round(height * 16 / 9)
    out = Path.join(System.tmp_dir!(), "bench_in_#{System.unique_integer([:positive])}.webm")

    args = [
      "-y",
      "-loglevel",
      "error",
      # Synthetic test pattern + tone — close enough to "talking head" pixel
      # complexity for an order-of-magnitude bench. Phase 1 should re-bench
      # with a real interview-style clip.
      "-f",
      "lavfi",
      "-i",
      "testsrc=duration=#{duration}:size=#{width}x#{height}:rate=30",
      "-f",
      "lavfi",
      "-i",
      "sine=frequency=440:duration=#{duration}",
      "-c:v",
      "libvpx-vp9",
      "-b:v",
      "1M",
      "-deadline",
      "realtime",
      "-cpu-used",
      "5",
      "-c:a",
      "libopus",
      "-b:a",
      "64k",
      out
    ]

    Mix.shell().info("Synthesising #{duration}s VP9 sample (#{width}x#{height}) → #{out}")

    case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
      {_, 0} -> out
      {output, code} -> Mix.raise("synth failed (#{code}):\n#{output}")
    end
  end

  defp transcode(input, output, preset) do
    args = [
      "-y",
      "-loglevel",
      "error",
      "-i",
      input,
      "-c:v",
      "libx264",
      "-preset",
      preset,
      "-crf",
      "23",
      "-c:a",
      "aac",
      "-b:a",
      "128k",
      "-movflags",
      "+faststart",
      output
    ]

    {wall_us, {_, code}} =
      :timer.tc(fn ->
        System.cmd("ffmpeg", args, stderr_to_stdout: true)
      end)

    if code != 0, do: Mix.raise("transcode failed (exit #{code})")
    %{wall_seconds: wall_us / 1_000_000, output: output, output_bytes: File.stat!(output).size}
  end

  defp format_result(%{wall_seconds: w, output_bytes: b}, source_seconds) do
    ratio = source_seconds / w

    """
      wall time     #{Float.round(w, 2)} s
      realtime ratio #{Float.round(ratio, 2)}× (#{ratio_label(ratio)})
      output size   #{format_bytes(b)}
      cores per 1k answers/hr (steady state) ≈ #{cores_per_1k(ratio, source_seconds)}
    """
  end

  defp ratio_label(r) when r >= 1, do: "#{Float.round(r, 1)}× faster than realtime"
  defp ratio_label(r), do: "#{Float.round(1 / r, 2)}× slower than realtime — bottleneck"

  # Cores ≈ (answers/sec) × (transcode_seconds / answer)
  # answers/hr = 1000 → answers/sec = 1000/3600
  # transcode_seconds/answer = source_seconds / ratio
  defp cores_per_1k(ratio, source_seconds) do
    needed = 1000 / 3600 * (source_seconds / ratio)
    Float.round(needed, 2)
  end

  defp print_summary(results, source_seconds) do
    walls = Enum.map(results, & &1.wall_seconds)
    avg = Enum.sum(walls) / length(walls)
    min_w = Enum.min(walls)
    max_w = Enum.max(walls)
    avg_ratio = source_seconds / avg

    Mix.shell().info("""

    Summary across #{length(results)} runs:
      avg wall   #{Float.round(avg, 2)} s
      min/max    #{Float.round(min_w, 2)} / #{Float.round(max_w, 2)} s
      avg ratio  #{Float.round(avg_ratio, 2)}× realtime
    """)
  end

  defp ffprobe(path) do
    case System.find_executable("ffprobe") do
      nil ->
        Mix.shell().info("ffprobe not found; skipping input metadata\n")
        %{duration: 0.0, width: 0, height: 0, codec: "?", bitrate: 0}

      _ ->
        args = [
          "-v",
          "error",
          "-select_streams",
          "v:0",
          "-show_entries",
          "stream=codec_name,width,height,bit_rate:format=duration",
          "-of",
          "default=nw=1",
          path
        ]

        case System.cmd("ffprobe", args) do
          {out, 0} ->
            kv = parse_ffprobe(out)

            duration =
              case parse_float(kv["duration"]) do
                d when d > 0.0 -> d
                _ -> probe_duration_fallback(path)
              end

            %{
              duration: duration,
              width: parse_int(kv["width"]),
              height: parse_int(kv["height"]),
              codec: kv["codec_name"] || "?",
              bitrate: parse_int(kv["bit_rate"])
            }

          _ ->
            %{duration: 0.0, width: 0, height: 0, codec: "?", bitrate: 0}
        end
    end
  end

  # MediaRecorder-streamed WebM has no container duration tag; ask ffprobe
  # to walk the stream packets, then fall back to a full ffmpeg decode.
  defp probe_duration_fallback(path) do
    stream_args = [
      "-v",
      "error",
      "-select_streams",
      "v:0",
      "-show_entries",
      "stream=duration",
      "-of",
      "default=nw=1:nk=1",
      path
    ]

    with {out, 0} <- System.cmd("ffprobe", stream_args),
         {f, _} when f > 0.0 <- Float.parse(String.trim(out)) do
      f
    else
      _ -> probe_duration_via_decode(path)
    end
  end

  defp probe_duration_via_decode(path) do
    case System.find_executable("ffmpeg") do
      nil ->
        0.0

      _ ->
        args = ["-nostats", "-i", path, "-f", "null", "-"]

        case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
          {out, _} ->
            ~r/time=(\d+):(\d+):(\d+(?:\.\d+)?)/
            |> Regex.scan(out)
            |> List.last()
            |> case do
              [_, h, m, s] ->
                {hi, _} = Integer.parse(h)
                {mi, _} = Integer.parse(m)
                {sf, _} = Float.parse(s)
                hi * 3600 + mi * 60 + sf

              _ ->
                0.0
            end

          _ ->
            0.0
        end
    end
  end

  defp parse_ffprobe(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, "=", parts: 2) do
        [k, v] -> [{k, v}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp parse_float(nil), do: 0.0

  defp parse_float(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp parse_int(nil), do: 0

  defp parse_int(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp format_seconds(s) when s == 0, do: "?"
  defp format_seconds(s), do: "#{Float.round(s, 2)} s"
  defp format_bitrate(0), do: "?"
  defp format_bitrate(b), do: "#{Float.round(b / 1000, 0)} kbps"
  defp format_bytes(b) when b < 1024, do: "#{b} B"
  defp format_bytes(b) when b < 1024 * 1024, do: "#{Float.round(b / 1024, 1)} KB"
  defp format_bytes(b), do: "#{Float.round(b / 1024 / 1024, 2)} MB"
end
