defmodule Interview.Capture.FocusEvent do
  @moduledoc """
  An attention-loss signal recorded while the candidate is mid-take.
  Used by the recruiter dashboard to surface "candidate left the tab
  N times during this answer" as a soft cheating indicator (PLAN —
  candidate-ux-overhaul-plan.md Phase 3).

  Two kinds:

    * `"lost"` — tab/window lost focus (page hidden or window blurred).
    * `"regained"` — tab/window regained focus.

  Paired but not enforced: we sometimes drop the regained event (the
  browser may navigate away entirely, or the candidate may submit
  before re-focusing). Counts use `kind = "lost"` only.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(lost regained)

  schema "question_response_focus_events" do
    field :kind, :string
    field :occurred_at, :utc_datetime_usec
    belongs_to :response, Interview.Capture.Response

    timestamps(updated_at: false)
  end

  def changeset(focus_event, attrs) do
    focus_event
    |> cast(attrs, [:response_id, :kind, :occurred_at])
    |> validate_required([:response_id, :kind, :occurred_at])
    |> validate_inclusion(:kind, @kinds)
    |> unique_constraint([:response_id, :occurred_at, :kind])
  end

  def kinds, do: @kinds
end
