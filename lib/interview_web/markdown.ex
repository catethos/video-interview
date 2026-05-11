defmodule InterviewWeb.Markdown do
  @moduledoc """
  Tiny Markdown → HTML renderer just big enough for our `docs/*.md`
  tutorials. Returns a `Phoenix.HTML.safe()` value that LiveViews can
  render with `{...}`.

  Adding a real markdown library (earmark, mdex) for one tutorial page
  would be overkill; this handles the constructs we actually use:

    * ATX headings `# … ######`
    * fenced code blocks ```` ```lang … ``` ````
    * unordered (`-`) and ordered (`1.`) lists
    * paragraphs (blank-line separated)
    * blockquotes (`>` prefix)
    * inline `code`, `**bold**`, and bare URLs / `<http://…>` autolinks

  The input is trusted (a file we ship in `priv/`), but every interpolated
  span is HTML-escaped anyway so we can never accidentally inject markup
  by editing the source doc.
  """

  alias Phoenix.HTML

  @spec to_html(binary()) :: HTML.safe()
  def to_html(markdown) when is_binary(markdown) do
    markdown
    |> String.split(~r/\r?\n/)
    |> parse_blocks([])
    |> Enum.map(&render_block/1)
    |> IO.iodata_to_binary()
    |> HTML.raw()
  end

  # ---- block parser -----------------------------------------------------

  defp parse_blocks([], acc), do: Enum.reverse(acc)

  defp parse_blocks(["" | rest], acc), do: parse_blocks(rest, acc)

  defp parse_blocks(["#" <> _ = line | rest], acc) do
    case Regex.run(~r/^(\#{1,6})\s+(.*)$/, line) do
      [_, hashes, text] ->
        parse_blocks(rest, [{:heading, String.length(hashes), text} | acc])

      _ ->
        parse_blocks(rest, [{:paragraph, [line]} | acc])
    end
  end

  defp parse_blocks(["```" <> info | rest], acc) do
    {code_lines, rest2} = take_until_fence(rest, [])
    parse_blocks(rest2, [{:code, String.trim(info), code_lines} | acc])
  end

  defp parse_blocks([line | _] = lines, acc) do
    cond do
      bullet_line?(line) ->
        {items, rest} = take_list(lines, :ul, [])
        parse_blocks(rest, [{:list, :ul, items} | acc])

      ordered_line?(line) ->
        {items, rest} = take_list(lines, :ol, [])
        parse_blocks(rest, [{:list, :ol, items} | acc])

      blockquote_line?(line) ->
        {qlines, rest} = take_blockquote(lines, [])
        parse_blocks(rest, [{:blockquote, qlines} | acc])

      true ->
        {plines, rest} = take_paragraph(lines, [])
        parse_blocks(rest, [{:paragraph, plines} | acc])
    end
  end

  defp take_until_fence([], acc), do: {Enum.reverse(acc), []}
  defp take_until_fence(["```" <> _ | rest], acc), do: {Enum.reverse(acc), rest}
  defp take_until_fence([line | rest], acc), do: take_until_fence(rest, [line | acc])

  defp bullet_line?(line), do: Regex.match?(~r/^\s*-\s+/, line)
  defp ordered_line?(line), do: Regex.match?(~r/^\s*\d+\.\s+/, line)
  defp blockquote_line?(line), do: Regex.match?(~r/^>\s?/, line)

  defp take_list([], _kind, acc), do: {Enum.reverse(acc), []}
  defp take_list(["" | rest], _kind, acc), do: {Enum.reverse(acc), rest}

  defp take_list([line | rest] = all, kind, acc) do
    case classify_list_line(line, kind) do
      {:item, text} ->
        {continuation, rest2} = take_list_continuation(rest, [])
        item_text = Enum.join([text | continuation], "\n")
        take_list(rest2, kind, [item_text | acc])

      :end ->
        {Enum.reverse(acc), all}
    end
  end

  defp classify_list_line(line, :ul) do
    case Regex.run(~r/^\s*-\s+(.*)$/, line) do
      [_, text] -> {:item, text}
      _ -> :end
    end
  end

  defp classify_list_line(line, :ol) do
    case Regex.run(~r/^\s*\d+\.\s+(.*)$/, line) do
      [_, text] -> {:item, text}
      _ -> :end
    end
  end

  defp take_list_continuation([], acc), do: {Enum.reverse(acc), []}

  defp take_list_continuation([line | rest] = all, acc) do
    cond do
      line == "" -> {Enum.reverse(acc), all}
      bullet_line?(line) or ordered_line?(line) -> {Enum.reverse(acc), all}
      Regex.match?(~r/^\s{2,}\S/, line) -> take_list_continuation(rest, [String.trim(line) | acc])
      true -> {Enum.reverse(acc), all}
    end
  end

  defp take_blockquote([], acc), do: {Enum.reverse(acc), []}
  defp take_blockquote(["" | rest], acc), do: {Enum.reverse(acc), rest}

  defp take_blockquote([line | rest] = all, acc) do
    case Regex.run(~r/^>\s?(.*)$/, line) do
      [_, text] -> take_blockquote(rest, [text | acc])
      _ -> {Enum.reverse(acc), all}
    end
  end

  defp take_paragraph([], acc), do: {Enum.reverse(acc), []}
  defp take_paragraph(["" | rest], acc), do: {Enum.reverse(acc), rest}

  defp take_paragraph([line | rest] = all, acc) do
    cond do
      String.starts_with?(line, "#") -> {Enum.reverse(acc), all}
      String.starts_with?(line, "```") -> {Enum.reverse(acc), all}
      bullet_line?(line) or ordered_line?(line) -> {Enum.reverse(acc), all}
      blockquote_line?(line) -> {Enum.reverse(acc), all}
      true -> take_paragraph(rest, [line | acc])
    end
  end

  # ---- block renderers --------------------------------------------------

  defp render_block({:heading, level, text}) do
    tag = "h#{level}"
    classes = heading_classes(level)
    ~s|<#{tag} class="#{classes}">#{inline(text)}</#{tag}>|
  end

  defp render_block({:code, lang, lines}) do
    body = lines |> Enum.join("\n") |> escape()
    lang_class = if lang == "", do: "", else: " language-#{escape(lang)}"

    ~s|<pre class="rounded bg-base-300 p-3 overflow-x-auto text-xs"><code class="#{lang_class}">#{body}</code></pre>|
  end

  defp render_block({:list, kind, items}) do
    tag = if kind == :ul, do: "ul", else: "ol"
    classes = if kind == :ul, do: "list-disc", else: "list-decimal"

    rendered =
      items
      |> Enum.map(fn item -> "<li>#{inline(item)}</li>" end)
      |> Enum.join()

    ~s|<#{tag} class="#{classes} pl-6 space-y-1">#{rendered}</#{tag}>|
  end

  defp render_block({:blockquote, lines}) do
    body = lines |> Enum.join(" ") |> inline()

    ~s|<blockquote class="border-l-4 border-base-300 pl-3 italic opacity-80">#{body}</blockquote>|
  end

  defp render_block({:paragraph, lines}) do
    body = lines |> Enum.join(" ") |> inline()
    ~s|<p>#{body}</p>|
  end

  defp heading_classes(1), do: "text-3xl font-semibold mt-6 mb-2"
  defp heading_classes(2), do: "text-2xl font-semibold mt-6 mb-2"
  defp heading_classes(3), do: "text-xl font-semibold mt-4 mb-1"
  defp heading_classes(_), do: "text-lg font-semibold mt-3 mb-1"

  # ---- inline -----------------------------------------------------------

  defp inline(text) do
    text
    |> escape()
    |> apply_inline_code()
    |> apply_bold()
    |> apply_links()
  end

  defp apply_inline_code(text) do
    Regex.replace(~r/`([^`]+)`/, text, ~s|<code class="px-1 rounded bg-base-300">\\1</code>|)
  end

  defp apply_bold(text) do
    Regex.replace(~r/\*\*([^*]+)\*\*/, text, "<strong>\\1</strong>")
  end

  defp apply_links(text) do
    text
    |> then(fn t ->
      Regex.replace(~r/\[([^\]]+)\]\(([^)\s]+)\)/, t, fn _full, label, href ->
        ~s|<a href="#{href}" class="link">#{label}</a>|
      end)
    end)
    |> then(fn t ->
      Regex.replace(~r/&lt;(https?:\/\/[^\s&]+)&gt;/, t, ~s|<a href="\\1" class="link">\\1</a>|)
    end)
  end

  # Escape HTML special chars. We use this on raw markdown content before
  # any of our own tag insertions so user content can never become markup.
  defp escape(text) do
    text
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end
end
