defmodule Interview.Workers.AbandonedPromptAssetSweeperTest do
  use Interview.DataCase, async: false

  use Oban.Testing, repo: Interview.Repo

  alias Interview.PromptAssets
  alias Interview.Repo
  alias Interview.Templates.PromptAsset
  alias Interview.Workers.AbandonedPromptAssetSweeper

  test "marks stale non-terminal assets as abandoned" do
    tenant = Interview.Fixtures.tenant!()
    {:ok, stale, _} = PromptAssets.create_recording(tenant.id, %{kind: "video"})
    {:ok, fresh, _} = PromptAssets.create_recording(tenant.id, %{kind: "video"})

    long_ago = NaiveDateTime.add(NaiveDateTime.utc_now(), -5 * 60 * 60, :second)
    just_now = NaiveDateTime.add(NaiveDateTime.utc_now(), -1, :second)

    {1, _} =
      from(a in PromptAsset, where: a.id == ^stale.id)
      |> Repo.update_all(set: [inserted_at: long_ago])

    {1, _} =
      from(a in PromptAsset, where: a.id == ^fresh.id)
      |> Repo.update_all(set: [inserted_at: just_now])

    assert :ok = perform_job(AbandonedPromptAssetSweeper, %{})

    assert Repo.get!(PromptAsset, stale.id).state == "abandoned"
    assert Repo.get!(PromptAsset, fresh.id).state == "recording"
  end

  test "ignores already-terminal assets" do
    tenant = Interview.Fixtures.tenant!()
    asset = Interview.Fixtures.prompt_asset!(tenant.id, %{state: "ready"})

    long_ago = NaiveDateTime.add(NaiveDateTime.utc_now(), -5 * 60 * 60, :second)

    {1, _} =
      from(a in PromptAsset, where: a.id == ^asset.id)
      |> Repo.update_all(set: [inserted_at: long_ago])

    assert :ok = perform_job(AbandonedPromptAssetSweeper, %{})
    assert Repo.get!(PromptAsset, asset.id).state == "ready"
  end
end
