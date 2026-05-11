defmodule Interview.Templates.MarkdownImporter do
  @moduledoc """
  Markdown-with-frontmatter importer (PLAN §3.4). One `.md` file per
  template version, structured as:

      ---
      template: <template name>          # or `template: {name: ..., description: ...}`
      retake_policy: { max_attempts: 2, mode: last }
      ---

      ---
      position: 1
      …
      ---

      <markdown prompt body>

      ---
      position: 2
      …
      ---

      <markdown prompt body>

  Normalises to the same `Interview.Templates.Spec` as the YAML importer
  and JSON API, then runs the shared validator.
  """

  alias Interview.Templates.Spec

  @doc """
  Parse markdown-with-frontmatter source. Returns `{:ok, %Spec{}}` or
  `{:error, errors}` (each error carries `:line` against the original
  source where possible).
  """
  def parse(source) when is_binary(source) do
    case split_blocks(source) do
      {:ok, template_fm, question_blocks} ->
        with {:ok, template_map, _tline} <- parse_template_block(template_fm),
             {:ok, questions} <- parse_question_blocks(question_blocks) do
          raw = %{
            "template" => template_map["template"],
            "retake_policy" => template_map["retake_policy"],
            "questions" => questions
          }

          spec = Spec.from_map(raw)

          case Spec.validate(spec) do
            {:ok, spec} ->
              {:ok, spec}

            {:error, errors} ->
              {:error, annotate_lines(errors, question_blocks, template_fm)}
          end
        end

      {:error, _} = err ->
        err
    end
  end

  # Splits source into:
  #   - a single template frontmatter block (between the first two `---`)
  #   - a list of `{frontmatter, body, fm_line, body_line}` for each
  #     subsequent question.
  defp split_blocks(source) do
    lines = String.split(source, "\n")
    delimiters = scan_delimiters(lines)

    case delimiters do
      [_, _ | _] = pairs when rem(length(pairs), 2) == 0 ->
        do_split(lines, pairs)

      [_ | _] ->
        {:error,
         [
           %{
             message: "unmatched `---` delimiter; question frontmatter must be closed",
             line: 1
           }
         ]}

      _ ->
        {:error,
         [
           %{
             message:
               "expected at least two `---` delimiters; questions are framed by `---` blocks",
             line: 1
           }
         ]}
    end
  end

  defp scan_delimiters(lines) do
    lines
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _} -> Regex.match?(~r/^---\s*$/, line) end)
    |> Enum.map(fn {_, lineno} -> lineno end)
  end

  defp do_split(lines, [t_open, t_close | rest]) do
    template_fm = %{
      lines: Enum.slice(lines, t_open..(t_close - 2)) |> Enum.join("\n"),
      start_line: t_open + 1
    }

    case parse_question_pairs(lines, rest, []) do
      {:ok, questions} -> {:ok, template_fm, questions}
      {:error, _} = err -> err
    end
  end

  defp parse_question_pairs(_lines, [], acc), do: {:ok, Enum.reverse(acc)}

  defp parse_question_pairs(_lines, [_only], _acc) do
    {:error,
     [%{message: "unmatched `---` delimiter; question frontmatter must be closed", line: nil}]}
  end

  defp parse_question_pairs(lines, [open, close | tail], acc) do
    fm = Enum.slice(lines, open..(close - 2)) |> Enum.join("\n")

    {body_end, remaining} =
      case tail do
        [next_open | _] -> {next_open - 2, tail}
        [] -> {length(lines) - 1, []}
      end

    body =
      Enum.slice(lines, close..body_end)
      |> Enum.join("\n")
      |> String.trim()

    parse_question_pairs(lines, remaining, [
      %{fm: fm, body: body, fm_line: open + 1, body_line: close + 1} | acc
    ])
  end

  defp parse_template_block(%{lines: source, start_line: line}) do
    case YamlElixir.read_from_string(source) do
      {:ok, raw} when is_map(raw) ->
        {:ok, normalise_template_frontmatter(raw), line}

      {:ok, _} ->
        {:error, [%{message: "template frontmatter must be a mapping", line: line}]}

      {:error, %YamlElixir.ParsingError{message: msg, line: l}} ->
        {:error, [%{message: msg, line: line + (l || 0)}]}

      {:error, %{message: msg}} ->
        {:error, [%{message: msg, line: line}]}
    end
  end

  defp normalise_template_frontmatter(raw) do
    template =
      case raw["template"] do
        nil -> %{}
        s when is_binary(s) -> %{"name" => s}
        m when is_map(m) -> m
      end

    %{
      "template" => template,
      "retake_policy" => raw["retake_policy"]
    }
  end

  defp parse_question_blocks(blocks) do
    blocks
    |> Enum.reduce_while({:ok, []}, fn block, {:ok, acc} ->
      case parse_question_block(block) do
        {:ok, q} -> {:cont, {:ok, [q | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, qs} -> {:ok, Enum.reverse(qs)}
      err -> err
    end
  end

  defp parse_question_block(%{fm: fm, body: body, fm_line: fm_line}) do
    case YamlElixir.read_from_string(fm) do
      {:ok, raw} when is_map(raw) ->
        prompt = if body == "", do: nil, else: body
        merged = Map.put_new(raw, "prompt_text", prompt)
        {:ok, merged}

      {:ok, _} ->
        {:error, [%{message: "question frontmatter must be a mapping", line: fm_line}]}

      {:error, %YamlElixir.ParsingError{message: msg, line: l}} ->
        {:error, [%{message: msg, line: fm_line + (l || 0)}]}

      {:error, %{message: msg}} ->
        {:error, [%{message: msg, line: fm_line}]}
    end
  end

  # ---- error → line annotation -----------------------------------------

  defp annotate_lines(errors, question_blocks, template_fm) do
    Enum.map(errors, fn err ->
      Map.put(err, :line, locate_line(err.path, question_blocks, template_fm))
    end)
  end

  defp locate_line(["template" | _], _qs, t), do: t.start_line
  defp locate_line(["retake_policy" | _], _qs, t), do: t.start_line
  defp locate_line(["questions"], _qs, t), do: t.start_line

  defp locate_line(["questions", idx], qs, _t) when is_integer(idx) do
    case Enum.at(qs, idx) do
      nil -> nil
      block -> block.fm_line
    end
  end

  defp locate_line(["questions", idx, field], qs, _t)
       when is_integer(idx) and is_binary(field) do
    case Enum.at(qs, idx) do
      nil ->
        nil

      block ->
        cond do
          field == "prompt_text" ->
            block.body_line

          true ->
            find_field_in_fm(block.fm, block.fm_line, field) || block.fm_line
        end
    end
  end

  defp locate_line(_, _, _), do: nil

  defp find_field_in_fm(fm, start_line, field) do
    fm
    |> String.split("\n")
    |> Enum.with_index(start_line)
    |> Enum.find_value(fn {line, lineno} ->
      if Regex.match?(~r/^\s*#{Regex.escape(field)}\s*:/, line), do: lineno
    end)
  end
end
