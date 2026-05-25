defmodule Interview.Scoring.Topology do
  @moduledoc """
  The scoring pipeline's DAG — which stages run, in what order, and how
  each stage's output feeds the next (PLAN — scoring-integration-plan.md
  §"Topology loader").

  This is the Elixir port of pulsifi-demo's `scoring/topology.ts`. The
  wiring lives in `priv/pipelines/topology.json` (the bundle's own
  `pipeline.json` does not encode it — its edges are empty), so a pipeline
  upgrade is a new bundle + a new topology file, with no code change.

  Each stage declares the globals it `binds` and the `output_label` it
  produces. A bind is either a bare label (`"input_data"`) or `"from:as"`
  (`"p4_results:input_data"` — bind the global `p4_results` under the
  runtime name `input_data`). Stages must be listed in topological order;
  `from_map/1` rejects a stage that binds a label no earlier stage
  produces.
  """

  alias __MODULE__.Stage

  defmodule Stage do
    @moduledoc "One pipeline stage. `binds` are resolved to `%{from:, as:}`."
    @enforce_keys [:id, :lat, :binds, :output_label, :entrypoint]
    defstruct [:id, :lat, :binds, :output_label, :entrypoint]

    @type bind :: %{from: String.t(), as: String.t()}
    @type t :: %__MODULE__{
            id: String.t(),
            lat: String.t(),
            binds: [bind()],
            output_label: String.t(),
            entrypoint: String.t()
          }
  end

  @enforce_keys [:pipeline_version, :bundle_path, :stages]
  defstruct [:pipeline_version, :bundle_path, :stages]

  @type t :: %__MODULE__{
          pipeline_version: String.t(),
          bundle_path: String.t(),
          stages: [Stage.t()]
        }

  @doc """
  Load and validate the committed topology at
  `priv/pipelines/topology.json`.
  """
  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(path \\ default_path()) do
    with {:ok, body} <- File.read(path),
         {:ok, json} <- Jason.decode(body) do
      from_map(json)
    end
  end

  @doc """
  Build a `%Topology{}` from a decoded JSON map, validating the DAG.

  Returns `{:error, {:unsatisfied_bind, stage_id, label}}` if a stage binds
  a label that no earlier stage (nor the root `input_data`) produces.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(%{
        "pipeline_version" => version,
        "bundle_path" => bundle_path,
        "stages" => raw_stages
      })
      when is_binary(version) and is_binary(bundle_path) and is_list(raw_stages) do
    stages = Enum.map(raw_stages, &parse_stage/1)

    with :ok <- validate_dag(stages) do
      {:ok, %__MODULE__{pipeline_version: version, bundle_path: bundle_path, stages: stages}}
    end
  end

  def from_map(_), do: {:error, :malformed_topology}

  @doc "Absolute path to a stage's `.lat` file inside the bundle."
  @spec lat_path(t(), Stage.t()) :: Path.t()
  def lat_path(%__MODULE__{bundle_path: bundle_path}, %Stage{lat: lat}) do
    Path.join([pipelines_root(), bundle_path, lat])
  end

  defp parse_stage(%{
         "id" => id,
         "lat" => lat,
         "binds" => binds,
         "output_label" => output_label,
         "entrypoint" => entrypoint
       }) do
    %Stage{
      id: id,
      lat: lat,
      binds: Enum.map(binds, &resolve_bind/1),
      output_label: output_label,
      entrypoint: entrypoint
    }
  end

  # "from:as" → %{from: "from", as: "as"};  bare "name" → %{from: "name", as: "name"}.
  defp resolve_bind(raw) when is_binary(raw) do
    case String.split(raw, ":", parts: 2) do
      [from, as] -> %{from: from, as: as}
      [name] -> %{from: name, as: name}
    end
  end

  # Mirror of topology.ts validateDag: walk stages in order, tracking the
  # labels available so far (seeded with the root `input_data`). Every bind
  # source must already be available.
  defp validate_dag(stages) do
    Enum.reduce_while(stages, MapSet.new(["input_data"]), fn stage, available ->
      case Enum.find(stage.binds, &(not MapSet.member?(available, &1.from))) do
        nil -> {:cont, MapSet.put(available, stage.output_label)}
        %{from: missing} -> {:halt, {:error, {:unsatisfied_bind, stage.id, missing}}}
      end
    end)
    |> case do
      %MapSet{} -> :ok
      {:error, _} = error -> error
    end
  end

  defp default_path, do: Path.join(pipelines_root(), "topology.json")

  defp pipelines_root, do: Application.app_dir(:interview, "priv/pipelines")
end
