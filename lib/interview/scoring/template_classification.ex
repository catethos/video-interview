defmodule Interview.Scoring.TemplateClassification do
  @moduledoc """
  The cached P1 (classification) output for one template version
  (PLAN — scoring-integration-plan.md §"template_classifications").

  P1 reads only the interview *questions* — never a candidate's answers —
  so its result is identical for every candidate on the same template
  version. We compute it once (on the first candidate's scoring run) and
  reuse it for everyone else. This is the v2 fairness fix: the same
  questions are classified the same way for all candidates, instead of
  drifting per transcript.

  The cache key is `(template_version_id, pipeline_version)`: bumping the
  pipeline build invalidates old rows naturally, since a new build writes
  a new row rather than overwriting.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "template_classifications" do
    field :pipeline_version, :string
    field :provider, :string
    field :result, :map
    field :computed_at, :utc_datetime_usec

    belongs_to :template_version, Interview.Templates.Version

    timestamps(updated_at: false)
  end

  def changeset(template_classification, attrs) do
    template_classification
    |> cast(attrs, [:template_version_id, :pipeline_version, :provider, :result, :computed_at])
    |> validate_required([:template_version_id, :pipeline_version, :result, :computed_at])
    |> unique_constraint([:template_version_id, :pipeline_version],
      name: :template_classifications_version_pipeline_index
    )
  end
end
