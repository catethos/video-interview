defmodule Interview.SoakTelemetry do
  @moduledoc """
  Dev-only telemetry handler that pretty-prints the recorder hook's
  `pushEvent` traffic + finalizer / webhook lifecycle into the dev log
  (PLAN §7 Phase 4, Safari soak harness).

  Wire-on flag: `config :interview, :soak_telemetry, true` (default in
  `config/dev.exs`). Off in test/prod — the log volume is wasteful at
  scale and the soak only matters on the dev box anyway.

  This module reads `Logger.metadata` to add a `[soak]` tag to every
  line so a `tail -f` filter is one grep away.
  """
  require Logger

  @events [
    [:interview, :recorder, :started],
    [:interview, :recorder, :stopped],
    [:interview, :recorder, :buffer],
    [:interview, :recorder, :bitrate],
    [:interview, :recorder, :capture_complete],
    [:interview, :webhook, :delivered],
    [:interview, :webhook, :retry],
    [:interview, :webhook, :permafail],
    [:interview, :webhook, :circuit_breaker_tripped]
  ]

  def attach do
    if Application.get_env(:interview, :soak_telemetry, false) do
      :telemetry.attach_many("interview-soak", @events, &__MODULE__.handle/4, %{})
    end
  end

  def detach, do: :telemetry.detach("interview-soak")

  def handle([_, :recorder, kind], measurements, metadata, _) do
    Logger.info(
      "[soak] recorder.#{kind} session=#{metadata[:session_id]} response=#{metadata[:response_id]} " <>
        format_kv(measurements)
    )
  end

  def handle([_, :webhook, kind], measurements, metadata, _) do
    Logger.info(
      "[soak] webhook.#{kind} delivery=#{metadata[:delivery_id]} event=#{metadata[:event_type]} " <>
        format_kv(measurements)
    )
  end

  defp format_kv(map) when map_size(map) == 0, do: ""

  defp format_kv(map) do
    Enum.map_join(map, " ", fn {k, v} -> "#{k}=#{v}" end)
  end
end
