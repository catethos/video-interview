defmodule Interview.Scoring.TemplateClassificationTest do
  use Interview.DataCase, async: true

  alias Interview.Fixtures
  alias Interview.Scoring.TemplateClassification

  defp version! do
    tenant = Fixtures.tenant!()
    template = Fixtures.template!(tenant.id)
    Fixtures.version!(template.id)
  end

  defp valid_attrs(template_version_id, overrides \\ %{}) do
    Map.merge(
      %{
        template_version_id: template_version_id,
        pipeline_version: "smoke_test_Pipeline_2_2026-05-25-0423",
        provider: "google/gemini-2.5-flash",
        result: %{"classifications" => [%{"question_number" => 1}]},
        computed_at: DateTime.utc_now()
      },
      overrides
    )
  end

  describe "changeset/2" do
    test "accepts a classification with a result map" do
      version = version!()

      assert {:ok, classification} =
               %TemplateClassification{}
               |> TemplateClassification.changeset(valid_attrs(version.id))
               |> Repo.insert()

      assert classification.provider == "google/gemini-2.5-flash"
      assert classification.result["classifications"] == [%{"question_number" => 1}]
    end

    test "accepts a missing provider (it is optional)" do
      version = version!()
      attrs = valid_attrs(version.id, %{provider: nil})

      assert {:ok, _} =
               %TemplateClassification{}
               |> TemplateClassification.changeset(attrs)
               |> Repo.insert()
    end

    test "requires template_version_id, pipeline_version, result, computed_at" do
      cs = TemplateClassification.changeset(%TemplateClassification{}, %{})
      refute cs.valid?

      errors = errors_on(cs)
      assert "can't be blank" in errors.template_version_id
      assert "can't be blank" in errors.pipeline_version
      assert "can't be blank" in errors.result
      assert "can't be blank" in errors.computed_at
    end

    test "is unique on (template_version_id, pipeline_version)" do
      version = version!()

      assert {:ok, _} =
               %TemplateClassification{}
               |> TemplateClassification.changeset(valid_attrs(version.id))
               |> Repo.insert()

      assert {:error, cs} =
               %TemplateClassification{}
               |> TemplateClassification.changeset(valid_attrs(version.id))
               |> Repo.insert()

      assert "has already been taken" in errors_on(cs).template_version_id
    end

    test "allows the same template version under a different pipeline_version" do
      version = version!()

      assert {:ok, _} =
               %TemplateClassification{}
               |> TemplateClassification.changeset(valid_attrs(version.id))
               |> Repo.insert()

      attrs =
        valid_attrs(version.id, %{pipeline_version: "smoke_test_Pipeline_3_2026-06-01-0900"})

      assert {:ok, _} =
               %TemplateClassification{}
               |> TemplateClassification.changeset(attrs)
               |> Repo.insert()
    end
  end
end
