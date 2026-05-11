defmodule InterviewWeb.TemplateController do
  @moduledoc """
  Recruiter-facing template + version JSON API (PLAN §3.4).

  All routes are tenant-scoped via `InterviewWeb.Plugs.DevTokenAuth`,
  which assigns `conn.assigns.tenant`. Real JWT/tenant auth replaces
  this plug end-to-end in a later session.

  Routes:

    POST   /api/templates                           → create
    GET    /api/templates                           → list (tenant-scoped)
    GET    /api/templates/:id                       → fetch with current_version
    POST   /api/templates/:id/versions              → create draft
    PUT    /api/templates/:id/versions/:vid/questions
    POST   /api/templates/:id/versions/:vid/publish
    POST   /api/templates/:id/import                (YAML or markdown body)

  Validation errors carry JSON pointers (RFC 6901) so clients can
  highlight the offending field. Webhook payloads (later) will carry
  `external_id` per PLAN §3.4.
  """
  use InterviewWeb, :controller

  alias Interview.Templates
  alias Interview.Templates.{MarkdownImporter, Spec, Template, Version, YamlImporter}

  # ---- Templates -------------------------------------------------------

  def create(conn, params) do
    tenant = conn.assigns.tenant

    attrs =
      params
      |> Map.take(["name", "description"])
      |> Map.put("tenant_id", tenant.id)

    case Templates.create_template(attrs) do
      {:ok, template} -> conn |> put_status(:created) |> json(render_template(template))
      {:error, cs} -> conn |> put_status(:unprocessable_entity) |> json(changeset_errors(cs))
    end
  end

  def index(conn, _params) do
    templates =
      conn.assigns.tenant.id
      |> Templates.list_templates()
      |> Enum.map(&render_template/1)

    json(conn, %{templates: templates})
  end

  def show(conn, %{"id" => id}) do
    case Templates.get_template_with_current_version(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      %{template: %Template{tenant_id: tid}} when tid != conn.assigns.tenant.id ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      %{template: template, current_version: current, draft_version: draft} ->
        json(conn, %{
          template: render_template(template),
          current_version: render_version(current),
          draft_version: render_version(draft)
        })
    end
  end

  # ---- Versions --------------------------------------------------------

  def create_version(conn, %{"id" => template_id}) do
    with {:ok, template} <- fetch_template(conn, template_id),
         {:ok, version} <- Templates.create_draft_version(template) do
      conn
      |> put_status(:created)
      |> json(%{version: render_version(version, with_questions: true)})
    end
    |> handle_error(conn)
  end

  def update_questions(conn, %{"id" => template_id, "vid" => vid, "questions" => qs})
      when is_list(qs) do
    # Build a Spec with a stub-valid template/retake so only question
    # errors surface in validation. The stub is never written: only the
    # questions and the existing version's retake_policy land in DB.
    spec = Spec.from_map(%{"template" => %{"name" => "_"}, "questions" => qs})

    with {:ok, _template} <- fetch_template(conn, template_id),
         {:ok, version} <- fetch_version(template_id, vid),
         {:ok, _} <- spec_validate(spec),
         {:ok, _} <- apply_questions_only(version, spec) do
      v = Templates.get_version!(version.id)
      json(conn, %{version: render_version(v, with_questions: true)})
    end
    |> handle_error(conn)
  end

  def update_questions(conn, _) do
    conn |> put_status(:unprocessable_entity) |> json(%{error: "missing_questions"})
  end

  def publish_version(conn, %{"id" => template_id, "vid" => vid}) do
    with {:ok, _template} <- fetch_template(conn, template_id),
         {:ok, version} <- fetch_version(template_id, vid),
         {:ok, published} <- Templates.publish_draft(version) do
      json(conn, %{version: render_version(published, with_questions: true)})
    end
    |> handle_error(conn)
  end

  # ---- Import ----------------------------------------------------------

  def import(conn, %{"id" => template_id} = params) do
    {body, _conn} = read_full_body(conn)
    content_type = first_content_type(conn)

    parse_result =
      cond do
        Map.has_key?(params, "format") -> parse_by_format(params["format"], body)
        content_type =~ "yaml" -> YamlImporter.parse(body)
        content_type =~ "markdown" -> MarkdownImporter.parse(body)
        body =~ ~r/\A---\s*\n/ -> MarkdownImporter.parse(body)
        true -> YamlImporter.parse(body)
      end

    with {:ok, _template} <- fetch_template(conn, template_id),
         {:ok, spec} <- parse_result,
         {:ok, draft} <- get_or_create_draft(template_id),
         {:ok, _} <- Templates.apply_spec_to_draft(draft, spec) do
      version = Templates.get_version!(draft.id)
      json(conn, %{version: render_version(version, with_questions: true)})
    else
      {:error, errors} when is_list(errors) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: render_import_errors(errors)})

      {:error, %Ecto.Changeset{} = cs} ->
        conn |> put_status(:unprocessable_entity) |> json(changeset_errors(cs))

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  defp parse_by_format("yaml", body), do: YamlImporter.parse(body)
  defp parse_by_format("markdown", body), do: MarkdownImporter.parse(body)

  defp parse_by_format(other, _),
    do: {:error, [%{message: "unknown format: #{other}", line: nil}]}

  defp get_or_create_draft(template_id) do
    template = Templates.get_template!(template_id)
    Templates.create_draft_version(template)
  end

  # ---- Plumbing --------------------------------------------------------

  defp fetch_template(conn, id) do
    tenant_id = conn.assigns.tenant.id

    case Interview.Repo.get(Template, id) do
      %Template{tenant_id: ^tenant_id} = t -> {:ok, t}
      _ -> {:error, :not_found}
    end
  end

  defp fetch_version(template_id, vid) do
    case Interview.Repo.get(Version, vid) do
      %Version{template_id: ^template_id} = v -> {:ok, v}
      _ -> {:error, :not_found}
    end
  end

  defp spec_validate(%Spec{} = spec) do
    case Spec.validate(spec) do
      {:ok, spec} -> {:ok, spec}
      {:error, errors} -> {:error, render_validation_errors(errors)}
    end
  end

  defp apply_questions_only(version, %Spec{} = spec) do
    # Reuse apply_spec_to_draft, but keep the version's existing retake
    # policy by spreading current values into the spec before applying.
    spec_with_existing_retake = %{
      spec
      | retake_policy: %{
          "max_attempts" => version.retake_policy["max_attempts"] || 1,
          "mode" => version.retake_policy["mode"] || "first_only"
        }
    }

    Templates.apply_spec_to_draft(version, spec_with_existing_retake)
  end

  defp handle_error(%Plug.Conn{state: :unset} = conn, _), do: conn
  defp handle_error(%Plug.Conn{} = conn, _), do: conn

  defp handle_error({:error, :not_found}, conn) do
    conn |> put_status(:not_found) |> json(%{error: "not_found"})
  end

  defp handle_error({:error, :published_immutable}, conn) do
    conn |> put_status(:conflict) |> json(%{error: "version_already_published"})
  end

  defp handle_error({:error, :already_published}, conn) do
    conn |> put_status(:conflict) |> json(%{error: "version_already_published"})
  end

  defp handle_error({:error, errors}, conn) when is_list(errors) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: errors})
  end

  defp handle_error({:error, reason}, conn) do
    conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
  end

  defp handle_error(other, _conn), do: other

  defp render_template(%Template{} = t) do
    %{
      id: t.id,
      tenant_id: t.tenant_id,
      name: t.name,
      description: t.description,
      current_version_id: t.current_version_id,
      archived_at: t.archived_at,
      inserted_at: t.inserted_at
    }
  end

  defp render_version(version, opts \\ [])
  defp render_version(nil, _opts), do: nil

  defp render_version(%Version{} = v, opts) do
    base = %{
      id: v.id,
      template_id: v.template_id,
      version_number: v.version_number,
      retake_policy: v.retake_policy,
      published_at: v.published_at,
      published_by: v.published_by
    }

    if Keyword.get(opts, :with_questions, false) do
      qs =
        v
        |> Templates.list_questions()
        |> Enum.map(&render_question/1)

      Map.put(base, :questions, qs)
    else
      base
    end
  end

  defp render_question(q) do
    %{
      id: q.id,
      position: q.position,
      prompt_text: q.prompt_text,
      think_time_seconds: q.think_time_seconds,
      min_answer_seconds: q.min_answer_seconds,
      max_answer_seconds: q.max_answer_seconds,
      required: q.required,
      max_attempts_override: q.max_attempts_override,
      tags: q.tags,
      locale: q.locale,
      external_id: q.external_id,
      notes: q.notes,
      prompt_asset_id: q.prompt_asset_id,
      attachment_asset_id: q.attachment_asset_id
    }
  end

  defp render_validation_errors(errors) do
    Enum.map(errors, fn %{path: path, message: msg} ->
      %{pointer: Spec.path_to_json_pointer(path), message: msg}
    end)
  end

  defp render_import_errors(errors) do
    Enum.map(errors, fn err ->
      base = %{message: err.message}

      base =
        if Map.has_key?(err, :path),
          do: Map.put(base, :pointer, Spec.path_to_json_pointer(err.path)),
          else: base

      base =
        if Map.has_key?(err, :line) and err.line, do: Map.put(base, :line, err.line), else: base

      base
    end)
  end

  defp changeset_errors(%Ecto.Changeset{} = cs) do
    %{
      errors:
        Enum.map(cs.errors, fn {field, {msg, _}} ->
          %{pointer: "/#{field}", message: msg}
        end)
    }
  end

  defp read_full_body(conn) do
    case Plug.Conn.read_body(conn, length: 1_000_000) do
      {:ok, body, conn} -> {body, conn}
      {:more, partial, conn} -> read_more(conn, [partial])
      {:error, _} -> {"", conn}
    end
  end

  defp read_more(conn, acc) do
    case Plug.Conn.read_body(conn, length: 1_000_000) do
      {:ok, body, conn} -> {IO.iodata_to_binary([acc, body]), conn}
      {:more, partial, conn} -> read_more(conn, [acc, partial])
      {:error, _} -> {IO.iodata_to_binary(acc), conn}
    end
  end

  defp first_content_type(conn) do
    conn |> Plug.Conn.get_req_header("content-type") |> List.first() |> Kernel.||("")
  end
end
