defmodule Interview.Templates.SpecTest do
  use ExUnit.Case, async: true

  alias Interview.Templates.Spec

  describe "validate/1" do
    test "passes a minimal valid spec" do
      spec =
        Spec.from_map(%{
          "template" => %{"name" => "T"},
          "questions" => [%{"position" => 1, "prompt" => "Hi"}]
        })

      assert {:ok, ^spec} = Spec.validate(spec)
    end

    test "requires template.name" do
      spec = Spec.from_map(%{"questions" => [%{"position" => 1, "prompt" => "Hi"}]})
      assert {:error, errors} = Spec.validate(spec)
      assert Enum.any?(errors, &(&1.path == ["template", "name"]))
    end

    test "requires at least one question" do
      spec = Spec.from_map(%{"template" => %{"name" => "T"}})
      assert {:error, errors} = Spec.validate(spec)
      assert Enum.any?(errors, &(&1.path == ["questions"]))
    end

    test "rejects duplicate positions" do
      spec =
        Spec.from_map(%{
          "template" => %{"name" => "T"},
          "questions" => [
            %{"position" => 1, "prompt" => "a"},
            %{"position" => 1, "prompt" => "b"}
          ]
        })

      assert {:error, errors} = Spec.validate(spec)
      assert Enum.any?(errors, &(&1.path == ["questions", 0, "position"]))
      assert Enum.any?(errors, &(&1.path == ["questions", 1, "position"]))
    end

    test "rejects duplicate external_ids" do
      spec =
        Spec.from_map(%{
          "template" => %{"name" => "T"},
          "questions" => [
            %{"position" => 1, "prompt" => "a", "external_id" => "x"},
            %{"position" => 2, "prompt" => "b", "external_id" => "x"}
          ]
        })

      assert {:error, errors} = Spec.validate(spec)
      assert Enum.any?(errors, &(&1.path == ["questions", 0, "external_id"]))
    end

    test "rejects unknown retake mode" do
      spec =
        Spec.from_map(%{
          "template" => %{"name" => "T"},
          "retake_policy" => %{"mode" => "best"},
          "questions" => [%{"position" => 1, "prompt" => "Hi"}]
        })

      assert {:error, errors} = Spec.validate(spec)
      assert Enum.any?(errors, &(&1.path == ["retake_policy", "mode"]))
    end

    test "rejects min_answer_seconds > max_answer_seconds" do
      spec =
        Spec.from_map(%{
          "template" => %{"name" => "T"},
          "questions" => [
            %{
              "position" => 1,
              "prompt" => "Hi",
              "min_answer_seconds" => 90,
              "max_answer_seconds" => 30
            }
          ]
        })

      assert {:error, errors} = Spec.validate(spec)
      assert Enum.any?(errors, &(&1.path == ["questions", 0, "min_answer_seconds"]))
    end

    test "rejects non-positive integer fields" do
      spec =
        Spec.from_map(%{
          "template" => %{"name" => "T"},
          "questions" => [
            %{
              "position" => 1,
              "prompt" => "Hi",
              "max_answer_seconds" => 0
            }
          ]
        })

      assert {:error, errors} = Spec.validate(spec)
      assert Enum.any?(errors, &(&1.path == ["questions", 0, "max_answer_seconds"]))
    end

    test "rejects non-list tags" do
      spec =
        Spec.from_map(%{
          "template" => %{"name" => "T"},
          "questions" => [
            %{"position" => 1, "prompt" => "Hi", "tags" => "behavioral"}
          ]
        })

      assert {:error, errors} = Spec.validate(spec)
      assert Enum.any?(errors, &(&1.path == ["questions", 0, "tags"]))
    end
  end

  describe "path_to_json_pointer/1" do
    test "renders simple paths" do
      assert Spec.path_to_json_pointer(["questions", 0, "prompt_text"]) ==
               "/questions/0/prompt_text"
    end

    test "escapes ~ and / per RFC 6901" do
      assert Spec.path_to_json_pointer(["a/b", "c~d"]) == "/a~1b/c~0d"
    end
  end
end
