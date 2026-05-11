defmodule Interview.TemplatesTest do
  use Interview.DataCase, async: false

  alias Interview.Fixtures
  alias Interview.Templates
  alias Interview.Templates.{Question, Spec, YamlImporter}

  describe "create_draft_version/1" do
    test "clones questions from the current_version" do
      tenant = Fixtures.tenant!()
      template = Fixtures.template!(tenant.id)
      v1 = Fixtures.version!(template.id, %{version_number: 1})

      _q1 = Fixtures.question!(v1.id, 1, %{prompt_text: "Q1"})
      _q2 = Fixtures.question!(v1.id, 2, %{prompt_text: "Q2"})

      {:ok, _} =
        Templates.publish_draft(v1)

      template = Templates.get_template!(template.id)
      assert template.current_version_id == v1.id

      {:ok, draft} = Templates.create_draft_version(template)
      assert draft.id != v1.id
      assert is_nil(draft.published_at)

      cloned = Templates.list_questions(draft)
      assert Enum.map(cloned, & &1.prompt_text) == ["Q1", "Q2"]
      # Cloned rows are fresh ids, not aliases of the originals.
      original_ids =
        Repo.all(from q in Question, where: q.template_version_id == ^v1.id, select: q.id)
        |> MapSet.new()

      cloned_ids = MapSet.new(Enum.map(cloned, & &1.id))
      assert MapSet.disjoint?(original_ids, cloned_ids)
    end

    test "is idempotent: a second call returns the same draft" do
      tenant = Fixtures.tenant!()
      template = Fixtures.template!(tenant.id)
      {:ok, draft1} = Templates.create_draft_version(template)
      {:ok, draft2} = Templates.create_draft_version(template)
      assert draft1.id == draft2.id
    end
  end

  describe "publish_draft/1" do
    test "stamps published_at, flips current_version_id, and the prior version is no longer mutable" do
      tenant = Fixtures.tenant!()
      template = Fixtures.template!(tenant.id)
      v1 = Fixtures.version!(template.id, %{version_number: 1})
      _q = Fixtures.question!(v1.id, 1, %{prompt_text: "Q"})

      {:ok, published} = Templates.publish_draft(v1)
      assert published.published_at

      template = Templates.get_template!(template.id)
      assert template.current_version_id == published.id

      # editing the published version is rejected
      assert {:error, :published_immutable} =
               Templates.update_draft_questions(published, [%{"prompt_text" => "X"}])
    end

    test "publishing a draft preserves frozen template_version_id on existing sessions" do
      tenant = Fixtures.tenant!()
      template = Fixtures.template!(tenant.id)
      v1 = Fixtures.version!(template.id, %{version_number: 1})
      _q = Fixtures.question!(v1.id, 1, %{prompt_text: "Q1"})
      {:ok, _} = Templates.publish_draft(v1)

      session = Fixtures.session!(tenant.id, v1.id)

      {:ok, draft} = Templates.create_draft_version(Templates.get_template!(template.id))

      Templates.update_draft_question(hd(Templates.list_questions(draft)), %{
        prompt_text: "edited"
      })

      {:ok, _v2} = Templates.publish_draft(draft)

      reloaded = Repo.get!(Interview.Capture.Session, session.id)
      assert reloaded.template_version_id == v1.id
    end

    test "rejects re-publishing an already-published version" do
      tenant = Fixtures.tenant!()
      template = Fixtures.template!(tenant.id)
      v1 = Fixtures.version!(template.id, %{version_number: 1})
      _q = Fixtures.question!(v1.id, 1, %{prompt_text: "Q"})
      {:ok, published} = Templates.publish_draft(v1)
      assert {:error, :already_published} = Templates.publish_draft(published)
    end
  end

  describe "reorder_draft_questions/2" do
    test "swaps question positions" do
      tenant = Fixtures.tenant!()
      template = Fixtures.template!(tenant.id)
      v = Fixtures.version!(template.id, %{version_number: 1})
      q1 = Fixtures.question!(v.id, 1)
      q2 = Fixtures.question!(v.id, 2)
      q3 = Fixtures.question!(v.id, 3)

      {:ok, reordered} = Templates.reorder_draft_questions(v, [q3.id, q1.id, q2.id])
      ids_in_order = Enum.sort_by(reordered, & &1.position) |> Enum.map(& &1.id)
      assert ids_in_order == [q3.id, q1.id, q2.id]
    end
  end

  describe "apply_spec_to_draft/2" do
    test "replaces the question list and updates retake_policy from a Spec" do
      tenant = Fixtures.tenant!()
      template = Fixtures.template!(tenant.id)
      {:ok, draft} = Templates.create_draft_version(template)

      spec =
        Spec.from_map(%{
          "template" => %{"name" => "ignored at apply time"},
          "retake_policy" => %{"max_attempts" => 3, "mode" => "last"},
          "questions" => [
            %{"position" => 1, "prompt" => "Q1", "max_answer_seconds" => 60},
            %{"position" => 2, "prompt" => "Q2", "required" => false}
          ]
        })

      assert {:ok, _spec} = Spec.validate(spec)
      assert {:ok, %{version: v, questions: qs}} = Templates.apply_spec_to_draft(draft, spec)
      assert v.retake_policy["max_attempts"] == 3
      assert v.retake_policy["mode"] == "last"
      assert Enum.map(qs, & &1.prompt_text) == ["Q1", "Q2"]
      assert Enum.map(qs, & &1.required) == [true, false]
    end
  end

  describe "version_to_spec / YAML round-trip" do
    test "a published version can be dumped and re-imported" do
      tenant = Fixtures.tenant!()
      template = Fixtures.template!(tenant.id, %{name: "T", description: "D"})

      v =
        Fixtures.version!(template.id, %{
          version_number: 1,
          retake_policy: %{"max_attempts" => 2, "mode" => "last"}
        })

      _ =
        Fixtures.question!(v.id, 1, %{
          prompt_text: "First **q** with markdown.\n\nMore.",
          tags: ["a", "b"]
        })

      _ = Fixtures.question!(v.id, 2, %{prompt_text: "Second", required: false})

      spec1 = Templates.version_to_spec(v)
      yaml = YamlImporter.dump(spec1)
      assert {:ok, spec2} = YamlImporter.parse(yaml)

      assert spec1.template["name"] == spec2.template["name"]
      assert length(spec1.questions) == length(spec2.questions)
      assert hd(spec1.questions)["tags"] == hd(spec2.questions)["tags"]
    end
  end

  describe "candidate-flow compatibility" do
    test "a session created against a published version still drives the candidate flow" do
      tenant = Fixtures.tenant!()
      template = Fixtures.template!(tenant.id)
      v = Fixtures.version!(template.id, %{version_number: 1})
      _ = Fixtures.question!(v.id, 1, %{prompt_text: "Q1", required: true})
      _ = Fixtures.question!(v.id, 2, %{prompt_text: "Q2", required: false})
      {:ok, _} = Templates.publish_draft(v)

      session = Fixtures.session!(tenant.id, v.id)

      # Capture context still resolves the questions and retake-policy
      # off the session's frozen template_version_id (PLAN §3.2/§3.4).
      assert Interview.Capture.list_questions(session) |> length() == 2
      version = Interview.Capture.get_template_version!(session)
      assert version.id == v.id
    end
  end
end
