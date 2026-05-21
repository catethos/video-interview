defmodule InterviewWeb.RecruiterTemplateLiveTest do
  use InterviewWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias Interview.Fixtures
  alias Interview.Templates

  setup %{conn: conn} do
    tenant = Fixtures.tenant!()
    recruiter = Fixtures.recruiter!(tenant.id)
    token = Fixtures.recruiter_session_token!(recruiter)
    template = Fixtures.template!(tenant.id, %{name: "Acme SDR"})
    v1 = Fixtures.version!(template.id, %{version_number: 1})
    _ = Fixtures.question!(v1.id, 1, %{prompt_text: "Q1"})
    _ = Fixtures.question!(v1.id, 2, %{prompt_text: "Q2"})
    {:ok, _} = Templates.publish_draft(v1)

    conn = Plug.Test.init_test_session(conn, %{recruiter_token: token})

    %{conn: conn, tenant: tenant, recruiter: recruiter, template: template, v1: v1}
  end

  test "mounts and shows the template name", %{conn: conn, template: template} do
    {:ok, _view, html} = live(conn, ~p"/recruiter/templates/#{template.id}")
    assert html =~ "Acme SDR"
    # Each question renders its prompt_text in the textarea; position is
    # shown as "01"/"02" italic numerals.
    assert html =~ ">Q1</textarea>"
    assert html =~ ">Q2</textarea>"
  end

  test "autosave on a question field persists the draft", %{conn: conn, template: template} do
    {:ok, view, _html} = live(conn, ~p"/recruiter/templates/#{template.id}")

    %{draft_version: draft} = Templates.get_template_with_current_version(template.id)
    assert draft

    [q1 | _] = Templates.list_questions(draft)

    render_hook(view, "update_field", %{
      "id" => q1.id,
      "field" => "prompt_text",
      "value" => "Edited prompt"
    })

    reloaded = Templates.get_question!(q1.id)
    assert reloaded.prompt_text == "Edited prompt"
  end

  test "update_retake persists the mode selection (regression)",
       %{conn: conn, template: template} do
    # Reported by live test: recruiter selected 'last' mode in the
    # select on the editor, but DB still showed 'first_only'. Repro
    # by triggering phx-change the way the browser would — element-
    # targeted so the form-field collection logic runs.
    {:ok, view, _html} = live(conn, ~p"/recruiter/templates/#{template.id}")

    %{draft_version: draft} = Templates.get_template_with_current_version(template.id)
    assert draft
    assert draft.retake_policy["mode"] == "first_only"

    # Both inputs live inside a wrapping <form phx-change="update_retake">
    # now, so any change submits BOTH fields together. Drive the form
    # to mimic the recruiter selecting 'last' while max_attempts holds
    # the rendered value (server-side state).
    view
    |> form(~s|form[phx-change="update_retake"]|, %{
      "max_attempts" => "#{draft.retake_policy["max_attempts"]}",
      "mode" => "last"
    })
    |> render_change()

    reloaded = Interview.Repo.get!(Interview.Templates.Version, draft.id)

    assert reloaded.retake_policy["mode"] == "last",
           "expected mode 'last' to persist, got: #{inspect(reloaded.retake_policy)}"
  end

  test "reorder via move event persists", %{conn: conn, template: template} do
    {:ok, view, _html} = live(conn, ~p"/recruiter/templates/#{template.id}")
    %{draft_version: draft} = Templates.get_template_with_current_version(template.id)
    [q1, q2] = Templates.list_questions(draft)

    render_hook(view, "move", %{"id" => q1.id, "dir" => "down"})

    [first, second] = Templates.list_questions(draft)
    assert first.id == q2.id
    assert second.id == q1.id
  end

  test "without recruiter session redirects to /auth/sign-in", %{template: template} do
    conn = build_conn() |> Plug.Test.init_test_session(%{})

    assert {:error, {:redirect, %{to: "/auth/sign-in"}}} =
             live(conn, ~p"/recruiter/templates/#{template.id}")
  end

  test "cross-tenant template renders as not_found", %{conn: conn} do
    other = Fixtures.tenant!()
    other_template = Fixtures.template!(other.id, %{name: "Other"})

    {:ok, _view, html} = live(conn, ~p"/recruiter/templates/#{other_template.id}")
    assert html =~ "not found" or html =~ "Not found" or html =~ "404"
  end

  test "delete_version removes an old published version with no sessions",
       %{conn: conn, template: template, v1: v1} do
    # Publish v2 so v2 becomes current and v1 is non-current.
    {:ok, draft2} = Templates.create_draft_version(template)
    _ = Fixtures.question!(draft2.id, 1, %{prompt_text: "v2 Q1"})
    {:ok, _v2} = Templates.publish_draft(draft2)

    {:ok, view, _html} = live(conn, ~p"/recruiter/templates/#{template.id}")

    view
    |> element(~s|button[phx-click="delete_version"][phx-value-id="#{v1.id}"]|)
    |> render_click()

    refute Templates.Version |> Interview.Repo.get(v1.id)
  end

  test "delete_version succeeds when the referencing sessions are all soft-deleted",
       %{conn: conn, tenant: tenant, template: template, v1: v1} do
    # v2 takes over as current.
    {:ok, draft2} = Templates.create_draft_version(template)
    _ = Fixtures.question!(draft2.id, 1, %{prompt_text: "v2 Q1"})
    {:ok, _v2} = Templates.publish_draft(draft2)

    session = Fixtures.session!(tenant.id, v1.id)
    # Mark soft-deleted directly (skips Oban job) — same row state as if
    # the recruiter had clicked Delete in the sessions list.
    {1, _} =
      Interview.Repo.update_all(
        from(s in Interview.Capture.Session, where: s.id == ^session.id),
        set: [deleted_at: DateTime.utc_now()]
      )

    {:ok, view, _html} = live(conn, ~p"/recruiter/templates/#{template.id}")

    view
    |> element(~s|button[phx-click="delete_version"][phx-value-id="#{v1.id}"]|)
    |> render_click()

    refute Interview.Repo.get(Templates.Version, v1.id)
    refute Interview.Repo.get(Interview.Capture.Session, session.id)
  end

  test "delete_version refuses when sessions reference the version", %{
    conn: conn,
    tenant: tenant,
    template: template,
    v1: v1
  } do
    # Park a session on v1 to block deletion.
    {:ok, draft2} = Templates.create_draft_version(template)
    _ = Fixtures.question!(draft2.id, 1, %{prompt_text: "v2 Q1"})
    {:ok, _v2} = Templates.publish_draft(draft2)
    _ = Fixtures.session!(tenant.id, v1.id)

    {:ok, view, _html} = live(conn, ~p"/recruiter/templates/#{template.id}")

    view
    |> element(~s|button[phx-click="delete_version"][phx-value-id="#{v1.id}"]|)
    |> render_click()

    assert render(view) =~ "sessions referencing it"
    assert Templates.Version |> Interview.Repo.get(v1.id)
  end

  test "set_current_version flips the template pointer back to an older published version",
       %{conn: conn, template: template, v1: v1} do
    # Publish a second version so we have two published versions to choose between.
    {:ok, draft2} = Templates.create_draft_version(template)
    _ = Fixtures.question!(draft2.id, 1, %{prompt_text: "v2 Q1"})
    {:ok, v2} = Templates.publish_draft(draft2)

    # Sanity: v2 is now current (publish flips the pointer).
    template = Templates.get_template!(template.id)
    assert template.current_version_id == v2.id

    {:ok, view, _html} = live(conn, ~p"/recruiter/templates/#{template.id}")

    # Click "Use this version" on the v1 row.
    view
    |> element(~s|button[phx-click="set_current_version"][phx-value-id="#{v1.id}"]|)
    |> render_click()

    reloaded = Templates.get_template!(template.id)
    assert reloaded.current_version_id == v1.id
  end

  test "publish creates a new version and flips current_version_id", %{
    conn: conn,
    template: template
  } do
    {:ok, view, _html} = live(conn, ~p"/recruiter/templates/#{template.id}")

    %{current_version: before, draft_version: draft_before} =
      Templates.get_template_with_current_version(template.id)

    # Edit something so the draft is meaningfully different.
    [q1 | _] = Templates.list_questions(draft_before)

    render_hook(view, "update_field", %{
      "id" => q1.id,
      "field" => "prompt_text",
      "value" => "Edited"
    })

    # Publish navigates back to the same URL.
    assert {:error, {:live_redirect, %{to: _path}}} =
             render_hook(view, "publish", %{})

    %{current_version: after_pub} = Templates.get_template_with_current_version(template.id)
    assert after_pub.id != before.id
    assert after_pub.published_at
  end
end
