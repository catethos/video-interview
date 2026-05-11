defmodule Interview.Templates.YamlImporter do
  @moduledoc """
  YAML import/export for a template version (PLAN §3.4 canonical file
  format). Round-trips through `Interview.Templates.Spec`. CSV is
  explicitly rejected — see PLAN §3.4 for the rationale.

  Validation errors carry both the structured `path` (for programmatic
  use) and a best-effort `line` lookup against the original source.
  """

  alias Interview.Templates.Spec

  @doc """
  Parse a YAML string into `{:ok, %Spec{}}` or `{:error, errors}`.

  Errors are `[%{path: [...], message: "...", line: integer | nil}]`
  for validation failures, or `[%{message: "...", line: integer | nil}]`
  for parse failures.
  """
  def parse(source) when is_binary(source) do
    case YamlElixir.read_from_string(source) do
      {:ok, raw} when is_map(raw) ->
        spec = Spec.from_map(raw)

        case Spec.validate(spec) do
          {:ok, spec} ->
            {:ok, spec}

          {:error, errors} ->
            {:error, annotate_lines(errors, source)}
        end

      {:ok, _other} ->
        {:error, [%{message: "YAML root must be a mapping", line: 1}]}

      {:error, %YamlElixir.ParsingError{message: msg, line: line}} ->
        {:error, [%{message: msg, line: line}]}

      {:error, %{message: msg}} ->
        {:error, [%{message: msg, line: nil}]}
    end
  end

  @doc """
  Serialize a `%Spec{}` back to YAML. Round-trips with `parse/1`.
  """
  def dump(%Spec{} = spec) do
    iolist = [
      "template:\n",
      indent_block(2, render_kv("name", spec.template["name"])),
      maybe(spec.template["description"], fn d ->
        indent_block(2, render_kv("description", d))
      end),
      "retake_policy:\n",
      indent_block(2, render_kv("max_attempts", spec.retake_policy["max_attempts"])),
      indent_block(2, render_kv("mode", spec.retake_policy["mode"])),
      "questions:\n",
      Enum.map(spec.questions, &render_question/1)
    ]

    IO.iodata_to_binary(iolist)
  end

  defp render_question(q) do
    # First line of a list item starts with `  - `; remaining lines `    `.
    head_field = "position"
    head_value = render_kv(head_field, q["position"])

    rest_fields =
      ~w(prompt_text think_time_seconds min_answer_seconds max_answer_seconds
         required max_attempts_override tags external_id locale prompt_asset_id
         attachment_asset_id notes)

    rest =
      Enum.flat_map(rest_fields, fn field ->
        case q[field] do
          nil -> []
          [] -> []
          v -> [render_field(field, v)]
        end
      end)

    [
      "  - ",
      head_value,
      Enum.map(rest, &indent_block(4, &1))
    ]
  end

  # `prompt_text` is rendered as `prompt:` in YAML to match the PLAN §3.4
  # examples. The importer accepts both forms.
  defp render_field("prompt_text", value), do: render_kv("prompt", value)
  defp render_field(field, value), do: render_kv(field, value)

  defp render_kv(key, value) when is_binary(value) do
    cond do
      String.contains?(value, "\n") ->
        [key, ": |\n", indent_block(2, value), "\n"]

      needs_quoting?(value) ->
        [key, ": ", quote_string(value), "\n"]

      true ->
        [key, ": ", value, "\n"]
    end
  end

  defp render_kv(key, value) when is_integer(value) or is_float(value) do
    [key, ": ", to_string(value), "\n"]
  end

  defp render_kv(key, true), do: [key, ": true\n"]
  defp render_kv(key, false), do: [key, ": false\n"]

  defp render_kv(key, list) when is_list(list) do
    if Enum.all?(list, &is_binary/1) do
      items = Enum.map(list, fn s -> ["  - ", quote_if_needed(s), "\n"] end)
      [key, ":\n", items]
    else
      [key, ": ", inspect(list), "\n"]
    end
  end

  defp render_kv(key, value), do: [key, ": ", inspect(value), "\n"]

  defp needs_quoting?(s) do
    String.starts_with?(s, ["'", "\"", "&", "*", "!", "|", ">", "%", "@", "`", "#", "?", "-"]) or
      String.contains?(s, [": ", " #", "\t"]) or
      s in ["true", "false", "null", "yes", "no", "~", ""]
  end

  defp quote_if_needed(s) do
    if needs_quoting?(s), do: quote_string(s), else: s
  end

  defp quote_string(s) do
    escaped = String.replace(s, "\"", "\\\"")
    [?", escaped, ?"]
  end

  defp indent_block(n, iodata) when is_integer(n) do
    pad = String.duplicate(" ", n)

    iodata
    |> IO.iodata_to_binary()
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> pad <> line
    end)
  end

  defp maybe(nil, _fun), do: []
  defp maybe(value, fun), do: fun.(value)

  # ---- error → line annotation -----------------------------------------

  defp annotate_lines(errors, source) do
    lines = String.split(source, "\n")
    question_starts = scan_question_starts(lines)

    Enum.map(errors, fn err -> Map.put(err, :line, locate(err.path, lines, question_starts)) end)
  end

  # `question_starts` is a list of 1-based line numbers, one per top-level
  # `- ` item under `questions:`.
  defp scan_question_starts(lines) do
    in_questions? =
      lines
      |> Enum.with_index(1)
      |> Enum.reduce({false, []}, fn {line, lineno}, {in_q, acc} ->
        cond do
          Regex.match?(~r/^questions\s*:\s*$/, line) ->
            {true, acc}

          in_q and Regex.match?(~r/^\s{0,2}-\s/, line) ->
            {true, [lineno | acc]}

          in_q and Regex.match?(~r/^\S/, line) ->
            # Top-level key resumed (e.g. another root field after the list)
            {false, acc}

          true ->
            {in_q, acc}
        end
      end)

    in_questions? |> elem(1) |> Enum.reverse()
  end

  defp locate([:template, _field], lines, _qs) do
    find_line(lines, ~r/^template\s*:/)
  end

  defp locate([:retake_policy, _field], lines, _qs) do
    find_line(lines, ~r/^retake_policy\s*:/)
  end

  defp locate(["template", _field], lines, _qs), do: find_line(lines, ~r/^template\s*:/)

  defp locate(["retake_policy", _field], lines, _qs),
    do: find_line(lines, ~r/^retake_policy\s*:/)

  defp locate(["questions"], lines, _qs), do: find_line(lines, ~r/^questions\s*:/)

  defp locate(["questions", idx], _lines, qs) when is_integer(idx) do
    Enum.at(qs, idx)
  end

  defp locate(["questions", idx, field], lines, qs) when is_integer(idx) and is_binary(field) do
    case Enum.at(qs, idx) do
      nil ->
        nil

      start_line ->
        end_line = Enum.at(qs, idx + 1) || length(lines) + 1
        slice = Enum.slice(lines, (start_line - 1)..(end_line - 2))
        # YAML uses `prompt:` for prompt_text
        keys =
          case field do
            "prompt_text" -> ["prompt_text", "prompt"]
            other -> [other]
          end

        find_in_slice(slice, start_line, keys)
    end
  end

  defp locate(_, _, _), do: nil

  defp find_line(lines, regex) do
    lines
    |> Enum.with_index(1)
    |> Enum.find_value(fn {line, lineno} ->
      if Regex.match?(regex, line), do: lineno
    end)
  end

  defp find_in_slice(slice, start_line, keys) do
    slice
    |> Enum.with_index(start_line)
    |> Enum.find_value(fn {line, lineno} ->
      cond do
        Enum.any?(keys, fn k -> Regex.match?(~r/^\s*#{Regex.escape(k)}\s*:/, line) end) ->
          lineno

        true ->
          nil
      end
    end) || start_line
  end
end
