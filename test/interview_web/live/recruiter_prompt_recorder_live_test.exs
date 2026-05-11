defmodule InterviewWeb.RecruiterPromptRecorderLiveTest do
  use InterviewWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query, only: [from: 2]

  alias Interview.Fixtures
  alias Interview.PromptAssets
  alias Interview.Repo
  alias Interview.Templates
  alias Interview.Templates.{PromptAsset, Question}

  setup %{conn: conn} do
    tenant = Fixtures.tenant!()
    recruiter = Fixtures.recruiter!(tenant.id)
    token = Fixtures.recruiter_session_token!(recruiter)
    template = Fixtures.template!(tenant.id)
    v1 = Fixtures.version!(template.id)
    q1 = Fixtures.question!(v1.id, 1, %{prompt_text: "Tell us about yourself"})
    {:ok, _} = Templates.publish_draft(v1)
    # Re-fetch the draft (publish creates a new draft? No — publish does not.
    # Mount of RecruiterTemplateLive auto-creates a draft if missing. The
    # prompt-recorder route uses the existing question id directly without
    # caring whether the version is published or draft, but writing
    # `prompt_asset_id` via `Templates.update_draft_question/2` requires the
    # version to be unpublished. So land the question on a fresh draft.)
    {:ok, draft} = Templates.create_draft_version(Templates.get_template!(template.id))
    draft_q = Repo.one(from q in Question, where: q.template_version_id == ^draft.id)

    conn = Plug.Test.init_test_session(conn, %{recruiter_token: token})

    %{
      conn: conn,
      tenant: tenant,
      recruiter: recruiter,
      template: template,
      question: draft_q
    }
  end

  test "mount creates a recording asset and renders the recorder shell",
       %{conn: conn, tenant: t, template: tpl, question: q} do
    {:ok, _view, html} =
      live(conn, ~p"/recruiter/templates/#{tpl.id}/questions/#{q.id}/prompt")

    assert html =~ "Record prompt"
    assert html =~ q.prompt_text
    assert html =~ ~s(phx-hook="RecruiterRecorder")

    # Exactly one fresh asset for this tenant in `recording` state.
    [asset] = PromptAssets.list(t.id, state: "recording")
    assert asset.kind == "video"
    assert asset.capture_instance_id
  end

  test "404 for a question not on this template",
       %{conn: conn, template: tpl} do
    other_tenant = Fixtures.tenant!()
    other_tpl = Fixtures.template!(other_tenant.id)
    other_v = Fixtures.version!(other_tpl.id)
    other_q = Fixtures.question!(other_v.id, 1, %{prompt_text: "X"})

    {:ok, _view, html} =
      live(conn, ~p"/recruiter/templates/#{tpl.id}/questions/#{other_q.id}/prompt")

    assert html =~ "not found"
  end

  test "set_as_prompt only works once the asset is ready",
       %{conn: conn, tenant: t, template: tpl, question: q} do
    {:ok, view, _html} =
      live(conn, ~p"/recruiter/templates/#{tpl.id}/questions/#{q.id}/prompt")

    [asset] = PromptAssets.list(t.id, state: "recording")

    # Recording → set_as_prompt is a no-op flash error.
    render_hook(view, "set_as_prompt", %{})
    refreshed = Repo.get!(Question, q.id)
    assert is_nil(refreshed.prompt_asset_id)

    # Promote to ready out-of-band, then re-trigger.
    Repo.update_all(
      from(a in PromptAsset, where: a.id == ^asset.id),
      set: [state: "ready", storage_key: "tests/x.mp4"]
    )

    assert {:error, {:live_redirect, %{to: target}}} =
             render_hook(view, "set_as_prompt", %{})

    assert target =~ "/recruiter/templates/#{tpl.id}"
    refreshed = Repo.get!(Question, q.id)
    assert refreshed.prompt_asset_id == asset.id
  end
end
