defmodule Interview.Templates.VersionTest do
  use Interview.DataCase, async: true

  alias Interview.Fixtures
  alias Interview.Templates.Version

  defp template! do
    tenant = Fixtures.tenant!()
    Fixtures.template!(tenant.id)
  end

  describe "changeset/2 — randomize_questions" do
    test "defaults to false when not provided" do
      template = template!()

      assert {:ok, v} =
               %Version{}
               |> Version.changeset(%{template_id: template.id, version_number: 1})
               |> Repo.insert()

      assert v.randomize_questions == false
    end

    test "casts true" do
      template = template!()

      assert {:ok, v} =
               %Version{}
               |> Version.changeset(%{
                 template_id: template.id,
                 version_number: 1,
                 randomize_questions: true
               })
               |> Repo.insert()

      assert v.randomize_questions == true
    end
  end
end
