defmodule Interview.Fixtures do
  @moduledoc """
  Minimal fixture helpers for Phase 1 tests. The full template-authoring
  surface lands in Phase 2; these helpers create the smallest valid
  graph we need to exercise the candidate capture pipeline.
  """
  import Ecto.Query, only: [from: 2]

  alias Interview.Repo
  alias Interview.Tenants.Tenant
  alias Interview.Templates.{PromptAsset, Template, Version, Question}
  alias Interview.Capture.Session
  alias Interview.Auth.{ApiKeys, Bootstrap, Recruiters, Tokens}

  def tenant!(attrs \\ %{}) do
    {:ok, t} =
      %Tenant{}
      |> Tenant.changeset(
        Map.merge(
          %{
            name: "Acme #{System.unique_integer([:positive])}",
            slug: "acme-#{System.unique_integer([:positive])}",
            frame_ancestors: ["'self'"]
          },
          attrs
        )
      )
      |> Repo.insert()

    t
  end

  def template!(tenant_id, attrs \\ %{}) do
    {:ok, t} =
      %Template{}
      |> Template.changeset(
        Map.merge(%{tenant_id: tenant_id, name: "T-#{System.unique_integer([:positive])}"}, attrs)
      )
      |> Repo.insert()

    t
  end

  def version!(template_id, attrs \\ %{}) do
    {:ok, v} =
      %Version{}
      |> Version.changeset(
        Map.merge(
          %{template_id: template_id, version_number: System.unique_integer([:positive])},
          attrs
        )
      )
      |> Repo.insert()

    v
  end

  def question!(template_version_id, position \\ 1, attrs \\ %{}) do
    {:ok, q} =
      %Question{}
      |> Question.changeset(
        Map.merge(
          %{
            template_version_id: template_version_id,
            position: position,
            prompt_text: "Question #{position}",
            max_answer_seconds: 60,
            required: true
          },
          attrs
        )
      )
      |> Repo.insert()

    q
  end

  @doc """
  Insert a `PromptAsset` directly. Defaults to a `ready` video asset.
  Override `:state` for tests that exercise mid-pipeline rows.
  """
  def prompt_asset!(tenant_id, attrs \\ %{}) do
    state = Map.get(attrs, :state, "ready")

    base =
      %{
        tenant_id: tenant_id,
        kind: "video",
        mime_type: "video/mp4",
        storage_key: "test/prompt_assets/#{Ecto.UUID.generate()}.mp4",
        state: state,
        bytes: 1024,
        duration_ms: 5_000
      }
      |> Map.merge(attrs)

    {:ok, asset} =
      %PromptAsset{} |> PromptAsset.changeset(base) |> Repo.insert()

    asset
  end

  def session!(tenant_id, template_version_id, attrs \\ %{}) do
    {:ok, s} =
      %Session{}
      |> Session.changeset(
        Map.merge(
          %{tenant_id: tenant_id, template_version_id: template_version_id, state: "in_progress"},
          attrs
        )
      )
      |> Repo.insert()

    s
  end

  @doc "Spins up a tenant + template + version + question + session in one call."
  def graph!(attrs \\ %{}) do
    tenant = tenant!(Map.get(attrs, :tenant, %{}))
    template = template!(tenant.id, Map.get(attrs, :template, %{}))
    version = version!(template.id, Map.get(attrs, :version, %{}))
    question = question!(version.id, Map.get(attrs, :position, 1), Map.get(attrs, :question, %{}))
    session = session!(tenant.id, version.id, Map.get(attrs, :session, %{}))

    %{tenant: tenant, template: template, version: version, question: question, session: session}
  end

  @doc """
  Like `graph!/1` but with N questions, returning them in a `:questions` list
  (and the first one as `:question` for back-compat with single-question tests).

  Each entry of `question_specs` is a map of attrs; `position` is auto-assigned
  unless overridden. `version_attrs` is merged into the template version (e.g.
  `%{retake_policy: %{"max_attempts" => 3, "mode" => "last"}}`).
  """
  def graph_with_questions!(question_specs, opts \\ []) do
    tenant = tenant!(opts[:tenant] || %{})
    template = template!(tenant.id, opts[:template] || %{})
    version = version!(template.id, opts[:version] || %{})

    questions =
      question_specs
      |> Enum.with_index(1)
      |> Enum.map(fn {attrs, idx} ->
        question!(version.id, attrs[:position] || idx, Map.delete(attrs, :position))
      end)

    session = session!(tenant.id, version.id, opts[:session] || %{})

    %{
      tenant: tenant,
      template: template,
      version: version,
      questions: questions,
      question: List.first(questions),
      session: session
    }
  end

  # ---- Auth fixtures ------------------------------------------------------

  def recruiter!(tenant_id, attrs \\ %{}) do
    Recruiters.create_user!(
      Map.merge(
        %{
          tenant_id: tenant_id,
          email: "rec-#{System.unique_integer([:positive])}@example.com"
        },
        attrs
      )
    )
  end

  @doc """
  Mints a fresh tenant API key. Returns `{api_key_struct, secret_string}`
  where `secret_string` is the wire bearer (`tk_<...>`).

  Pass `revoked: true` to also revoke before returning.
  """
  def api_key!(tenant_id, opts \\ []) do
    name = Keyword.get(opts, :name, "key-#{System.unique_integer([:positive])}")
    {:ok, %{api_key: key, secret: secret}} = ApiKeys.create(tenant_id, name)

    key =
      if Keyword.get(opts, :revoked, false) do
        {:ok, k} = ApiKeys.revoke(tenant_id, key.id)
        k
      else
        key
      end

    {key, secret}
  end

  def bootstrap_token!(%Session{} = session) do
    {:ok, %{token: token}} = Bootstrap.mint(session)
    token
  end

  def upload_bearer!(%Session{} = session) do
    Tokens.mint_upload_bearer(session.id)
  end

  def recruiter_session_token!(%Recruiters.User{} = user) do
    Tokens.mint_recruiter_session(user.id, user.tenant_id)
  end

  @doc """
  Mark a `Response` as `ready` with a fake artifact on disk under the
  configured storage root. Useful for playback tests — the file's bytes
  are deterministic so we can assert on `Range` slicing.

  Returns the updated `%Response{}`. The body defaults to a 4 KiB
  payload of repeated ASCII; pass `:bytes` to override.
  """
  def with_artifact!(%Interview.Capture.Response{} = response, opts \\ []) do
    body = Keyword.get(opts, :bytes, :binary.copy(<<"ABCDEFGH">>, 512))
    duration_ms = Keyword.get(opts, :duration_ms, 1_234)
    storage_key = Keyword.get(opts, :storage_key, "test/#{response.id}.mp4")

    path = Interview.Storage.artifact_path(storage_key)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)

    {1, [updated]} =
      Interview.Repo.update_all(
        from(r in Interview.Capture.Response, where: r.id == ^response.id, select: r),
        set: [
          state: "ready",
          storage_key: storage_key,
          duration_ms: duration_ms,
          finalized_at: DateTime.utc_now()
        ]
      )

    updated
  end
end
