defmodule Interview.Repo.Migrations.AddCaptionColumnsToPromptAssets do
  use Ecto.Migration

  def change do
    alter table(:prompt_assets) do
      # Canonical storage key of the .vtt caption file generated for
      # this prompt video. Null until the async Whisper caption worker
      # finishes. Image/PDF assets never populate this — they have no
      # audio to caption.
      add :caption_storage_key, :string
      # Provider that produced the captions (e.g. "openai-whisper-1").
      # Recorded so we can re-run with a different provider later
      # without losing the audit trail.
      add :caption_provider, :string
      # When the captions landed. Mirrors `transcript_ready_at` on
      # question_responses — both nil + late population means the
      # candidate page can render a "captions loading" hint instead
      # of an empty <track>.
      add :caption_ready_at, :utc_datetime_usec
    end
  end
end
