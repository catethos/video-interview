defmodule Interview.Templates.Spec do
  @moduledoc """
  Canonical intermediate representation for a template version. YAML,
  markdown-with-frontmatter, and JSON all parse into this struct, then
  pass through `validate/1`. One code path, three front doors (PLAN
  §3.4 importer behaviour).

  Validation errors are returned as a list of `%{path, message}` maps.
  `path` is a list of segments — strings for keys, integers for list
  indexes (0-based). Importers translate the path into a human-readable
  location: line numbers for YAML/markdown, JSON pointers for API.
  """

  alias __MODULE__

  defstruct template: %{}, retake_policy: %{}, questions: []

  @type path_segment :: String.t() | non_neg_integer()
  @type validation_error :: %{path: [path_segment()], message: String.t()}

  @valid_modes ~w(first_only last)
  @question_int_fields ~w(position think_time_seconds min_answer_seconds max_answer_seconds max_attempts_override)
  @question_string_fields ~w(prompt_text external_id locale notes prompt_asset_id attachment_asset_id)

  @doc """
  Build a `%Spec{}` from a parsed map (string-keyed). Pure shape coercion;
  defers checks to `validate/1`. Unknown top-level or per-question keys
  are passed through to `validate/1` so the validator can flag them.
  """
  def from_map(raw) when is_map(raw) do
    %Spec{
      template: take_string_keys(raw["template"] || %{}, ~w(name description)),
      retake_policy: normalise_retake(raw["retake_policy"] || %{}),
      questions: normalise_questions(raw["questions"] || [])
    }
  end

  defp normalise_retake(rp) when is_map(rp) do
    %{
      "max_attempts" => rp["max_attempts"],
      "mode" => rp["mode"]
    }
  end

  defp normalise_retake(_), do: %{"max_attempts" => nil, "mode" => nil}

  defp normalise_questions(qs) when is_list(qs) do
    qs
    |> Enum.with_index()
    |> Enum.map(fn {q, idx} -> normalise_question(q, idx) end)
  end

  defp normalise_questions(_), do: []

  defp normalise_question(q, _idx) when is_map(q) do
    # Translate `prompt` -> `prompt_text` if the source used the YAML/MD
    # shorthand. The DB column is `prompt_text`.
    base =
      case Map.fetch(q, "prompt") do
        {:ok, v} -> Map.put_new(q, "prompt_text", v)
        :error -> q
      end

    %{
      "position" => base["position"],
      "prompt_text" => base["prompt_text"],
      "think_time_seconds" => base["think_time_seconds"],
      "min_answer_seconds" => base["min_answer_seconds"],
      "max_answer_seconds" => base["max_answer_seconds"],
      "required" => Map.get(base, "required", true),
      "max_attempts_override" => base["max_attempts_override"],
      "tags" => base["tags"] || [],
      "locale" => base["locale"],
      "external_id" => base["external_id"],
      "notes" => base["notes"],
      "prompt_asset_id" => base["prompt_asset_id"],
      "attachment_asset_id" => base["attachment_asset_id"]
    }
  end

  defp normalise_question(_, idx) do
    %{"position" => nil, "prompt_text" => nil, "_invalid" => idx}
  end

  defp take_string_keys(map, keys) when is_map(map) do
    Enum.reduce(keys, %{}, fn k, acc -> Map.put(acc, k, map[k]) end)
  end

  defp take_string_keys(_, _), do: %{}

  @doc """
  Validate a `%Spec{}`. Returns `{:ok, spec}` or `{:error, errors}` where
  `errors` is a list of `%{path: [...], message: "..."}`.
  """
  def validate(%Spec{} = spec) do
    errors =
      []
      |> validate_template(spec.template)
      |> validate_retake_policy(spec.retake_policy)
      |> validate_questions(spec.questions)

    case errors do
      [] -> {:ok, spec}
      errs -> {:error, Enum.reverse(errs)}
    end
  end

  defp validate_template(errors, template) do
    name = template["name"]

    cond do
      is_nil(name) or name == "" ->
        [error(["template", "name"], "is required") | errors]

      not is_binary(name) ->
        [error(["template", "name"], "must be a string") | errors]

      true ->
        errors
    end
  end

  defp validate_retake_policy(errors, rp) do
    errors
    |> validate_max_attempts(rp["max_attempts"])
    |> validate_mode(rp["mode"])
  end

  defp validate_max_attempts(errors, nil), do: errors

  defp validate_max_attempts(errors, n) when is_integer(n) and n >= 1, do: errors

  defp validate_max_attempts(errors, _),
    do: [error(["retake_policy", "max_attempts"], "must be an integer >= 1") | errors]

  defp validate_mode(errors, nil), do: errors

  defp validate_mode(errors, mode) when mode in @valid_modes, do: errors

  defp validate_mode(errors, _),
    do: [
      error(
        ["retake_policy", "mode"],
        "must be one of: #{Enum.join(@valid_modes, ", ")}"
      )
      | errors
    ]

  defp validate_questions(errors, []) do
    [error(["questions"], "must contain at least one question") | errors]
  end

  defp validate_questions(errors, questions) do
    errors
    |> validate_unique_positions(questions)
    |> validate_unique_external_ids(questions)
    |> then(fn errs ->
      questions
      |> Enum.with_index()
      |> Enum.reduce(errs, fn {q, idx}, acc -> validate_question(acc, q, idx) end)
    end)
  end

  defp validate_unique_positions(errors, questions) do
    positions = Enum.map(questions, & &1["position"])

    duplicates =
      positions
      |> Enum.frequencies()
      |> Enum.filter(fn {pos, n} -> n > 1 and not is_nil(pos) end)
      |> Enum.map(&elem(&1, 0))

    Enum.reduce(duplicates, errors, fn dup_pos, acc ->
      questions
      |> Enum.with_index()
      |> Enum.filter(fn {q, _} -> q["position"] == dup_pos end)
      |> Enum.reduce(acc, fn {_, idx}, acc2 ->
        [error(["questions", idx, "position"], "duplicate position #{dup_pos}") | acc2]
      end)
    end)
  end

  defp validate_unique_external_ids(errors, questions) do
    pairs =
      questions
      |> Enum.with_index()
      |> Enum.reject(fn {q, _} -> is_nil(q["external_id"]) end)

    duplicates =
      pairs
      |> Enum.frequencies_by(fn {q, _} -> q["external_id"] end)
      |> Enum.filter(fn {_, n} -> n > 1 end)
      |> Enum.map(&elem(&1, 0))

    Enum.reduce(duplicates, errors, fn dup, acc ->
      pairs
      |> Enum.filter(fn {q, _} -> q["external_id"] == dup end)
      |> Enum.reduce(acc, fn {_, idx}, acc2 ->
        [error(["questions", idx, "external_id"], "duplicate external_id #{inspect(dup)}") | acc2]
      end)
    end)
  end

  defp validate_question(errors, q, idx) do
    errors
    |> validate_question_position(q, idx)
    |> validate_question_prompt(q, idx)
    |> validate_question_required(q, idx)
    |> validate_question_tags(q, idx)
    |> validate_question_int_fields(q, idx)
    |> validate_question_string_fields(q, idx)
    |> validate_min_le_max(q, idx)
  end

  defp validate_question_position(errors, q, idx) do
    case q["position"] do
      n when is_integer(n) and n >= 1 -> errors
      nil -> [error(["questions", idx, "position"], "is required") | errors]
      _ -> [error(["questions", idx, "position"], "must be an integer >= 1") | errors]
    end
  end

  defp validate_question_prompt(errors, q, idx) do
    case q["prompt_text"] do
      s when is_binary(s) and byte_size(s) > 0 -> errors
      nil -> [error(["questions", idx, "prompt_text"], "is required") | errors]
      "" -> [error(["questions", idx, "prompt_text"], "is required") | errors]
      _ -> [error(["questions", idx, "prompt_text"], "must be a string") | errors]
    end
  end

  defp validate_question_required(errors, q, idx) do
    case q["required"] do
      v when is_boolean(v) -> errors
      _ -> [error(["questions", idx, "required"], "must be true or false") | errors]
    end
  end

  defp validate_question_tags(errors, q, idx) do
    case q["tags"] do
      tags when is_list(tags) ->
        if Enum.all?(tags, &is_binary/1) do
          errors
        else
          [error(["questions", idx, "tags"], "every tag must be a string") | errors]
        end

      _ ->
        [error(["questions", idx, "tags"], "must be a list of strings") | errors]
    end
  end

  defp validate_question_int_fields(errors, q, idx) do
    Enum.reduce(@question_int_fields, errors, fn field, acc ->
      case q[field] do
        nil -> acc
        n when is_integer(n) and n >= 1 -> acc
        _ -> [error(["questions", idx, field], "must be an integer >= 1") | acc]
      end
    end)
  end

  defp validate_question_string_fields(errors, q, idx) do
    Enum.reduce(@question_string_fields, errors, fn field, acc ->
      case q[field] do
        nil -> acc
        s when is_binary(s) -> acc
        _ -> [error(["questions", idx, field], "must be a string") | acc]
      end
    end)
  end

  defp validate_min_le_max(errors, q, idx) do
    case {q["min_answer_seconds"], q["max_answer_seconds"]} do
      {min, max} when is_integer(min) and is_integer(max) and min > max ->
        [
          error(
            ["questions", idx, "min_answer_seconds"],
            "must be <= max_answer_seconds"
          )
          | errors
        ]

      _ ->
        errors
    end
  end

  defp error(path, message), do: %{path: path, message: message}

  @doc """
  Render a path as a JSON pointer (RFC 6901): `/questions/0/prompt_text`.
  """
  def path_to_json_pointer(path) when is_list(path) do
    "/" <> (path |> Enum.map(&pointer_segment/1) |> Enum.join("/"))
  end

  defp pointer_segment(seg) when is_integer(seg), do: Integer.to_string(seg)

  defp pointer_segment(seg) when is_binary(seg) do
    seg |> String.replace("~", "~0") |> String.replace("/", "~1")
  end
end
