defmodule Interview.Capture.SessionQuestion do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "session_questions" do
    field :position, :integer
    # The candidate's per-session 1..N slot (shuffled when the version opts into
    # randomization). `position` stays the canonical template order.
    field :display_order, :integer
    field :selected_response_id, :binary_id

    belongs_to :session, Interview.Capture.Session
    belongs_to :template_question, Interview.Templates.Question

    timestamps()
  end

  def changeset(sq, attrs) do
    sq
    |> cast(attrs, [
      :session_id,
      :template_question_id,
      :position,
      :display_order,
      :selected_response_id
    ])
    |> validate_required([:session_id, :template_question_id, :position])
    |> unique_constraint([:session_id, :template_question_id])
  end
end
