defmodule Interview.Templates.MarkdownImporterTest do
  use ExUnit.Case, async: true

  alias Interview.Templates.{MarkdownImporter, Spec}

  @valid """
  ---
  template: SDR Phone Screen
  retake_policy: { max_attempts: 2, mode: last }
  ---

  ---
  position: 1
  think_time_seconds: 30
  max_answer_seconds: 90
  required: true
  tags: [behavioral, sales]
  external_id: sdr-q1
  ---

  **Tell me about a time you turned a "no" into a "yes."**

  Be specific — name the prospect, the objection, what you did.

  ---
  position: 2
  max_answer_seconds: 120
  max_attempts_override: 1
  tags: [experience]
  ---

  Walk me through your last 5 closed-won deals.
  """

  test "parses markdown-with-frontmatter into the same spec shape as YAML" do
    assert {:ok, %Spec{} = spec} = MarkdownImporter.parse(@valid)
    assert spec.template["name"] == "SDR Phone Screen"
    assert spec.retake_policy["mode"] == "last"
    assert spec.retake_policy["max_attempts"] == 2
    assert length(spec.questions) == 2

    [q1, q2] = spec.questions
    assert q1["position"] == 1
    assert String.contains?(q1["prompt_text"], "turned a")
    assert q1["tags"] == ["behavioral", "sales"]
    assert q1["external_id"] == "sdr-q1"
    assert q2["position"] == 2
    assert String.contains?(q2["prompt_text"], "closed-won")
  end

  test "supports an explicit `template:` mapping form" do
    src = """
    ---
    template:
      name: ACME
      description: Hello
    ---

    ---
    position: 1
    ---

    Hi
    """

    assert {:ok, spec} = MarkdownImporter.parse(src)
    assert spec.template["name"] == "ACME"
    assert spec.template["description"] == "Hello"
  end

  test "validation errors carry a line number near the offending field" do
    bad = """
    ---
    template: T
    ---

    ---
    position: 1
    max_answer_seconds: 0
    ---

    Hello
    """

    assert {:error, [err]} = MarkdownImporter.parse(bad)
    assert err.path == ["questions", 0, "max_answer_seconds"]
    assert is_integer(err.line)
  end

  test "missing prompt body produces a prompt_text validation error" do
    bad = """
    ---
    template: T
    ---

    ---
    position: 1
    ---
    """

    assert {:error, [err]} = MarkdownImporter.parse(bad)
    assert err.path == ["questions", 0, "prompt_text"]
  end

  test "missing closing delimiter is reported" do
    bad = """
    ---
    template: T
    ---

    ---
    position: 1
    """

    assert {:error, [err]} = MarkdownImporter.parse(bad)
    assert err.message =~ "unmatched"
  end
end
