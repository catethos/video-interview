defmodule InterviewWeb.PromptAssetAttachmentController do
  @moduledoc """
  Single-shot multipart endpoint for recruiter-authored image/PDF
  attachments on a `template_question` (PLAN §3.4 recruiter prompts).

  Skips the tus + finalizer pipeline — the file is small, lands once,
  and the row is inserted directly as `ready`. The candidate-side
  prompt-recording pipeline (`/uploads/prompt_assets/...`) is reserved
  for video/audio.

      POST /recruiter/templates/:tid/questions/:qid/attachment
        multipart/form-data with one `attachment` field

  Returns:

    * 200 — `{ok: true, promptAssetId, kind}`; the question's
      `attachment_asset_id` has been pointed at the new row.
    * 401 — recruiter session missing/invalid.
    * 403 — template not owned by the recruiter's tenant.
    * 404 — template/question not found.
    * 422 — bad MIME, oversized file, draft published.
  """
  use InterviewWeb, :controller

  alias Interview.PromptAssets
  alias Interview.Repo
  alias Interview.Storage
  alias Interview.Templates
  alias Interview.Templates.{Question, Template}

  @max_bytes 25 * 1024 * 1024

  @kinds %{
    "image/png" => "image",
    "image/jpeg" => "image",
    "image/webp" => "image",
    "image/gif" => "image",
    "application/pdf" => "pdf"
  }

  def create(conn, %{"tid" => template_id, "qid" => question_id} = params) do
    with %{tenant: tenant} = assigns <- conn.assigns,
         %Template{tenant_id: tid} = template when tid == tenant.id <-
           Templates.get_template!(template_id),
         %Question{} = question <- Repo.get(Question, question_id),
         %Templates.Version{published_at: nil} = version <-
           Repo.get(Templates.Version, question.template_version_id),
         true <- version.template_id == template.id,
         %Plug.Upload{} = upload <- Map.get(params, "attachment"),
         {:ok, kind} <- classify(upload),
         {:ok, bytes} <- assert_under_max(upload),
         storage_key = artifact_key(tenant.id),
         {:ok, _} <- Storage.put_artifact(storage_key, upload.path),
         {:ok, asset} <-
           PromptAssets.create_attachment(tenant.id, %{
             kind: kind,
             mime_type: upload.content_type,
             storage_key: storage_key,
             bytes: bytes,
             created_by_user_id: assigns.current_recruiter.id
           }),
         {:ok, _} <-
           Templates.update_draft_question(question, %{"attachment_asset_id" => asset.id}) do
      json(conn, %{ok: true, promptAssetId: asset.id, kind: kind})
    else
      %Plug.Upload{} ->
        conn |> put_status(422) |> json(%{ok: false, error: "no_attachment"})

      nil ->
        not_found(conn)

      %Templates.Version{} ->
        conn
        |> put_status(422)
        |> json(%{ok: false, error: "version_published"})

      %Template{} ->
        not_found(conn)

      false ->
        not_found(conn)

      {:error, :unsupported_type} ->
        conn |> put_status(422) |> json(%{ok: false, error: "unsupported_type"})

      {:error, :too_large} ->
        conn |> put_status(422) |> json(%{ok: false, error: "too_large"})

      {:error, :published_immutable} ->
        conn |> put_status(422) |> json(%{ok: false, error: "version_published"})

      {:error, %Ecto.Changeset{}} ->
        conn |> put_status(422) |> json(%{ok: false, error: "invalid"})

      _ ->
        not_found(conn)
    end
  end

  defp classify(%Plug.Upload{content_type: ct}) do
    case Map.get(@kinds, ct) do
      nil -> {:error, :unsupported_type}
      kind -> {:ok, kind}
    end
  end

  defp assert_under_max(%Plug.Upload{path: path}) do
    case File.stat(path) do
      {:ok, %{size: size}} when size <= @max_bytes -> {:ok, size}
      {:ok, _} -> {:error, :too_large}
      {:error, _} -> {:error, :too_large}
    end
  end

  defp artifact_key(tenant_id) do
    "tenants/#{tenant_id}/prompt_assets/#{Ecto.UUID.generate()}"
  end

  defp not_found(conn) do
    conn |> put_status(404) |> json(%{ok: false, error: "not_found"})
  end
end
