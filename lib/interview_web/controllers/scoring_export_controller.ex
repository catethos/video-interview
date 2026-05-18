defmodule InterviewWeb.ScoringExportController do
  @moduledoc """
  Server-to-server read of a completed interview, shaped for a downstream
  scoring pipeline (PLAN §8.5 change 2).

  Route:

    * `GET /api/sessions/:id/scoring_export`

  Authenticated via `InterviewWeb.Plugs.TenantAuth` — accepts either a
  tenant API key (`tk_*`) or a recruiter bearer (`rk_*`). The session
  must belong to the caller's tenant and be in the `ready` state
  (finalizer complete). Returns the flat Q+A array a scoring pipeline
  consumes — see `Interview.ExternalIntegration.ScoringExport` for the
  payload contract.
  """
  use InterviewWeb, :controller

  alias Interview.ExternalIntegration.ScoringExport

  def show(conn, %{"id" => session_id}) do
    tenant = conn.assigns.tenant

    case ScoringExport.build(tenant.id, session_id) do
      {:ok, payload} ->
        json(conn, render_payload(payload))

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "session_not_found"})

      {:error, :not_ready} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error: "session_not_ready",
          hint:
            "the session has not finalized yet; wait for the session.ready webhook before retrying"
        })
    end
  end

  # JSON encoder hint: dates render as ISO 8601 strings; transcript
  # entries stay a list of maps with snake_case keys (matches the
  # ViScoringExport contract in pulsifi-demo's shared types).
  defp render_payload(p) do
    %{
      session_id: p.session_id,
      external_id: p.external_id,
      tenant_id: p.tenant_id,
      candidate_email: p.candidate_email,
      completed_at: p.completed_at,
      state: p.state,
      interview_transcript: p.interview_transcript
    }
  end
end
