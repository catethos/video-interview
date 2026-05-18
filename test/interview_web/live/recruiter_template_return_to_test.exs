defmodule InterviewWeb.RecruiterTemplateReturnToTest do
  @moduledoc """
  Integration tests for the deep-link template-creation handoff
  (PLAN §8.5 change 1). Covers:

    * /recruiter/templates/new creates a template + draft and forwards
      `return_to`/`state` to the editor
    * /recruiter/templates/:id with a whitelisted `return_to` stashes
      it in assigns
    * Publish on a return_to-aware LiveView redirects externally
      with the template UUIDs + echoed `state`
    * Non-whitelisted `return_to` is silently dropped — recruiter
      still gets the normal post-publish flow
  """
  use InterviewWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Interview.Fixtures
  alias Interview.Repo
  alias Interview.Templates

  setup %{conn: conn} do
    tenant =
      Fixtures.tenant!(%{
        allowed_return_origins: ["https://pulsifi.demo", "http://localhost:4001"]
      })

    recruiter = Fixtures.recruiter!(tenant.id)
    token = Fixtures.recruiter_session_token!(recruiter)
    conn = Plug.Test.init_test_session(conn, %{recruiter_token: token})

    %{conn: conn, tenant: tenant, recruiter: recruiter}
  end

  describe "/recruiter/templates/new" do
    test "creates a template + draft and forwards return_to + state", %{conn: conn} do
      params = %{
        "return_to" => "https://pulsifi.demo/api/jobs/abc/vi-template-callback",
        "state" => "signed-state-token",
        "name" => "Senior Engineer Screening"
      }

      {:error, {:live_redirect, %{to: target}}} =
        live(conn, "/recruiter/templates/new?" <> URI.encode_query(params))

      uri = URI.parse(target)
      assert uri.path =~ ~r"^/recruiter/templates/[a-f0-9-]{36}$"
      decoded = URI.decode_query(uri.query)
      assert decoded["return_to"] == params["return_to"]
      assert decoded["state"] == params["state"]

      # Template + draft both exist under the recruiter's tenant.
      "/recruiter/templates/" <> template_id = uri.path

      %{template: template, draft_version: draft} =
        Templates.get_template_with_current_version(template_id)

      assert template.name == "Senior Engineer Screening"
      assert draft, "a draft version should have been created"
    end

    test "default name is used when none is supplied", %{conn: conn} do
      {:error, {:live_redirect, %{to: target}}} = live(conn, "/recruiter/templates/new")

      "/recruiter/templates/" <> template_id = URI.parse(target).path
      %{template: t} = Templates.get_template_with_current_version(template_id)
      assert t.name =~ "Untitled interview"
    end
  end

  describe "/recruiter/templates/:id with return_to" do
    test "publish redirects externally with template ids + echoed state", %{
      conn: conn,
      tenant: tenant
    } do
      template = Fixtures.template!(tenant.id, %{name: "Acme"})
      draft = Fixtures.version!(template.id, %{version_number: 1})
      _q = Fixtures.question!(draft.id, 1, %{prompt_text: "Tell me about a time…"})

      params = %{
        "return_to" => "https://pulsifi.demo/cb",
        "state" => "abc.xyz"
      }

      {:ok, view, _html} =
        live(conn, "/recruiter/templates/#{template.id}?" <> URI.encode_query(params))

      result = render_hook(view, "publish", %{})

      # External redirects come back as {:error, {:redirect, %{to: "https://...", status: 302}}}
      # — Phoenix uses `:to` for both internal and external; internal redirects
      # use `{:live_redirect, ...}` instead.
      assert {:error, {:redirect, %{to: external, status: 302}}} = result

      uri = URI.parse(external)
      assert uri.scheme == "https"
      assert uri.host == "pulsifi.demo"
      assert uri.path == "/cb"

      decoded = URI.decode_query(uri.query)
      assert decoded["state"] == "abc.xyz"
      assert decoded["template_id"] == template.id
      # The published version is the just-published draft.
      published = Repo.get(Interview.Templates.Version, decoded["template_version_id"])
      assert published.template_id == template.id
      refute is_nil(published.published_at)
    end

    test "non-whitelisted return_to is silently ignored; publish goes to detail page", %{
      conn: conn,
      tenant: tenant
    } do
      template = Fixtures.template!(tenant.id, %{name: "Acme"})
      draft = Fixtures.version!(template.id, %{version_number: 1})
      _q = Fixtures.question!(draft.id, 1, %{prompt_text: "Q1"})

      params = %{
        "return_to" => "https://evil.example/cb",
        "state" => "abc"
      }

      {:ok, view, _html} =
        live(conn, "/recruiter/templates/#{template.id}?" <> URI.encode_query(params))

      result = render_hook(view, "publish", %{})

      # Falls through to the normal push_navigate to the detail page.
      assert {:error, {:live_redirect, %{to: target}}} = result
      assert target == "/recruiter/templates/#{template.id}"
    end

    test "no return_to → normal publish flow", %{conn: conn, tenant: tenant} do
      template = Fixtures.template!(tenant.id, %{name: "Acme"})
      draft = Fixtures.version!(template.id, %{version_number: 1})
      _q = Fixtures.question!(draft.id, 1, %{prompt_text: "Q1"})

      {:ok, view, _html} = live(conn, "/recruiter/templates/#{template.id}")

      assert {:error, {:live_redirect, %{to: target}}} = render_hook(view, "publish", %{})
      assert target == "/recruiter/templates/#{template.id}"
    end
  end
end
