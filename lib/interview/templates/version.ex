defmodule Interview.Templates.Version do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "interview_template_versions" do
    field :version_number, :integer
    field :retake_policy, :map, default: %{"max_attempts" => 1, "mode" => "first_only"}
    field :published_at, :utc_datetime_usec
    field :published_by, :string

    belongs_to :template, Interview.Templates.Template
    has_many :questions, Interview.Templates.Question, foreign_key: :template_version_id

    timestamps()
  end

  def changeset(version, attrs) do
    version
    |> cast(attrs, [:template_id, :version_number, :retake_policy, :published_at, :published_by])
    |> validate_required([:template_id, :version_number])
    |> unique_constraint([:template_id, :version_number])
  end
end
