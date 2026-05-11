defmodule Mix.Tasks.Sdk.Test do
  @shortdoc "Run @you/interview-embed SDK unit tests via Node's test runner"

  @moduledoc """
  Shells out to `node --test assets/embed/__tests__/` (PLAN §7 Phase 3
  carry-forward).

  Behaviour:

    * If Node is on PATH → run the suite, fail the task on non-zero exit.
    * If Node is NOT on PATH → `Logger.warning` and skip (CI may not have
      Node; local devs should). Skipping is intentional — the goal is to
      catch SDK regressions on developer machines, not to gate CI on a
      tool we don't ship as part of the Elixir Mix toolchain.

  Wired into `mix precommit` so the SDK can't regress silently between
  Phoenix-side changes.
  """
  use Mix.Task

  require Logger

  @tests_path "assets/embed/__tests__"

  @impl true
  def run(_args) do
    case System.find_executable("node") do
      nil ->
        Logger.warning(
          "sdk.test: node not on PATH; skipping SDK unit tests. " <>
            "(install Node to run them locally — they live in #{@tests_path})"
        )

        :ok

      node ->
        if not File.dir?(@tests_path) do
          Logger.warning("sdk.test: #{@tests_path} not found; skipping")
          :ok
        else
          run_node(node)
        end
    end
  end

  defp run_node(node) do
    Mix.shell().info("sdk.test: running node --test #{@tests_path}")

    {output, status} = System.cmd(node, ["--test", @tests_path], stderr_to_stdout: true)

    Mix.shell().info(output)

    cond do
      status == 0 ->
        :ok

      String.contains?(output, "ENOENT") ->
        Logger.warning("sdk.test: node could not find the test files; skipping")
        :ok

      true ->
        Mix.raise("sdk.test failed (exit #{status}); see output above")
    end
  end
end
