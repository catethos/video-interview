defmodule Interview.Repo.Migrations.RestrictTemplateQuestionAssetFks do
  use Ecto.Migration

  # Switch prompt_asset_id / attachment_asset_id from ON DELETE SET NULL to
  # ON DELETE RESTRICT. A published template_version is meant to be immutable
  # (PLAN §3.2): silently nilling out a referenced asset on delete is the
  # same kind of mid-flight mutation §3.4 forbids on the row itself, and
  # would leave a candidate staring at a question whose video prompt
  # vanished. RESTRICT forces the caller (the not-yet-wired
  # PromptAssets.delete/2) to either soft-archive the asset or detach it
  # from every referencing question first.
  def change do
    alter table(:template_questions) do
      modify :prompt_asset_id,
             references(:prompt_assets, type: :binary_id, on_delete: :restrict),
             from: references(:prompt_assets, type: :binary_id, on_delete: :nilify_all)

      modify :attachment_asset_id,
             references(:prompt_assets, type: :binary_id, on_delete: :restrict),
             from: references(:prompt_assets, type: :binary_id, on_delete: :nilify_all)
    end
  end
end
