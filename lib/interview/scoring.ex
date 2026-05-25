defmodule Interview.Scoring do
  @moduledoc """
  Public API for the scoring subsystem (PLAN — scoring-integration-plan.md
  §"Context module").

  Responsibilities:

    * **Pipeline identity** — `pipeline_version/0`, loaded from the committed
      `topology.json`. The cache key and the webhook both key on it.
    * **P1 classification cache** — `get_classification/2`,
      `upsert_classification/1`, `with_classification_lock/2`. P1 reads only
      the questions (+ job_role), so its result is shared across every
      candidate on a template version; we compute it once and reuse it.
    * **P1 compute** — `classify/1` runs the P1 stage alone (no DB writes).
    * **Run bookkeeping** — `record_score/3`, `already_scored?/2`. A compact
      `session_scores` receipt so the worker can short-circuit on retries
      (cost guard) and observability can answer "scored? when? which build?".
    * **Eligibility** — `eligible_for_scoring?/1`, the gate `rollup_session/1`
      checks before enqueuing the worker.

  The heavy lifting (running P2-P5, building the webhook payload) lives in
  `score_session/1` — added next — which composes these pieces.
  """

  import Ecto.Query

  alias Interview.Capture.Session
  alias Interview.ExternalIntegration.ScoringExport
  alias Interview.Repo
  alias Interview.Scoring.{PipelineRunner, SessionScore, TemplateClassification, Topology}

  @doc "The pipeline build string, from the committed topology.json."
  @spec pipeline_version() :: String.t()
  def pipeline_version, do: topology().pipeline_version

  @doc "The loaded, validated pipeline topology (cached after first load)."
  @spec topology() :: Topology.t()
  def topology do
    case :persistent_term.get({__MODULE__, :topology}, nil) do
      nil ->
        {:ok, topology} = Topology.load()
        :persistent_term.put({__MODULE__, :topology}, topology)
        topology

      topology ->
        topology
    end
  end

  @doc "The cached P1 classification for a template version, or nil."
  @spec get_classification(Ecto.UUID.t(), String.t()) :: TemplateClassification.t() | nil
  def get_classification(template_version_id, pipeline_version) do
    Repo.get_by(TemplateClassification,
      template_version_id: template_version_id,
      pipeline_version: pipeline_version
    )
  end

  @doc """
  Insert a classification, idempotent on `(template_version_id,
  pipeline_version)`. Returns the canonical persisted row whether this call
  inserted it or a concurrent one already did. `attrs` is atom-keyed.
  """
  @spec upsert_classification(map()) ::
          {:ok, TemplateClassification.t()} | {:error, Ecto.Changeset.t()}
  def upsert_classification(attrs) do
    %TemplateClassification{}
    |> TemplateClassification.changeset(attrs)
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:template_version_id, :pipeline_version]
    )
    |> case do
      {:ok, _} -> {:ok, get_classification(attrs.template_version_id, attrs.pipeline_version)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Take a Postgres transaction-scoped advisory lock keyed on the template
  version, then run `fun`. Serializes concurrent first-candidate workers
  computing P1 for the same template so they can't double-spend the LLM —
  the lock auto-releases when the transaction commits.
  """
  @spec with_classification_lock(Ecto.UUID.t(), (-> result)) :: {:ok, result} | {:error, term()}
        when result: term()
  def with_classification_lock(template_version_id, fun) when is_function(fun, 0) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1)::bigint)", [template_version_id])
      fun.()
    end)
  end

  @doc """
  Run the P1 stage alone for an input row and return `{:ok, %{result,
  provider}}`. Pure compute — no DB writes (the caller caches the result).
  `result` wraps the raw P1 rows so they can be replayed verbatim as the
  `p1_results` global on a cache hit.
  """
  @spec classify(map()) :: {:ok, %{result: map(), provider: String.t() | nil}} | {:error, term()}
  def classify(input_row) do
    case PipelineRunner.run_pipeline(topology(), input_row, only: ["p1"]) do
      {:ok, %{stage_outputs: %{"p1" => rows}}} ->
        # provider (which model produced P1) is not recorded in v1 — the
        # model lives in the .lat, not the topology. See contract §12.4.
        {:ok, %{result: %{"rows" => rows}, provider: nil}}

      {:ok, _} ->
        {:error, :p1_not_produced}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Record that a session was scored. Idempotent on `(session_id,
  pipeline_version)`; returns the canonical row. `status` is `:ready` or
  `:failed`; pass `error_reason:` for failures.
  """
  @spec record_score(Ecto.UUID.t(), :ready | :failed, keyword()) ::
          {:ok, SessionScore.t()} | {:error, Ecto.Changeset.t()}
  def record_score(session_id, status, opts \\ []) when status in [:ready, :failed] do
    pipeline_version = pipeline_version()

    attrs = %{
      session_id: session_id,
      pipeline_version: pipeline_version,
      status: Atom.to_string(status),
      error_reason: Keyword.get(opts, :error_reason),
      computed_at: DateTime.utc_now()
    }

    %SessionScore{}
    |> SessionScore.changeset(attrs)
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:session_id, :pipeline_version])
    |> case do
      {:ok, _} ->
        {:ok,
         Repo.get_by(SessionScore, session_id: session_id, pipeline_version: pipeline_version)}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc "Whether a `session_scores` row already exists for this build (the cost guard)."
  @spec already_scored?(Ecto.UUID.t(), String.t()) :: boolean()
  def already_scored?(session_id, pipeline_version) do
    Repo.exists?(
      from s in SessionScore,
        where: s.session_id == ^session_id and s.pipeline_version == ^pipeline_version
    )
  end

  @doc """
  Whether a session is ready to be scored — state `ready` and every selected
  response transcribed. Reuses `ScoringExport.build/2` so "ready to score"
  has a single definition.
  """
  @spec eligible_for_scoring?(Ecto.UUID.t()) :: boolean()
  def eligible_for_scoring?(session_id) do
    case Repo.get(Session, session_id) do
      %Session{tenant_id: tenant_id} ->
        match?({:ok, _}, ScoringExport.build(tenant_id, session_id))

      nil ->
        false
    end
  end

  @doc """
  Score a finalized session end-to-end and return the `session.scored`
  webhook `data` payload (contract §4). Does NOT write `session_scores` or
  enqueue the webhook — the worker does both, so it can branch on success vs
  failure.

  Resolves P1 from the cache (computing + caching it under the advisory lock
  on a miss), runs P2-P5 with the cached P1 bound as `p1_results`, then
  assembles the payload. Returns `{:error, :not_ready}` when the session
  isn't finalized yet (the worker snoozes and retries).
  """
  @spec score_session(Ecto.UUID.t()) :: {:ok, map()} | {:error, term()}
  def score_session(session_id) do
    with {:ok, session} <- fetch_session(session_id),
         {:ok, export} <- ScoringExport.build(session.tenant_id, session_id),
         input_row = build_input_row(session, export),
         {:ok, p1_rows, provider} <- resolve_p1(session.template_version_id, input_row),
         {:ok, %{stage_outputs: stage_outputs}} <-
           PipelineRunner.run_pipeline(topology(), input_row,
             prebound: %{"p1_results" => p1_rows}
           ) do
      {:ok, build_scored_payload(session, p1_rows, provider, stage_outputs, export)}
    end
  end

  defp fetch_session(session_id) do
    case Repo.get(Session, session_id) do
      %Session{} = session -> {:ok, session}
      nil -> {:error, :not_found}
    end
  end

  defp build_input_row(%Session{} = session, export) do
    %{
      "custom_id" => session.id,
      "template_version_id" => session.template_version_id,
      "job_role" => session.job_role || "",
      "job_description" => session.job_description || "",
      "candidate_name" => "",
      "candidate_email" => session.candidate_email || "",
      "interview_transcript" => Jason.encode!(pipeline_transcript(export))
    }
  end

  # The pipeline only needs the Q+A trio; the .lat SQL parses this string.
  defp pipeline_transcript(export) do
    Enum.map(export.interview_transcript, fn q ->
      %{
        "question_number" => q.question_number,
        "question_text" => q.question_text,
        "answer_text" => q.answer_text
      }
    end)
  end

  # Cache hit → reuse. Miss → compute under the advisory lock, re-checking
  # inside it so a racing worker that just populated the cache wins without a
  # second LLM call.
  defp resolve_p1(template_version_id, input_row) do
    pipeline_version = pipeline_version()

    case get_classification(template_version_id, pipeline_version) do
      %TemplateClassification{result: %{"rows" => rows}, provider: provider} ->
        {:ok, rows, provider}

      nil ->
        compute_and_cache_p1(template_version_id, input_row, pipeline_version)
    end
  end

  defp compute_and_cache_p1(template_version_id, input_row, pipeline_version) do
    template_version_id
    |> with_classification_lock(fn ->
      case get_classification(template_version_id, pipeline_version) do
        %TemplateClassification{result: %{"rows" => rows}, provider: provider} ->
          {rows, provider}

        nil ->
          case classify(input_row) do
            {:ok, %{result: %{"rows" => rows} = result, provider: provider}} ->
              {:ok, _} =
                upsert_classification(%{
                  template_version_id: template_version_id,
                  pipeline_version: pipeline_version,
                  provider: provider,
                  result: result,
                  computed_at: DateTime.utc_now()
                })

              {rows, provider}

            {:error, reason} ->
              Repo.rollback(reason)
          end
      end
    end)
    |> case do
      {:ok, {rows, provider}} -> {:ok, rows, provider}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_scored_payload(%Session{} = session, p1_rows, provider, stage_outputs, export) do
    %{
      "pipeline_version" => pipeline_version(),
      "scored_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "classification_provider" => provider,
      # Frozen snapshot of the job context the pipeline ran against (job_role
      # feeds P1; job_description feeds P2-P5). Travels with the score so the
      # record is self-describing even if the consumer later edits the job.
      "job_context" => %{"role" => session.job_role, "description" => session.job_description},
      "classifications" => classifications_from(p1_rows),
      "pipeline_outputs" => %{
        "p2" => p2_output(stage_outputs["p2"]),
        "p3" =>
          per_question(
            stage_outputs["p3"],
            ~w(clarity_coherence relevance_completeness support_quality)
          ),
        "p4" => per_question(stage_outputs["p4"], ~w(layer2_scores)),
        "p5" => p5_output(stage_outputs["p5"])
      },
      "interview_transcript" => webhook_transcript(export)
    }
  end

  defp classifications_from([row | _]), do: decode_maybe(row["classifications"])
  defp classifications_from(_), do: []

  defp p2_output([row | _]),
    do: %{"question_evidences" => decode_maybe(row["question_evidences"])}

  defp p2_output(_), do: %{"question_evidences" => []}

  defp p5_output([row | _]) do
    %{
      "overall_insights" => decode_maybe(row["overall_insights"]),
      "question_level_evaluation" => decode_maybe(row["question_level_evaluation"])
    }
  end

  defp p5_output(_), do: %{"overall_insights" => [], "question_level_evaluation" => []}

  # Per-question stages (p3/p4): one entry per question, each carrying
  # question_number (which ProcessData passes through) plus the decoded score
  # fields. Joinable to interview_transcript + classifications.
  defp per_question(rows, fields) when is_list(rows) do
    Enum.map(rows, fn row ->
      Enum.reduce(fields, %{"question_number" => row["question_number"]}, fn field, acc ->
        Map.put(acc, field, decode_maybe(row[field]))
      end)
    end)
  end

  defp per_question(_, _), do: []

  defp webhook_transcript(export) do
    Enum.map(export.interview_transcript, fn q ->
      %{
        "question_number" => q.question_number,
        "question_text" => q.question_text,
        "answer_text" => q.answer_text,
        "response_id" => q.response_id,
        "duration_ms" => q.duration_ms,
        "focus_lost_count" => q.focus_lost_count,
        "focus_lost_total_ms" => q.focus_lost_total_ms
      }
    end)
  end

  # Stage outputs may arrive as JSON strings (the DuckDB serialization quirk)
  # or as already-decoded maps/lists; normalize to real JSON either way.
  defp decode_maybe(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _} -> value
    end
  end

  defp decode_maybe(value), do: value
end
