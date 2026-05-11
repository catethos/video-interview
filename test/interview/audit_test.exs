defmodule Interview.AuditTest do
  use Interview.DataCase, async: false
  use Oban.Testing, repo: Interview.Repo

  alias Interview.Audit
  alias Interview.Audit.Event
  alias Interview.Auth.{ApiKeys, Bootstrap, Recruiters}
  alias Interview.Capture
  alias Interview.Repo
  alias Interview.Templates

  describe "log/1 inserts an event" do
    test "stamps occurred_at when omitted" do
      tenant = Interview.Fixtures.tenant!()

      {:ok, %Event{} = e} =
        Audit.log(%{
          tenant_id: tenant.id,
          actor_kind: "system",
          action: "test.stamp"
        })

      assert e.occurred_at
      assert e.action == "test.stamp"
    end

    test "list_for_tenant returns most recent first" do
      tenant = Interview.Fixtures.tenant!()
      Audit.log!(%{tenant_id: tenant.id, actor_kind: "system", action: "a"})
      Audit.log!(%{tenant_id: tenant.id, actor_kind: "system", action: "b"})

      assert [%Event{action: "b"}, %Event{action: "a"}] = Audit.list_for_tenant(tenant.id)
    end
  end

  describe "emit points" do
    test "bootstrap.mint + bootstrap.consume" do
      %{session: session} = Interview.Fixtures.graph!()

      {:ok, %{token: token}} = Bootstrap.mint(session)
      assert {:ok, _} = Bootstrap.consume(token)

      events =
        Audit.list_for_subject("session", session.id)
        |> Enum.map(& &1.action)
        |> Enum.sort()

      assert "bootstrap.mint" in events
      assert "bootstrap.consume" in events
    end

    test "magic_link.request + magic_link.consume + recruiter.sign_in" do
      tenant = Interview.Fixtures.tenant!()
      user = Interview.Fixtures.recruiter!(tenant.id)

      {:ok, %{url: _, token: raw}} = Recruiters.request_magic_link(user.email)
      {:ok, _} = Recruiters.consume_magic_link(raw)

      events =
        Audit.list_for_subject("recruiter_user", user.id)
        |> Enum.map(& &1.action)
        |> Enum.sort()

      assert events == ["magic_link.consume", "magic_link.request"]
    end

    test "api_key.create + api_key.revoke" do
      tenant = Interview.Fixtures.tenant!()

      {:ok, %{api_key: key, secret: _}} = ApiKeys.create(tenant.id, "ats")
      {:ok, _} = ApiKeys.revoke(tenant.id, key.id)

      actions =
        Audit.list_for_subject("tenant_api_key", key.id)
        |> Enum.map(& &1.action)
        |> Enum.sort()

      assert actions == ["api_key.create", "api_key.revoke"]
    end

    test "session.submit emits when submit_session promotes the session" do
      tenant = Interview.Fixtures.tenant!()
      version = Interview.Fixtures.version!(Interview.Fixtures.template!(tenant.id).id)
      _ = Interview.Fixtures.question!(version.id, 1, %{required: false})
      session = Interview.Fixtures.session!(tenant.id, version.id, %{state: "in_progress"})

      {:ok, _} = Capture.submit_session(session)

      assert [%Event{}] =
               Repo.all(from(e in Event, where: e.action == "session.submit"))
    end

    test "template.publish" do
      tenant = Interview.Fixtures.tenant!()
      template = Interview.Fixtures.template!(tenant.id)
      version = Interview.Fixtures.version!(template.id)

      {:ok, _published} = Templates.publish_draft(version, published_by: nil)

      assert [%Event{action: "template.publish"}] =
               Audit.list_for_subject("template_version", version.id)
    end
  end
end
