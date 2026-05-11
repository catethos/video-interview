defmodule InterviewWeb.MarkdownTest do
  use ExUnit.Case, async: true

  alias InterviewWeb.Markdown

  defp render(md), do: md |> Markdown.to_html() |> Phoenix.HTML.safe_to_string()

  test "renders ATX headings at the right level" do
    assert render("# top") =~ ~s|<h1 class="text-3xl|
    assert render("## sub") =~ ~s|<h2 class="text-2xl|
    assert render("### subsub") =~ ~s|<h3 class="text-xl|
  end

  test "renders fenced code blocks with the language class" do
    md = "```elixir\nIO.puts(1)\n```"
    html = render(md)
    assert html =~ ~s|<pre class="rounded|
    assert html =~ ~s|class=" language-elixir"|
    assert html =~ "IO.puts(1)"
  end

  test "renders unordered and ordered lists" do
    assert render("- one\n- two") =~ "<ul"
    assert render("- one\n- two") =~ "<li>one</li>"
    assert render("1. one\n2. two") =~ "<ol"
  end

  test "applies inline code, bold, and links" do
    html = render("Use `mix test`. **Important** [docs](https://example.com).")
    assert html =~ "<code"
    assert html =~ "<strong>Important</strong>"
    assert html =~ ~s|<a href="https://example.com" class="link">docs</a>|
  end

  test "escapes raw HTML in source" do
    html = render("Look: <script>alert(1)</script>")
    refute html =~ "<script>"
    assert html =~ "&lt;script&gt;"
  end

  test "renders blockquotes" do
    assert render("> note me") =~ "<blockquote"
  end

  test "renders paragraphs separated by blank lines" do
    html = render("first\n\nsecond")
    assert html =~ "<p>first</p>"
    assert html =~ "<p>second</p>"
  end
end
