defmodule InterviewWeb.RecruiterTemplateLive do
  @moduledoc """
  Recruiter authoring UI for an `interview_template` (PLAN §3.4).

  - Lists existing versions (published + the current draft).
  - Edits the draft's questions in place. Autosave on every field blur
    (no separate "Save" button).
  - Reorders questions (up/down buttons; drag-handle is a follow-up
    polish item).
  - Publishes the draft, atomically flipping `current_version_id`.

  Editing a published version is impossible by construction: the page
  only writes to the draft, and the context layer rejects writes to
  versions with `published_at != nil`.
  """
  use InterviewWeb, :live_view

  import Ecto.Query, only: [from: 2]

  alias Interview.ExternalIntegration.ReturnTo
  alias Interview.Repo
  alias Interview.Templates
  alias Interview.Templates.{PromptAsset, Question, Version}

  @impl true
  def mount(%{"id" => template_id} = params, _session, socket) do
    tenant_id = socket.assigns.tenant.id

    case Templates.get_template_with_current_version(template_id) do
      %{template: %{tenant_id: tid}} when tid != tenant_id ->
        {:ok,
         socket
         |> assign(:not_found, true)
         |> assign(:template_id, template_id)}

      nil ->
        {:ok,
         socket
         |> assign(:not_found, true)
         |> assign(:template_id, template_id)}

      %{template: template, current_version: current, draft_version: draft} ->
        {:ok, draft} = ensure_draft(template, draft)
        questions = Templates.list_questions(draft)
        assets = load_assets_for(questions)
        external_integration = build_external_integration(params, socket.assigns.tenant, draft)

        {:ok,
         socket
         |> assign(:not_found, false)
         |> assign(:template, template)
         |> assign(:current_version, current)
         |> assign(:draft, draft)
         |> assign(:questions, questions)
         |> assign(:assets, assets)
         |> assign(:versions, Templates.list_versions(template.id))
         |> assign(:saved_at, nil)
         |> assign(:collapsed_sections, MapSet.new([:versions, :retake_policy]))
         |> assign(:collapsed_questions, MapSet.new())
         |> assign(:external_integration, external_integration)}
    end
  end

  # `return_to`/`state` are forwarded by external systems (e.g. Pulsifi) to
  # complete a deep-link template-creation handoff. When present and the
  # origin is whitelisted, publishing the template redirects the browser
  # back to the caller with the new template UUID. Invalid `return_to`s are
  # silently dropped (the LiveView still works for the recruiter — they just
  # land on the normal post-publish detail page).
  #
  # Falls back to fields stored on the draft when the URL doesn't carry
  # the params — this covers the case where an in-LV navigation (e.g. the
  # prompt recorder's post-attach push_navigate) strips the query mid-edit.
  defp build_external_integration(params, tenant, draft) do
    return_to = params["return_to"] || draft.external_return_url
    state = params["state"] || draft.external_return_state

    case ReturnTo.validate(return_to, tenant.allowed_return_origins) do
      {:ok, uri} -> %{return_to_uri: uri, state: state}
      {:error, _} -> nil
    end
  end

  defp load_assets_for(questions) do
    ids =
      questions
      |> Enum.flat_map(fn q -> [q.prompt_asset_id, q.attachment_asset_id] end)
      |> Enum.reject(&is_nil/1)

    case ids do
      [] ->
        %{}

      ids ->
        Repo.all(from(a in PromptAsset, where: a.id in ^ids))
        |> Map.new(&{&1.id, &1})
    end
  end

  defp ensure_draft(_template, %Version{} = draft), do: {:ok, draft}
  defp ensure_draft(template, nil), do: Templates.create_draft_version(template)

  # ---- Events ----------------------------------------------------------

  @impl true
  def handle_event("update_field", %{"id" => id, "field" => field, "value" => value}, socket) do
    question = find_question(socket.assigns.questions, id)

    if is_nil(question) do
      {:noreply, socket}
    else
      attrs = cast_field(field, value)

      case Templates.update_draft_question(question, attrs) do
        {:ok, _updated} ->
          {:noreply, refresh_questions(socket)}

        {:error, changeset} ->
          {:noreply,
           socket
           |> put_flash(:error, "Failed to save: #{inspect(changeset.errors)}")}
      end
    end
  end

  # The select fires `phx-change` (a FORM event), which silently
  # ignores `phx-value-*` attributes — only the named form fields
  # reach this handler. The number input fires `phx-blur` (NOT a
  # form event), so its `phx-value-field` did get through. Rather
  # than maintain two param shapes, accept whatever named keys arrive
  # and merge them into retake_policy a piece at a time. Each field
  # write is independent — partial params won't clobber the other.
  def handle_event("update_retake", params, socket) do
    draft = socket.assigns.draft
    rp = draft.retake_policy || %{}

    new_rp =
      rp
      |> maybe_set_retake("max_attempts", parse_int_or_nil(params["max_attempts"]))
      |> maybe_set_retake("mode", params["mode"])

    case Templates.update_draft_version(draft, %{retake_policy: new_rp}) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:draft, updated)
         |> stamp_saved()}

      {:error, _cs} ->
        {:noreply, put_flash(socket, :error, "Failed to update retake policy")}
    end
  end

  defp maybe_set_retake(map, _key, nil), do: map
  defp maybe_set_retake(map, key, value), do: Map.put(map, key, value)

  defp parse_int_or_nil(nil), do: nil
  defp parse_int_or_nil(""), do: nil

  defp parse_int_or_nil(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_int_or_nil(n) when is_integer(n), do: n
  defp parse_int_or_nil(_), do: nil

  def handle_event("add_question", _params, socket) do
    questions = socket.assigns.questions
    next_position = length(questions) + 1

    attrs = %{
      "template_version_id" => socket.assigns.draft.id,
      "position" => next_position,
      "prompt_text" => "New question #{next_position}",
      "required" => true
    }

    case %Question{} |> Question.changeset(attrs) |> Interview.Repo.insert() do
      {:ok, _q} ->
        {:noreply, refresh_questions(socket)}

      {:error, _cs} ->
        {:noreply, put_flash(socket, :error, "Failed to add question")}
    end
  end

  def handle_event("delete_question", %{"id" => id}, socket) do
    case find_question(socket.assigns.questions, id) do
      nil ->
        {:noreply, socket}

      question ->
        Interview.Repo.delete!(question)
        # Compact positions so they remain a contiguous 1..N sequence.
        remaining =
          Templates.list_questions(socket.assigns.draft)
          |> Enum.map(& &1.id)

        {:ok, _} = Templates.reorder_draft_questions(socket.assigns.draft, remaining)
        {:noreply, refresh_questions(socket)}
    end
  end

  def handle_event("move", %{"id" => id, "dir" => dir}, socket) do
    delta = if dir == "up", do: -1, else: 1
    ids = Enum.map(socket.assigns.questions, & &1.id)
    idx = Enum.find_index(ids, &(&1 == id))
    target = idx && idx + delta

    cond do
      is_nil(idx) ->
        {:noreply, socket}

      target < 0 or target >= length(ids) ->
        {:noreply, socket}

      true ->
        {a, b} = {Enum.at(ids, idx), Enum.at(ids, target)}
        new_order = ids |> List.replace_at(idx, b) |> List.replace_at(target, a)

        case Templates.reorder_draft_questions(socket.assigns.draft, new_order) do
          {:ok, _} -> {:noreply, refresh_questions(socket)}
          {:error, _} -> {:noreply, put_flash(socket, :error, "Reorder failed")}
        end
    end
  end

  def handle_event("remove_prompt_asset", %{"id" => id}, socket) do
    case find_question(socket.assigns.questions, id) do
      nil ->
        {:noreply, socket}

      question ->
        case Templates.update_draft_question(question, %{"prompt_asset_id" => nil}) do
          {:ok, _} -> {:noreply, refresh_questions(socket)}
          {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to remove prompt")}
        end
    end
  end

  def handle_event("remove_attachment", %{"id" => id}, socket) do
    case find_question(socket.assigns.questions, id) do
      nil ->
        {:noreply, socket}

      question ->
        case Templates.update_draft_question(question, %{"attachment_asset_id" => nil}) do
          {:ok, _} -> {:noreply, refresh_questions(socket)}
          {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to remove attachment")}
        end
    end
  end

  def handle_event("publish", _params, socket) do
    case Templates.publish_draft(socket.assigns.draft) do
      {:ok, published} ->
        case socket.assigns.external_integration do
          nil ->
            # Normal flow: re-fetch the template detail page so the just-
            # published version is visible as `current_version`.
            {:noreply,
             push_navigate(socket, to: ~p"/recruiter/templates/#{socket.assigns.template.id}")}

          %{return_to_uri: uri, state: state} ->
            # Deep-link handoff: send the recruiter's browser back to the
            # external caller (e.g. Pulsifi) with the new template UUIDs
            # appended. The `state` token is echoed unchanged so the
            # caller can verify the callback's origin.
            redirect_url =
              ReturnTo.build_redirect(uri, %{
                "template_id" => socket.assigns.template.id,
                "template_version_id" => published.id,
                "state" => state
              })

            {:noreply, redirect(socket, external: redirect_url)}
        end

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Publish failed: #{inspect(reason)}")}
    end
  end

  def handle_event("toggle_section", %{"section" => key}, socket) do
    section = String.to_existing_atom(key)

    {:noreply,
     update(socket, :collapsed_sections, fn set ->
       if MapSet.member?(set, section),
         do: MapSet.delete(set, section),
         else: MapSet.put(set, section)
     end)}
  end

  def handle_event("attachment_uploaded", _params, socket) do
    {:noreply, refresh_questions(socket)}
  end

  def handle_event("attachment_error", %{"error" => reason}, socket) do
    require Logger
    Logger.warning("attachment upload failed: #{reason}")
    {:noreply, socket}
  end

  def handle_event("toggle_question", %{"id" => id}, socket) do
    {:noreply,
     update(socket, :collapsed_questions, fn set ->
       if MapSet.member?(set, id),
         do: MapSet.delete(set, id),
         else: MapSet.put(set, id)
     end)}
  end

  def handle_event("delete_version", %{"id" => version_id}, socket) do
    template = socket.assigns.template
    recruiter = socket.assigns.current_recruiter

    case Repo.get(Version, version_id) do
      %Version{} = version ->
        case Templates.delete_version(template, version, actor_id: recruiter.id) do
          :ok ->
            # If the deleted version was the open draft, the next visit
            # will re-create one via `ensure_draft`; for now redirect to
            # let mount do that cleanly. Otherwise just refresh the list.
            if socket.assigns.draft && socket.assigns.draft.id == version.id do
              {:noreply, push_navigate(socket, to: ~p"/recruiter/templates/#{template.id}")}
            else
              {:noreply,
               socket
               |> assign(:versions, Templates.list_versions(template.id))
               |> stamp_saved()}
            end

          {:error, :has_sessions} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "This version has sessions referencing it and can't be deleted."
             )}

          {:error, :is_current} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Can't delete the current version. Switch to another version first."
             )}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Could not delete version: #{inspect(reason)}")}
        end

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("set_current_version", %{"id" => version_id}, socket) do
    template = socket.assigns.template
    recruiter = socket.assigns.current_recruiter

    case Repo.get(Version, version_id) do
      %Version{} = version ->
        case Templates.set_current_version(template, version, actor_id: recruiter.id) do
          {:ok, updated_template} ->
            {:noreply,
             socket
             |> assign(:template, updated_template)
             |> assign(:current_version, version)
             |> stamp_saved()}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Could not switch version: #{inspect(reason)}")}
        end

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("new_draft", _params, socket) do
    case Templates.create_draft_version(socket.assigns.template) do
      {:ok, _draft} ->
        {:noreply,
         push_navigate(socket, to: ~p"/recruiter/templates/#{socket.assigns.template.id}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not open draft: #{inspect(reason)}")}
    end
  end

  # ---- Helpers ---------------------------------------------------------

  defp find_question(questions, id), do: Enum.find(questions, &(&1.id == id))

  defp cast_field("prompt_text", v), do: %{"prompt_text" => v}
  defp cast_field("notes", v), do: %{"notes" => v}
  defp cast_field("external_id", v), do: %{"external_id" => nil_if_blank(v)}
  defp cast_field("locale", v), do: %{"locale" => nil_if_blank(v)}
  defp cast_field("required", v), do: %{"required" => v in ["true", "on", true]}

  defp cast_field("tags", v) do
    list =
      v
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    %{"tags" => list}
  end

  defp cast_field(field, v)
       when field in ~w(think_time_seconds min_answer_seconds max_answer_seconds max_attempts_override) do
    %{field => parse_int(v)}
  end

  defp cast_field(field, v), do: %{field => v}

  defp nil_if_blank(nil), do: nil
  defp nil_if_blank(""), do: nil
  defp nil_if_blank(s), do: s

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_int(n) when is_integer(n), do: n

  defp refresh_questions(socket) do
    questions = Templates.list_questions(socket.assigns.draft)
    assets = load_assets_for(questions)

    socket
    |> assign(:questions, questions)
    |> assign(:assets, assets)
    |> stamp_saved()
  end

  defp stamp_saved(socket) do
    assign(socket, :saved_at, DateTime.utc_now())
  end

  # ---- Render ----------------------------------------------------------

  @impl true
  def render(%{not_found: true} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <h1 class="text-2xl">Template not found</h1>
      <p class="text-sm opacity-70">No template with id <code>{@template_id}</code>.</p>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div
        class="mx-auto max-w-4xl px-6 sm:px-10 py-12 sm:py-16 space-y-10"
        id="recruiter-template-editor"
      >
        <p class="zen-eyebrow">
          <.link
            navigate={~p"/recruiter/templates"}
            class="zen-link text-base-content/60 hover:text-base-content"
          >
            <span class="zen-arrow" aria-hidden="true">←</span>
            <span>All templates</span>
          </.link>
        </p>

        <header class="flex flex-wrap items-baseline justify-between gap-4">
          <div class="space-y-3">
            <p class="zen-eyebrow">§ — Template</p>
            <h1 class="font-display text-[clamp(2.5rem,7vw,4rem)] leading-[0.98] tracking-[-0.022em] font-light text-balance">
              {@template.name}
            </h1>
            <p
              :if={@template.description && @template.description != ""}
              class="text-[15px] leading-[1.65] text-base-content/70 max-w-[44ch]"
            >
              {@template.description}
            </p>
          </div>
          <p
            :if={@saved_at}
            id="saved-indicator"
            class="zen-eyebrow opacity-55"
          >
            Saved {format_time(@saved_at)}
          </p>
        </header>

        <section data-section-state={section_state(@collapsed_sections, :versions)}>
          <button
            type="button"
            phx-click="toggle_section"
            phx-value-section="versions"
            class="zen-eyebrow inline-flex items-baseline gap-2 cursor-pointer hover:text-base-content transition-colors"
          >
            <span
              class={[
                "transition-transform duration-300 inline-block",
                if(MapSet.member?(@collapsed_sections, :versions), do: "", else: "rotate-90")
              ]}
              aria-hidden="true"
            >
              ▸
            </span>
            <span>§ — Versions · {length(@versions)}</span>
          </button>
          <div class="section-shutter">
            <div class="pt-5">
              <ul class="space-y-2.5 text-[13.5px] font-mono" id="versions-list">
                <li
                  :for={v <- @versions}
                  class={[
                    "flex flex-wrap items-baseline gap-x-5 gap-y-1",
                    v.id == @draft.id && "text-base-content",
                    v.id != @draft.id && "text-base-content/65"
                  ]}
                >
                  <span class={["w-8 tabular-nums", v.id == @draft.id && "font-medium"]}>
                    v{v.version_number}
                  </span>
                  <span :if={v.published_at} class="text-base-content/55">
                    published {format_time(v.published_at)}
                  </span>
                  <span
                    :if={is_nil(v.published_at)}
                    class="zen-eyebrow normal-case tracking-[0.06em] text-[10.5px] opacity-75"
                  >
                    draft
                  </span>
                  <span
                    :if={@current_version && @current_version.id == v.id}
                    class="zen-eyebrow normal-case tracking-[0.06em] text-[10.5px] text-primary/85"
                  >
                    current
                  </span>
                  <button
                    :if={v.published_at && (!@current_version || @current_version.id != v.id)}
                    type="button"
                    phx-click="set_current_version"
                    phx-value-id={v.id}
                    data-confirm={"Make v#{v.version_number} the current version? Only new sessions are affected."}
                    class="zen-link text-base-content/55 hover:text-base-content text-[12.5px]"
                  >
                    <span class="zen-arrow" aria-hidden="true">↺</span>
                    <span>Use this version</span>
                  </button>
                  <button
                    :if={!@current_version || @current_version.id != v.id}
                    type="button"
                    phx-click="delete_version"
                    phx-value-id={v.id}
                    data-confirm={"Delete v#{v.version_number}? Refuses if any sessions reference it."}
                    class="zen-link text-error/55 hover:text-error text-[12.5px]"
                  >
                    <span>Delete</span>
                  </button>
                </li>
              </ul>
            </div>
          </div>
        </section>

        <section data-section-state={section_state(@collapsed_sections, :retake_policy)}>
          <button
            type="button"
            phx-click="toggle_section"
            phx-value-section="retake_policy"
            class="zen-eyebrow inline-flex items-baseline gap-2 cursor-pointer hover:text-base-content transition-colors"
          >
            <span
              class={[
                "transition-transform duration-300 inline-block",
                if(MapSet.member?(@collapsed_sections, :retake_policy), do: "", else: "rotate-90")
              ]}
              aria-hidden="true"
            >
              ▸
            </span>
            <span>§ — Retake policy</span>
          </button>
          <div class="section-shutter">
            <div class="pt-5">
              <%!--
                Wrap both inputs in a single <form phx-change>. Any change
                event then carries the CURRENT DOM value of EVERY named
                field — fixes the prior bug where typing '2' in max_attempts
                then clicking the mode select made the server overwrite
                max_attempts back to 1 (because the select fired phx-change
                before the input fired phx-blur, and the re-render used
                stale server state).
                phx-debounce keeps per-keystroke max_attempts changes from
                spamming the websocket.
              --%>
              <form
                phx-change="update_retake"
                phx-debounce="400"
                class="grid grid-cols-2 gap-x-10 gap-y-5 max-w-md"
              >
                <label class="block space-y-2">
                  <span class="zen-eyebrow opacity-65">Max attempts</span>
                  <input
                    type="number"
                    min="1"
                    value={@draft.retake_policy["max_attempts"]}
                    name="max_attempts"
                    class="input input-sm w-full"
                  />
                </label>
                <label class="block space-y-2">
                  <span class="zen-eyebrow opacity-65">Mode</span>
                  <select name="mode" class="select select-sm w-full">
                    <option value="first_only" selected={@draft.retake_policy["mode"] == "first_only"}>
                      first only
                    </option>
                    <option value="last" selected={@draft.retake_policy["mode"] == "last"}>
                      last
                    </option>
                  </select>
                </label>
              </form>
            </div>
          </div>
        </section>

        <section data-section-state={section_state(@collapsed_sections, :questions)}>
          <div class="flex items-baseline justify-between gap-4">
            <button
              type="button"
              phx-click="toggle_section"
              phx-value-section="questions"
              class="zen-eyebrow inline-flex items-baseline gap-2 cursor-pointer hover:text-base-content transition-colors"
            >
              <span
                class={[
                  "transition-transform duration-300 inline-block",
                  if(MapSet.member?(@collapsed_sections, :questions), do: "", else: "rotate-90")
                ]}
                aria-hidden="true"
              >
                ▸
              </span>
              <span>§ — Questions · {length(@questions)}</span>
            </button>
            <button
              phx-click="add_question"
              id="add-question"
              class="zen-link text-base-content/70 hover:text-base-content text-[13.5px]"
            >
              <span class="zen-arrow" aria-hidden="true">+</span>
              <span>Add question</span>
            </button>
          </div>

          <div class="section-shutter">
            <div class="pt-7">
              <ol class="space-y-12" id="questions-list">
                <li
                  :for={{q, idx} <- Enum.with_index(@questions)}
                  id={"question-#{q.id}"}
                  data-question-id={q.id}
                  data-section-state={section_state(@collapsed_questions, q.id)}
                  class="pt-7 border-t border-base-content/10 first:border-t-0 first:pt-0"
                >
                  <div class="flex items-baseline justify-between gap-4">
                    <button
                      type="button"
                      phx-click="toggle_question"
                      phx-value-id={q.id}
                      class="group flex items-baseline gap-4 min-w-0 flex-1 text-left cursor-pointer hover:text-base-content transition-colors"
                    >
                      <span
                        class={[
                          "transition-transform duration-300 inline-block text-[12px] text-base-content/55",
                          if(MapSet.member?(@collapsed_questions, q.id), do: "", else: "rotate-90")
                        ]}
                        aria-hidden="true"
                      >
                        ▸
                      </span>
                      <span class="font-display italic text-[1.3rem] text-base-content/45 tabular-nums leading-none shrink-0">
                        {String.pad_leading(to_string(q.position), 2, "0")}
                      </span>
                      <span class="text-[13.5px] text-base-content/65 truncate italic font-display">
                        {question_summary(q.prompt_text)}
                      </span>
                    </button>
                    <div class="flex items-baseline gap-6 text-[14px] shrink-0">
                      <button
                        phx-click="move"
                        phx-value-id={q.id}
                        phx-value-dir="up"
                        disabled={idx == 0}
                        class="zen-link text-base-content/55 hover:text-base-content disabled:opacity-25 disabled:cursor-not-allowed"
                        aria-label="Move up"
                      >
                        <span aria-hidden="true">↑</span>
                      </button>
                      <button
                        phx-click="move"
                        phx-value-id={q.id}
                        phx-value-dir="down"
                        disabled={idx == length(@questions) - 1}
                        class="zen-link text-base-content/55 hover:text-base-content disabled:opacity-25 disabled:cursor-not-allowed"
                        aria-label="Move down"
                      >
                        <span aria-hidden="true">↓</span>
                      </button>
                      <button
                        phx-click="delete_question"
                        phx-value-id={q.id}
                        data-confirm="Delete this question?"
                        class="zen-link text-error/65 hover:text-error"
                        aria-label="Delete"
                      >
                        <span aria-hidden="true">×</span>
                      </button>
                    </div>
                  </div>

                  <div class="section-shutter">
                    <div class="space-y-6 pt-6">
                      <label class="block space-y-2">
                        <span class="zen-eyebrow opacity-65">Prompt · markdown</span>
                        <textarea
                          rows="3"
                          phx-blur="update_field"
                          phx-value-id={q.id}
                          phx-value-field="prompt_text"
                          name="value"
                          class="textarea w-full leading-relaxed"
                        >{q.prompt_text}</textarea>
                      </label>

                      <div class="grid grid-cols-2 sm:grid-cols-4 gap-x-6 gap-y-4 items-stretch">
                        <label class="flex flex-col gap-2">
                          <span class="zen-eyebrow opacity-65 leading-tight">Think time · s</span>
                          <input
                            type="number"
                            min="1"
                            value={q.think_time_seconds}
                            phx-blur="update_field"
                            phx-value-id={q.id}
                            phx-value-field="think_time_seconds"
                            name="value"
                            class="input input-sm w-full mt-auto"
                          />
                        </label>
                        <label class="flex flex-col gap-2">
                          <span class="zen-eyebrow opacity-65 leading-tight">Min answer · s</span>
                          <input
                            type="number"
                            min="1"
                            value={q.min_answer_seconds}
                            phx-blur="update_field"
                            phx-value-id={q.id}
                            phx-value-field="min_answer_seconds"
                            name="value"
                            class="input input-sm w-full mt-auto"
                          />
                        </label>
                        <label class="flex flex-col gap-2">
                          <span class="zen-eyebrow opacity-65 leading-tight">Max answer · s</span>
                          <input
                            type="number"
                            min="1"
                            value={q.max_answer_seconds}
                            phx-blur="update_field"
                            phx-value-id={q.id}
                            phx-value-field="max_answer_seconds"
                            name="value"
                            class="input input-sm w-full mt-auto"
                          />
                        </label>
                        <label class="flex flex-col gap-2">
                          <span class="zen-eyebrow opacity-65 leading-tight">
                            Max attempts override
                          </span>
                          <input
                            type="number"
                            min="1"
                            value={q.max_attempts_override}
                            phx-blur="update_field"
                            phx-value-id={q.id}
                            phx-value-field="max_attempts_override"
                            name="value"
                            class="input input-sm w-full mt-auto"
                          />
                        </label>
                      </div>

                      <div
                        class="flex flex-wrap items-baseline gap-x-7 gap-y-3 text-[13.5px]"
                        id={"prompt-#{q.id}"}
                      >
                        <%= if q.prompt_asset_id do %>
                          <span class="zen-eyebrow normal-case tracking-[0.06em] text-[10.5px] text-success/80">
                            prompt · {asset_label(@assets, q.prompt_asset_id)}
                          </span>
                          <.link
                            navigate={
                              ~p"/recruiter/templates/#{@template.id}/questions/#{q.id}/prompt"
                            }
                            class="zen-link text-base-content/65 hover:text-base-content"
                          >
                            <span class="zen-arrow" aria-hidden="true">↺</span>
                            <span>Replace</span>
                          </.link>
                          <button
                            phx-click="remove_prompt_asset"
                            phx-value-id={q.id}
                            data-confirm="Remove prompt video?"
                            class="zen-link text-base-content/50 hover:text-base-content"
                          >
                            <span>Remove</span>
                          </button>
                        <% else %>
                          <.link
                            navigate={
                              ~p"/recruiter/templates/#{@template.id}/questions/#{q.id}/prompt"
                            }
                            class="zen-link text-base-content/70 hover:text-base-content"
                          >
                            <span class="zen-arrow" aria-hidden="true">●</span>
                            <span>Record prompt</span>
                          </.link>
                        <% end %>

                        <span class="opacity-25" aria-hidden="true">·</span>

                        <%= if q.attachment_asset_id do %>
                          <span class="zen-eyebrow normal-case tracking-[0.06em] text-[10.5px] opacity-70">
                            attachment · {asset_label(@assets, q.attachment_asset_id)}
                          </span>
                          <button
                            phx-click="remove_attachment"
                            phx-value-id={q.id}
                            data-confirm="Remove attachment?"
                            class="zen-link text-base-content/50 hover:text-base-content"
                          >
                            <span>Remove</span>
                          </button>
                        <% else %>
                          <form
                            id={"attach-form-#{q.id}"}
                            phx-hook="AttachmentForm"
                            action={
                              ~p"/recruiter/templates/#{@template.id}/questions/#{q.id}/attachment"
                            }
                            method="post"
                            enctype="multipart/form-data"
                            class="inline-flex items-baseline"
                          >
                            <input
                              type="hidden"
                              name="_csrf_token"
                              value={Phoenix.Controller.get_csrf_token()}
                            />
                            <label class="zen-link text-base-content/70 hover:text-base-content cursor-pointer">
                              <span class="zen-arrow" aria-hidden="true">↑</span>
                              <span>Attach image or PDF</span>
                              <input
                                type="file"
                                name="attachment"
                                accept="image/*,application/pdf"
                                class="sr-only"
                              />
                            </label>
                          </form>
                        <% end %>
                      </div>

                      <div class="grid grid-cols-1 sm:grid-cols-[max-content_1fr_1fr] gap-x-8 gap-y-4 items-baseline">
                        <label class="inline-flex items-center gap-2.5 text-[13.5px] cursor-pointer">
                          <input
                            type="checkbox"
                            checked={q.required}
                            phx-click="update_field"
                            phx-value-id={q.id}
                            phx-value-field="required"
                            phx-value-value={!q.required && "true"}
                            class="checkbox checkbox-sm"
                          />
                          <span class="zen-eyebrow normal-case tracking-[0.06em] text-[11px] opacity-80">
                            Required
                          </span>
                        </label>
                        <label class="block space-y-2">
                          <span class="zen-eyebrow opacity-65">Tags · comma-separated</span>
                          <input
                            type="text"
                            value={Enum.join(q.tags || [], ", ")}
                            phx-blur="update_field"
                            phx-value-id={q.id}
                            phx-value-field="tags"
                            name="value"
                            class="input input-sm w-full"
                          />
                        </label>
                        <label class="block space-y-2">
                          <span class="zen-eyebrow opacity-65">External id</span>
                          <input
                            type="text"
                            value={q.external_id}
                            phx-blur="update_field"
                            phx-value-id={q.id}
                            phx-value-field="external_id"
                            name="value"
                            class="input input-sm w-full"
                          />
                        </label>
                      </div>
                    </div>
                  </div>
                </li>
              </ol>
            </div>
          </div>
        </section>

        <section class="space-y-4 pt-6 border-t border-base-content/10">
          <button
            phx-click="publish"
            id="publish-btn"
            class="zen-link text-base-content text-[15px]"
          >
            <span class="zen-arrow" aria-hidden="true">→</span>
            <span>Publish draft as v{@draft.version_number}</span>
          </button>
          <p class="text-[13px] text-base-content/55 max-w-[60ch] leading-relaxed">
            Sessions already in flight keep their frozen template version;
            only new sessions reference the published one.
          </p>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp section_state(collapsed, key) do
    if MapSet.member?(collapsed, key), do: "closed", else: "open"
  end

  defp question_summary(prompt_text) when is_binary(prompt_text) do
    prompt_text
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
    |> case do
      "" -> "(empty)"
      s when byte_size(s) > 60 -> String.slice(s, 0, 60) <> "…"
      s -> s
    end
  end

  defp question_summary(_), do: "(empty)"

  defp format_time(nil), do: ""

  defp format_time(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> DateTime.to_string()
  end

  defp asset_label(assets, asset_id) do
    case Map.get(assets, asset_id) do
      nil -> "(missing)"
      %PromptAsset{state: state, kind: kind} -> "#{kind} (#{state})"
    end
  end
end
