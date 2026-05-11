defmodule Interview.Templates do
  @moduledoc """
  Template authoring (PLAN §3.4).

  Versioning rule: editing a published version is disallowed. Drafts
  (versions with `published_at = nil`) are mutable; `publish_draft/2`
  stamps `published_at`/`published_by` and atomically flips
  `interview_templates.current_version_id` to the freshly-published row.

  Imports (YAML / markdown / JSON) flow through the same shared
  `Interview.Templates.Spec` and apply to the current draft via
  `apply_spec_to_draft/2`. One code path, three front doors.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Interview.Repo
  alias Interview.Templates.{Question, Spec, Template, Version}

  # ---- Templates --------------------------------------------------------

  def create_template(attrs) do
    %Template{}
    |> Template.changeset(attrs)
    |> Repo.insert()
  end

  def list_templates(tenant_id) do
    from(t in Template,
      where: t.tenant_id == ^tenant_id and is_nil(t.archived_at),
      order_by: [desc: t.inserted_at]
    )
    |> Repo.all()
  end

  def get_template!(id), do: Repo.get!(Template, id)

  @doc """
  Fetch a template with `current_version_id` and current draft (if any)
  preloaded. Returns `%{template, current_version, draft_version}` —
  any of which may be `nil` (a brand-new template has neither yet).
  """
  def get_template_with_current_version(id) do
    template = Repo.get(Template, id)

    if is_nil(template) do
      nil
    else
      current = template.current_version_id && Repo.get(Version, template.current_version_id)
      draft = current_draft(template)

      %{template: template, current_version: current, draft_version: draft}
    end
  end

  defp current_draft(%Template{id: tid}) do
    from(v in Version,
      where: v.template_id == ^tid and is_nil(v.published_at),
      order_by: [desc: v.version_number],
      limit: 1
    )
    |> Repo.one()
  end

  # ---- Versions ---------------------------------------------------------

  def get_version!(id), do: Repo.get!(Version, id)

  def get_version(id), do: Repo.get(Version, id)

  def list_versions(template_id) do
    from(v in Version,
      where: v.template_id == ^template_id,
      order_by: [desc: v.version_number]
    )
    |> Repo.all()
  end

  def list_questions(%Version{id: vid}) do
    from(q in Question, where: q.template_version_id == ^vid, order_by: q.position)
    |> Repo.all()
  end

  def get_question!(id), do: Repo.get!(Question, id)

  @doc """
  Open a draft version on a template. If a draft already exists, return
  it. Otherwise clone questions from `current_version` (if any) into a
  fresh unpublished version.

  Returns `{:ok, %Version{}}`.
  """
  def create_draft_version(template, attrs \\ %{})

  def create_draft_version(%Template{} = template, attrs) do
    case current_draft(template) do
      %Version{} = existing ->
        {:ok, existing}

      nil ->
        do_create_draft_version(template, attrs)
    end
  end

  defp do_create_draft_version(template, attrs) do
    current = template.current_version_id && Repo.get(Version, template.current_version_id)

    retake_policy =
      attrs[:retake_policy] || (current && current.retake_policy) ||
        %{"max_attempts" => 1, "mode" => "first_only"}

    Multi.new()
    |> Multi.run(:next_version_number, fn repo, _ ->
      n =
        repo.one(
          from(v in Version,
            where: v.template_id == ^template.id,
            select: coalesce(max(v.version_number), 0)
          )
        )

      {:ok, (n || 0) + 1}
    end)
    |> Multi.insert(:version, fn %{next_version_number: n} ->
      Version.changeset(%Version{}, %{
        template_id: template.id,
        version_number: n,
        retake_policy: retake_policy
      })
    end)
    |> Multi.run(:clone_questions, fn repo, %{version: version} ->
      cloned =
        if current do
          clone_questions(repo, current.id, version.id)
        else
          0
        end

      {:ok, cloned}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{version: version}} -> {:ok, version}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  defp clone_questions(repo, source_version_id, target_version_id) do
    source_questions =
      from(q in Question,
        where: q.template_version_id == ^source_version_id,
        order_by: q.position
      )
      |> repo.all()

    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    rows =
      Enum.map(source_questions, fn q ->
        %{
          id: Ecto.UUID.generate(),
          template_version_id: target_version_id,
          position: q.position,
          prompt_text: q.prompt_text,
          prompt_asset_id: q.prompt_asset_id,
          attachment_asset_id: q.attachment_asset_id,
          think_time_seconds: q.think_time_seconds,
          max_answer_seconds: q.max_answer_seconds,
          min_answer_seconds: q.min_answer_seconds,
          required: q.required,
          max_attempts_override: q.max_attempts_override,
          tags: q.tags,
          locale: q.locale,
          external_id: q.external_id,
          notes: q.notes,
          inserted_at: now,
          updated_at: now
        }
      end)

    if rows == [] do
      0
    else
      {n, _} = repo.insert_all(Question, rows)
      n
    end
  end

  @doc """
  Mutate a draft. Editing a *published* version raises (PLAN §3.4
  versioning rule).
  """
  def update_draft_version(%Version{published_at: nil} = version, attrs) do
    version
    |> Version.changeset(attrs)
    |> Repo.update()
  end

  def update_draft_version(%Version{}, _attrs), do: {:error, :published_immutable}

  @doc """
  Replace the question list of a draft version with the given specs.
  Each spec is a map with the `template_questions` fields. Positions
  are taken as authoritative.

  Returns `{:ok, [%Question{}]}` or `{:error, changeset}`.
  """
  def update_draft_questions(%Version{published_at: nil} = version, question_specs)
      when is_list(question_specs) do
    Multi.new()
    |> Multi.delete_all(
      :delete_existing,
      from(q in Question, where: q.template_version_id == ^version.id)
    )
    |> Multi.run(:insert, fn repo, _ ->
      questions =
        question_specs
        |> Enum.with_index(1)
        |> Enum.map(fn {spec, idx} ->
          attrs =
            spec
            |> stringify_keys()
            |> Map.put("template_version_id", version.id)
            |> Map.put_new("position", idx)

          changeset = Question.changeset(%Question{}, attrs)

          case repo.insert(changeset) do
            {:ok, q} -> q
            {:error, cs} -> throw({:invalid, idx, cs})
          end
        end)

      {:ok, questions}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{insert: questions}} -> {:ok, questions}
      {:error, _step, reason, _} -> {:error, reason}
    end
  catch
    {:invalid, idx, cs} -> {:error, {idx, cs}}
  end

  def update_draft_questions(%Version{}, _), do: {:error, :published_immutable}

  @doc """
  Update a single draft question by id. Useful for the LiveView autosave
  path which writes one field at a time.
  """
  def update_draft_question(%Question{} = question, attrs) do
    version = Repo.get!(Version, question.template_version_id)

    if not is_nil(version.published_at) do
      {:error, :published_immutable}
    else
      question
      |> Question.changeset(attrs)
      |> Repo.update()
    end
  end

  @doc """
  Reorder a draft's questions. `ordered_ids` is the new position-1..N
  order. All ids must belong to the version.
  """
  def reorder_draft_questions(%Version{published_at: nil} = version, ordered_ids)
      when is_list(ordered_ids) do
    Multi.new()
    |> Multi.run(:reorder, fn repo, _ ->
      # Stage 1: shift to negative offsets to dodge the
      # UNIQUE(template_version_id, position) constraint.
      ordered_ids
      |> Enum.with_index(1)
      |> Enum.each(fn {id, idx} ->
        {1, _} =
          from(q in Question,
            where: q.id == ^id and q.template_version_id == ^version.id
          )
          |> repo.update_all(set: [position: -idx])
      end)

      # Stage 2: settle to final positions.
      ordered_ids
      |> Enum.with_index(1)
      |> Enum.each(fn {id, idx} ->
        {1, _} =
          from(q in Question,
            where: q.id == ^id and q.template_version_id == ^version.id
          )
          |> repo.update_all(set: [position: idx])
      end)

      {:ok, length(ordered_ids)}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, _} -> {:ok, list_questions(version)}
      {:error, _, reason, _} -> {:error, reason}
    end
  end

  def reorder_draft_questions(%Version{}, _), do: {:error, :published_immutable}

  @doc """
  Publish a draft. Stamps `published_at`/`published_by`, then flips the
  parent template's `current_version_id` in the same transaction
  (PLAN §3.4 versioning rule). Returns `{:ok, %Version{}}` or
  `{:error, reason}`.

  Sessions in flight keep their frozen `template_version_id` and are
  unaffected.
  """
  def publish_draft(version, opts \\ [])

  def publish_draft(%Version{published_at: nil} = version, opts) do
    published_by = Keyword.get(opts, :published_by)

    Multi.new()
    |> Multi.update(:publish, fn _ ->
      Version.changeset(version, %{
        published_at: DateTime.utc_now(),
        published_by: published_by
      })
    end)
    |> Multi.run(:flip_current, fn repo, %{publish: published} ->
      {1, [template]} =
        from(t in Template,
          where: t.id == ^version.template_id,
          select: t
        )
        |> repo.update_all(set: [current_version_id: published.id])

      {:ok, template}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{publish: published}} ->
        template = Repo.get!(Template, version.template_id)

        Interview.Audit.log!(%{
          tenant_id: template.tenant_id,
          actor_kind: "recruiter",
          actor_id: published_by,
          action: "template.publish",
          subject_kind: "template_version",
          subject_id: published.id,
          metadata: %{
            "template_id" => template.id,
            "version_number" => published.version_number
          }
        })

        {:ok, published}

      {:error, _step, reason, _} ->
        {:error, reason}
    end
  end

  def publish_draft(%Version{}, _opts), do: {:error, :already_published}

  @doc """
  Point a template's `current_version_id` at a previously published
  version — the "revert to old version" affordance. Only new sessions are
  affected; in-flight sessions keep their frozen `template_version_id`
  (PLAN §3.4).

  Returns `{:ok, %Template{}}` on success.
  Returns `{:error, :version_not_published}` if the target is still a draft.
  Returns `{:error, :template_mismatch}` if the version belongs to a
  different template.
  """
  def set_current_version(%Template{} = template, %Version{} = version, opts \\ []) do
    actor_id = Keyword.get(opts, :actor_id)

    cond do
      version.template_id != template.id ->
        {:error, :template_mismatch}

      is_nil(version.published_at) ->
        {:error, :version_not_published}

      true ->
        {1, [updated]} =
          from(t in Template, where: t.id == ^template.id, select: t)
          |> Repo.update_all(set: [current_version_id: version.id])

        Interview.Audit.log!(%{
          tenant_id: template.tenant_id,
          actor_kind: "recruiter",
          actor_id: actor_id,
          action: "template.set_current_version",
          subject_kind: "template_version",
          subject_id: version.id,
          metadata: %{
            "template_id" => template.id,
            "version_number" => version.version_number
          }
        })

        {:ok, updated}
    end
  end

  @doc """
  Delete a template version. Refuses if:

    * the version belongs to a different template (`:template_mismatch`),
    * it is the template's current published version (`:is_current`),
    * any session references it (`:has_sessions`).

  Cascades to `template_questions` via the existing FK
  (`on_delete: :delete_all`). Drafts can be deleted — they're transient
  working copies, and `ensure_draft` will create a fresh one on the next
  visit if needed.
  """
  def delete_version(%Template{} = template, %Version{} = version, opts \\ []) do
    actor_id = Keyword.get(opts, :actor_id)

    cond do
      version.template_id != template.id ->
        {:error, :template_mismatch}

      template.current_version_id == version.id ->
        {:error, :is_current}

      true ->
        # Only *live* sessions (no `deleted_at`) block deletion. Soft-
        # deleted sessions had their storage and response rows scrubbed
        # by `Interview.Workers.SessionDeletion`; the session row was
        # kept only to keep the audit subject_id alive. Here we hard-
        # delete those rows so the version can drop — `audit_events`
        # already holds the history independently.
        live_count =
          Repo.aggregate(
            from(s in Interview.Capture.Session,
              where: s.template_version_id == ^version.id and is_nil(s.deleted_at)
            ),
            :count,
            :id
          )

        cond do
          live_count > 0 ->
            {:error, :has_sessions}

          true ->
            Repo.transaction(fn ->
              # Hard-delete soft-deleted sessions first — `session_questions`
              # cascade with them, freeing `template_questions` (which are
              # held by `session_questions` via `ON DELETE RESTRICT`) so
              # the version's cascade can drop them.
              {_n, _} =
                from(s in Interview.Capture.Session,
                  where: s.template_version_id == ^version.id
                )
                |> Repo.delete_all()

              {:ok, _} = Repo.delete(version)
            end)

            Interview.Audit.log!(%{
              tenant_id: template.tenant_id,
              actor_kind: "recruiter",
              actor_id: actor_id,
              action: "template.delete_version",
              subject_kind: "template_version",
              subject_id: version.id,
              metadata: %{
                "template_id" => template.id,
                "version_number" => version.version_number
              }
            })

            :ok
        end
    end
  end

  # ---- Spec → DB --------------------------------------------------------

  @doc """
  Apply a validated `%Spec{}` to a draft version: replace the version's
  `retake_policy` and `template_questions` rows. Used by importers and
  the JSON API; the LiveView builder writes the same fields directly.
  """
  def apply_spec_to_draft(%Version{published_at: nil} = version, %Spec{} = spec) do
    Multi.new()
    |> Multi.update(
      :update_version,
      Version.changeset(version, %{
        retake_policy: %{
          "max_attempts" => spec.retake_policy["max_attempts"] || 1,
          "mode" => spec.retake_policy["mode"] || "first_only"
        }
      })
    )
    |> Multi.delete_all(
      :delete_questions,
      from(q in Question, where: q.template_version_id == ^version.id)
    )
    |> Multi.run(:insert_questions, fn repo, _ ->
      questions =
        Enum.map(spec.questions, fn q ->
          attrs = Map.put(q, "template_version_id", version.id)

          case repo.insert(Question.changeset(%Question{}, attrs)) do
            {:ok, inserted} -> inserted
            {:error, cs} -> throw({:question_invalid, q["position"], cs})
          end
        end)

      {:ok, questions}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{update_version: v, insert_questions: qs}} -> {:ok, %{version: v, questions: qs}}
      {:error, _step, reason, _} -> {:error, reason}
    end
  catch
    {:question_invalid, pos, cs} -> {:error, {:question_invalid, pos, cs}}
  end

  def apply_spec_to_draft(%Version{}, %Spec{}), do: {:error, :published_immutable}

  @doc """
  Build a `%Spec{}` from a persisted version's current rows. Round-trips
  with `YamlImporter.dump/1`.
  """
  def version_to_spec(%Version{} = version) do
    template = Repo.get!(Template, version.template_id)
    questions = list_questions(version)

    %Spec{
      template: %{
        "name" => template.name,
        "description" => template.description
      },
      retake_policy: %{
        "max_attempts" => version.retake_policy["max_attempts"] || 1,
        "mode" => version.retake_policy["mode"] || "first_only"
      },
      questions: Enum.map(questions, &question_to_spec_map/1)
    }
  end

  defp question_to_spec_map(%Question{} = q) do
    %{
      "position" => q.position,
      "prompt_text" => q.prompt_text,
      "think_time_seconds" => q.think_time_seconds,
      "min_answer_seconds" => q.min_answer_seconds,
      "max_answer_seconds" => q.max_answer_seconds,
      "required" => q.required,
      "max_attempts_override" => q.max_attempts_override,
      "tags" => q.tags || [],
      "locale" => q.locale,
      "external_id" => q.external_id,
      "notes" => q.notes,
      "prompt_asset_id" => q.prompt_asset_id,
      "attachment_asset_id" => q.attachment_asset_id
    }
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
