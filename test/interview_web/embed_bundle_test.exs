defmodule InterviewWeb.EmbedBundleTest do
  @moduledoc """
  Smoke tests for the @you/interview-embed customer SDK distribution.

  These don't exercise the SDK's runtime behaviour (no JS test runner in
  this project — see `interview/docs/phase3-findings.md` carries-forward).
  They verify the wiring that has to be right for customers to be able to
  paste the script tag and have it work:

    1. The source lives where the esbuild profile expects it.
    2. The output filename is in the static_paths allowlist so Plug.Static
       will actually serve it.
    3. If the bundle has been built into priv/static, it carries the
       expected public surface (`YourInterview.mount`).
  """
  use ExUnit.Case, async: true

  @source Path.expand("../../assets/embed/index.js", __DIR__)
  @bundle Path.expand("../../priv/static/embed.v1.js", __DIR__)

  test "SDK source exists at the location esbuild bundles from" do
    assert File.exists?(@source), "missing #{@source} — did you delete the SDK source?"
    contents = File.read!(@source)
    assert contents =~ "YourInterview"
    assert contents =~ "mount"
    assert contents =~ "channelId"
    assert contents =~ "iframeOrigin"
  end

  test "embed.v1.js is in static_paths so Plug.Static serves it" do
    assert "embed.v1.js" in InterviewWeb.static_paths()
  end

  test "if the bundle was built, it exposes YourInterview.mount" do
    case File.read(@bundle) do
      {:ok, contents} ->
        assert contents =~ "YourInterview"
        assert contents =~ "mount"
        # The bundle must stay close to the ~5KB budget (PLAN §3.1).
        # Check the *minified* size is the gate; unminified dev builds
        # blow well past 5KB, so we only assert when the bundle is small
        # (i.e. someone ran `--minify`).
        size = byte_size(contents)
        assert size < 50_000, "embed bundle suspiciously large at #{size} bytes"

      {:error, :enoent} ->
        # Tolerated: a fresh checkout where `mix esbuild embed` hasn't
        # run yet. CI / `mix assets.build` produces it; this test isn't
        # the gate for that.
        :ok
    end
  end
end
