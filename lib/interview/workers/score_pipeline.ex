defmodule Interview.Workers.ScorePipeline do
  @moduledoc """
  Runs the lattice scoring pipeline for a finalized session and emits the
  outcome to the consumer (PLAN — scoring-integration-plan.md §"Worker").

  Enqueued by `Capture.rollup_session/1` once a session reaches `ready` with
  every selected response transcribed. The `unique` option collapses
  accidental duplicate enqueues for the same session within a 60s window.

  Sequence:

    1. Session gone → `:discard`.
    2. Already scored for this pipeline build → `:ok` (the cost guard — an
       Oban retry on a worker that already finished must NOT re-run the
       pipeline or re-fire the webhook).
    3. `Scoring.score_session/1`:
       * `{:ok, data}` → in one transaction, write the `session_scores`
         receipt and enqueue the `session.scored` webhook (atomic, so the
         receipt and the outbound delivery never diverge). Return `:ok`.
       * `{:error, :not_ready}` → `{:snooze, 30}` (a late transcript is still
         landing; retry shortly).
       * `{:error, :not_found}` → `:discard`.
       * `{:error, {stage, reason}}` → see error policy below.

  Error policy (mirrors `WhisperTranscript`):

    * `missing_api_key` / `unauthorized` → `:discard` + operator log. These
      are configuration faults, not a per-candidate scoring failure.
    * anything else transient (`rate_limited`, `server_error`, `transport`,
      decode errors, …) → retry via `{:error, reason}` until the final
      attempt. On the final attempt, record a `failed` receipt + enqueue the
      `session.scoring_failed` webhook, then return `:ok` — the outcome is
      recorded and delivered, so Oban must mark the job completed rather than
      retry and double-fire the failure event.
  """

  use Oban.Worker,
    queue: :scoring,
    max_attempts: 6,
    unique: [period: 60, fields: [:args], keys: [:session_id]]

  require Logger

  alias Interview.Capture.Session
  alias Interview.Repo
  alias Interview.Scoring
  alias Interview.Webhooks

  @discard_reasons ~w(missing_api_key unauthorized)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"session_id" => session_id}, attempt: attempt, max_attempts: max}) do
    case Repo.get(Session, session_id) do
      nil ->
        {:discard, "session not found"}

      %Session{} = session ->
        if Scoring.already_scored?(session_id, Scoring.pipeline_version()) do
          :ok
        else
          run(session, attempt, max)
        end
    end
  end

  defp run(%Session{} = session, attempt, max) do
    case Scoring.score_session(session.id) do
      {:ok, data} -> finalize_success(session, data)
      {:error, :not_ready} -> {:snooze, 30}
      {:error, :not_found} -> {:discard, "session vanished mid-score"}
      {:error, reason} -> handle_failure(session, reason, attempt, max)
    end
  end

  defp finalize_success(%Session{} = session, data) do
    {:ok, _} =
      Repo.transaction(fn ->
        {:ok, _} = Scoring.record_score(session.id, :ready)
        {:ok, _} = Webhooks.enqueue(session, "session.scored", data)
      end)

    :ok
  end

  defp handle_failure(%Session{} = session, reason, attempt, max) do
    {stage, code, message} = classify_failure(reason)

    cond do
      code in @discard_reasons ->
        Logger.warning("scoring: #{code} (stage=#{stage}); discarding — operator action required")
        {:discard, code}

      attempt < max ->
        # Transient — let Oban back off and retry. No receipt, no webhook.
        {:error, reason}

      true ->
        finalize_failure(session, stage, code, message, attempt)
    end
  end

  defp finalize_failure(%Session{} = session, stage, code, message, attempt) do
    data = %{
      "pipeline_version" => Scoring.pipeline_version(),
      "failed_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "stage" => stage,
      "reason" => code,
      "message" => message,
      "attempts" => attempt
    }

    {:ok, _} =
      Repo.transaction(fn ->
        {:ok, _} = Scoring.record_score(session.id, :failed, error_reason: code)
        {:ok, _} = Webhooks.enqueue(session, "session.scoring_failed", data)
      end)

    :ok
  end

  # score_session stage errors are {stage_id, inner_reason}; map the inner
  # reason to a stable contract code (§5) and keep the raw term as the message.
  defp classify_failure({stage_id, inner}) when is_binary(stage_id) do
    {stage_id, reason_code(inner), inspect(inner)}
  end

  defp classify_failure(other), do: {nil, "stage_error", inspect(other)}

  defp reason_code({:rate_limited, _}), do: "rate_limited"
  defp reason_code(:rate_limited), do: "rate_limited"
  defp reason_code({:server_error, _, _}), do: "server_error"
  defp reason_code({:server_error, _}), do: "server_error"
  defp reason_code({:transport, _}), do: "transport"
  defp reason_code({:missing_api_key, _}), do: "missing_api_key"
  defp reason_code(:missing_api_key), do: "missing_api_key"
  defp reason_code({:unauthorized, _}), do: "unauthorized"
  defp reason_code(:unauthorized), do: "unauthorized"
  defp reason_code(_), do: "stage_error"
end
