defmodule Interview.Scoring.SessionScore do
  @moduledoc """
  A metadata-only record that a session was put through the scoring
  pipeline (PLAN — scoring-integration-plan.md §"session_scores").

  This row holds *no* pipeline outputs — those go to the consumer in the
  `session.scored` webhook payload. Keeping it compact lets VI answer
  "was this session scored, with which pipeline, when?" cheaply, and lets
  the worker short-circuit on Oban retries so the pipeline never runs twice
  (a cost guard, since each run is several LLM calls).

  Two terminal statuses:

    * `"ready"`  — pipeline ran; the `session.scored` webhook was enqueued.
    * `"failed"` — pipeline gave up after retries; the
      `session.scoring_failed` webhook was enqueued. `error_reason` holds a
      stable machine code (e.g. `"rate_limited"`).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(ready failed)

  schema "session_scores" do
    field :pipeline_version, :string
    field :status, :string
    field :error_reason, :string
    field :computed_at, :utc_datetime_usec

    belongs_to :session, Interview.Capture.Session

    timestamps(updated_at: false)
  end

  def changeset(session_score, attrs) do
    session_score
    |> cast(attrs, [:session_id, :pipeline_version, :status, :error_reason, :computed_at])
    |> validate_required([:session_id, :pipeline_version, :status, :computed_at])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:session_id, :pipeline_version])
  end

  def statuses, do: @statuses
end
