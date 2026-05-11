defmodule Interview.Templates.QuestionTest do
  use Interview.DataCase, async: true

  alias Interview.Fixtures
  alias Interview.Templates.Question

  describe "changeset/2 asset references" do
    setup do
      tenant = Fixtures.tenant!()
      template = Fixtures.template!(tenant.id)
      version = Fixtures.version!(template.id)
      {:ok, tenant: tenant, template: template, version: version}
    end

    test "accepts a question with no asset references", %{version: v} do
      attrs = %{
        template_version_id: v.id,
        position: 1,
        prompt_text: "Q"
      }

      assert {:ok, _} =
               %Question{} |> Question.changeset(attrs) |> Repo.insert()
    end

    test "accepts a ready prompt asset owned by the same tenant",
         %{tenant: t, version: v} do
      asset = Fixtures.prompt_asset!(t.id, %{state: "ready"})

      attrs = %{
        template_version_id: v.id,
        position: 1,
        prompt_text: "Q",
        prompt_asset_id: asset.id
      }

      assert {:ok, q} =
               %Question{} |> Question.changeset(attrs) |> Repo.insert()

      assert q.prompt_asset_id == asset.id
    end

    test "rejects a non-existent prompt_asset_id", %{version: v} do
      attrs = %{
        template_version_id: v.id,
        position: 1,
        prompt_text: "Q",
        prompt_asset_id: Ecto.UUID.generate()
      }

      cs = Question.changeset(%Question{}, attrs)
      refute cs.valid?
      assert "does not exist" in errors_on(cs).prompt_asset_id
    end

    test "rejects a prompt_asset owned by a different tenant", %{version: v} do
      other_tenant = Fixtures.tenant!()
      asset = Fixtures.prompt_asset!(other_tenant.id, %{state: "ready"})

      attrs = %{
        template_version_id: v.id,
        position: 1,
        prompt_text: "Q",
        prompt_asset_id: asset.id
      }

      cs = Question.changeset(%Question{}, attrs)
      refute cs.valid?
      assert "belongs to a different tenant" in errors_on(cs).prompt_asset_id
    end

    test "rejects a non-ready prompt_asset", %{tenant: t, version: v} do
      asset = Fixtures.prompt_asset!(t.id, %{state: "pending", storage_key: nil})

      attrs = %{
        template_version_id: v.id,
        position: 1,
        prompt_text: "Q",
        prompt_asset_id: asset.id
      }

      cs = Question.changeset(%Question{}, attrs)
      refute cs.valid?

      [msg] = errors_on(cs).prompt_asset_id
      assert msg =~ "is not ready"
    end

    test "validates attachment_asset_id with the same rules", %{tenant: t, version: v} do
      pending =
        Fixtures.prompt_asset!(t.id, %{
          kind: "image",
          state: "pending",
          storage_key: nil
        })

      attrs = %{
        template_version_id: v.id,
        position: 1,
        prompt_text: "Q",
        attachment_asset_id: pending.id
      }

      cs = Question.changeset(%Question{}, attrs)
      refute cs.valid?
      [msg] = errors_on(cs).attachment_asset_id
      assert msg =~ "is not ready"
    end
  end
end
