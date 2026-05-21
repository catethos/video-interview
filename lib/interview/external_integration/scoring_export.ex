defmodule Interview.ExternalIntegration.ScoringExport do
  @moduledoc """
  Assembles the JSON payload returned by
  `GET /api/sessions/:id/scoring_export` (PLAN §8.5 change 2).

  Downstream scoring pipelines (e.g. the lattice runner inside Pulsifi)
  need a flat, per-question Q+A array. This module joins
  `template_questions` (the prompt) with the canonical
  `question_responses` row (the candidate's answer + transcript) for
  each `session_questions` slot, ordered by position.

  Tenant scoping is mandatory: a session that does not belong to the
  caller's tenant returns `{:error, :not_found}`. Sessions that exist
  but haven't been finalized yet return `{:error, :not_ready}` — the
  caller should wait for a `session.ready` webhook before retrying.
  """

  alias Interview.Capture.Session
  alias Interview.Playback

  @type payload :: %{
          session_id: String.t(),
          external_id: String.t() | nil,
          tenant_id: String.t(),
          candidate_email: String.t() | nil,
          completed_at: DateTime.t() | nil,
          state: String.t(),
          interview_transcript: [transcript_entry()]
        }

  @type transcript_entry :: %{
          question_number: pos_integer(),
          question_text: String.t(),
          answer_text: String.t() | nil,
          response_id: String.t() | nil,
          duration_ms: non_neg_integer() | nil,
          focus_lost_count: non_neg_integer(),
          focus_lost_total_ms: non_neg_integer()
        }

  @doc """
  Build the export payload for a session.

  Returns:
    * `{:ok, payload}` — session exists, belongs to tenant, is finalized
    * `{:error, :not_found}` — no such session, or wrong tenant
    * `{:error, :not_ready}` — session exists but is not yet in `ready` state
  """
  @spec build(String.t(), String.t()) ::
          {:ok, payload()} | {:error, :not_found | :not_ready}
  def build(tenant_id, session_id) when is_binary(tenant_id) and is_binary(session_id) do
    case Playback.get_session(tenant_id, session_id) do
      nil ->
        {:error, :not_found}

      %{session: %Session{state: "ready"} = session, questions: question_cards} ->
        if transcripts_ready?(question_cards) do
          {:ok,
           %{
             session_id: session.id,
             external_id: session.external_id,
             tenant_id: session.tenant_id,
             candidate_email: session.candidate_email,
             completed_at: session.completed_at,
             state: session.state,
             interview_transcript: Enum.map(question_cards, &transcript_entry/1)
           }}
        else
          # Session is finalized but the async Whisper jobs haven't all
          # landed yet. Without this guard, a caller racing the
          # session.ready webhook can read answer_text: nil for any
          # question whose transcript is still pending.
          {:error, :not_ready}
        end

      %{session: %Session{}} ->
        {:error, :not_ready}
    end
  end

  # Two final states per question:
  #   * `selected_response: nil`  → the candidate skipped or never answered.
  #     The question is final, just empty. Treat as ready.
  #   * `selected_response: %Response{transcript_ready_at: t}` with t != nil
  #     → the answer's Whisper transcript landed. Ready.
  # Any other shape (an existing response whose transcript hasn't landed
  # yet) means we're racing the async transcription job; report not_ready
  # so the caller retries.
  defp transcripts_ready?(question_cards) do
    Enum.all?(question_cards, fn
      %{selected_response: nil} -> true
      %{selected_response: %{transcript_ready_at: t}} when not is_nil(t) -> true
      _ -> false
    end)
  end

  defp transcript_entry(%{
         template_question: q,
         selected_response: selected_response
       }) do
    %{count: focus_count, total_ms: focus_total_ms} =
      case selected_response do
        %{id: rid} -> Interview.Capture.focus_loss_summary(rid)
        _ -> %{count: 0, total_ms: 0}
      end

    %{
      question_number: q.position,
      question_text: q.prompt_text,
      answer_text: selected_response && selected_response.transcript_text,
      response_id: selected_response && selected_response.id,
      duration_ms: selected_response && selected_response.duration_ms,
      focus_lost_count: focus_count,
      focus_lost_total_ms: focus_total_ms
    }
  end
end
