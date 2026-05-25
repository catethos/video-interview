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
end
