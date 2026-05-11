defmodule Interview.Templates.Question do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias Interview.Repo
  alias Interview.Templates.{PromptAsset, Template, Version}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "template_questions" do
    field :position, :integer
    field :prompt_text, :string
    field :think_time_seconds, :integer
    field :max_answer_seconds, :integer
    field :min_answer_seconds, :integer
    field :required, :boolean, default: true
    field :max_attempts_override, :integer
    field :tags, {:array, :string}, default: []
    field :locale, :string
    field :external_id, :string
    field :notes, :string

    belongs_to :template_version, Interview.Templates.Version
    belongs_to :prompt_asset, Interview.Templates.PromptAsset
    belongs_to :attachment_asset, Interview.Templates.PromptAsset

    timestamps()
  end

  def changeset(question, attrs) do
    question
    |> cast(attrs, [
      :template_version_id,
      :position,
      :prompt_text,
      :prompt_asset_id,
      :attachment_asset_id,
      :think_time_seconds,
      :max_answer_seconds,
      :min_answer_seconds,
      :required,
      :max_attempts_override,
      :tags,
      :locale,
      :external_id,
      :notes
    ])
    |> validate_required([:template_version_id, :position, :prompt_text])
    |> unique_constraint([:template_version_id, :position])
    |> validate_asset_reference(:prompt_asset_id)
    |> validate_asset_reference(:attachment_asset_id)
  end

  # An attached asset must (a) exist, (b) belong to the same tenant as
  # the question's template_version, (c) be in state `ready`. Importers
  # surface the resulting changeset error with a line/path location.
  defp validate_asset_reference(changeset, field) do
    asset_id = get_field(changeset, field)
    version_id = get_field(changeset, :template_version_id)

    cond do
      is_nil(asset_id) ->
        changeset

      is_nil(version_id) ->
        # No version yet → defer; require_required will already fail.
        changeset

      true ->
        case lookup_asset(asset_id, version_id) do
          nil ->
            add_error(changeset, field, "does not exist")

          {_state, false} ->
            add_error(changeset, field, "belongs to a different tenant")

          {state, true} when state != "ready" ->
            add_error(changeset, field, "is not ready (state=#{state})")

          {_state, true} ->
            changeset
        end
    end
  end

  defp lookup_asset(asset_id, version_id) do
    Repo.one(
      from a in PromptAsset,
        join: v in Version,
        on: v.id == ^version_id,
        join: t in Template,
        on: t.id == v.template_id,
        where: a.id == ^asset_id,
        select: {a.state, a.tenant_id == t.tenant_id}
    )
  end
end
