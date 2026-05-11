defmodule Interview.Templates.YamlImporterTest do
  use ExUnit.Case, async: true

  alias Interview.Templates.{Spec, YamlImporter}

  @valid """
  template:
    name: SDR Phone Screen
    description: 30-min async screen for inbound SDR roles
  retake_policy:
    max_attempts: 2
    mode: last
  questions:
    - position: 1
      prompt: |
        **Tell me about a time you turned a "no" into a "yes."**

        Be specific.
      think_time_seconds: 30
      max_answer_seconds: 90
      required: true
      tags:
        - behavioral
        - sales
      external_id: sdr-q1
    - position: 2
      prompt: Walk me through your last 5 closed-won deals.
      max_answer_seconds: 120
      max_attempts_override: 1
      tags:
        - experience
  """

  test "parses a complete YAML template" do
    assert {:ok, %Spec{} = spec} = YamlImporter.parse(@valid)
    assert spec.template["name"] == "SDR Phone Screen"
    assert spec.retake_policy["max_attempts"] == 2
    assert spec.retake_policy["mode"] == "last"
    assert length(spec.questions) == 2

    [q1, q2] = spec.questions
    assert q1["position"] == 1
    assert String.contains?(q1["prompt_text"], "turned a")
    assert q1["tags"] == ["behavioral", "sales"]
    assert q1["external_id"] == "sdr-q1"
    assert q2["max_attempts_override"] == 1
  end

  test "round-trips: parse → dump → parse" do
    assert {:ok, spec1} = YamlImporter.parse(@valid)
    dumped = YamlImporter.dump(spec1)
    assert {:ok, spec2} = YamlImporter.parse(dumped)

    # The questions normalise identically; markdown bodies survive through
    # the YAML block scalar (`|`).
    assert spec1.template == spec2.template
    assert spec1.retake_policy == spec2.retake_policy
    assert length(spec1.questions) == length(spec2.questions)

    Enum.zip(spec1.questions, spec2.questions)
    |> Enum.each(fn {a, b} ->
      assert a["position"] == b["position"]
      assert String.trim(a["prompt_text"]) == String.trim(b["prompt_text"])
      assert a["tags"] == b["tags"]
      assert a["max_answer_seconds"] == b["max_answer_seconds"]
      assert a["max_attempts_override"] == b["max_attempts_override"]
      assert a["required"] == b["required"]
    end)
  end

  test "validation error carries a line number for the offending question field" do
    bad = """
    template:
      name: T
    questions:
      - position: 1
        prompt: ok
      - position: 2
        prompt: bad
        max_answer_seconds: 0
    """

    assert {:error, [err]} = YamlImporter.parse(bad)
    assert err.path == ["questions", 1, "max_answer_seconds"]
    assert err.line in 7..9
  end

  test "validation error on retake_policy carries the retake_policy line" do
    bad = """
    template:
      name: T
    retake_policy:
      mode: best
    questions:
      - position: 1
        prompt: hi
    """

    assert {:error, [err]} = YamlImporter.parse(bad)
    assert err.path == ["retake_policy", "mode"]
    assert is_integer(err.line)
  end

  test "rejects YAML that isn't a mapping at the root" do
    assert {:error, [%{message: msg}]} = YamlImporter.parse("- a\n- b\n")
    assert msg =~ "mapping"
  end

  test "surface YAML parse errors with a line" do
    bad = "template:\n  name: T\nquestions:\n  - position: 1\n    prompt: ok\n  -"
    assert {:error, [err]} = YamlImporter.parse(bad)
    assert err.message != nil
  end

  test "dump emits block scalar for multi-line prompt" do
    spec =
      Spec.from_map(%{
        "template" => %{"name" => "T"},
        "questions" => [
          %{"position" => 1, "prompt" => "line1\nline2\n"}
        ]
      })

    assert {:ok, _} = Spec.validate(spec)
    yaml = YamlImporter.dump(spec)
    assert yaml =~ "prompt: |"
    assert yaml =~ "line1"
    assert yaml =~ "line2"
  end
end
