defmodule InterviewWeb.HarnessRouterTest do
  use Interview.DataCase, async: true

  alias Interview.Capture.Session
  alias Interview.Tenants.Tenant
  alias Interview.Templates.{Question, Template, Version}
  alias Interview.Repo

  defp seed_dev_tenant_graph do
    {:ok, tenant} =
      %Tenant{}
      |> Tenant.changeset(%{name: "Dev Tenant", slug: "dev", frame_ancestors: ["'self'"]})
      |> Repo.insert()

    {:ok, template} =
      %Template{}
      |> Template.changeset(%{tenant_id: tenant.id, name: "Dev Template"})
      |> Repo.insert()

    {:ok, version} =
      %Version{}
      |> Version.changeset(%{
        template_id: template.id,
        version_number: 1,
        published_at: DateTime.utc_now()
      })
      |> Repo.insert()

    {:ok, _} =
      %Question{}
      |> Question.changeset(%{
        template_version_id: version.id,
        position: 1,
        prompt_text: "Q",
        max_answer_seconds: 60,
        required: true
      })
      |> Repo.insert()

    {:ok, template} =
      template
      |> Template.changeset(%{current_version_id: version.id})
      |> Repo.update()

    %{tenant: tenant, template: template, version: version}
  end

  defp call(method, path, body \\ nil) do
    conn =
      Plug.Test.conn(method, path, body)
      |> Plug.Conn.put_req_header("content-type", "application/json")

    InterviewWeb.HarnessRouter.call(conn, InterviewWeb.HarnessRouter.init([]))
  end

  test "POST /session mints a fresh dev-tenant session + bootstrap" do
    %{tenant: tenant, version: version} = seed_dev_tenant_graph()

    conn = call(:post, "/session")
    assert conn.status == 200
    %{"session_id" => sid, "bootstrap_token" => token} = Jason.decode!(conn.resp_body)
    assert is_binary(sid)
    assert is_binary(token)

    session = Repo.get!(Session, sid)
    assert session.tenant_id == tenant.id
    assert session.template_version_id == version.id
    refute is_nil(session.bootstrap_jti)
  end

  test "POST /session/:id/bootstrap rotates the jti" do
    seed_dev_tenant_graph()

    %{"session_id" => sid, "bootstrap_token" => first} =
      call(:post, "/session") |> Map.fetch!(:resp_body) |> Jason.decode!()

    %{"bootstrap_token" => second} =
      call(:post, "/session/#{sid}/bootstrap")
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()

    refute first == second
    assert {:error, :invalid} = Interview.Auth.Bootstrap.consume(first)
    assert {:ok, _} = Interview.Auth.Bootstrap.consume(second)
  end

  test "POST /session/:id/bootstrap rejects sessions outside the dev tenant" do
    seed_dev_tenant_graph()

    {:ok, other} =
      %Tenant{}
      |> Tenant.changeset(%{name: "Other", slug: "other-#{System.unique_integer([:positive])}"})
      |> Repo.insert()

    other_template = Interview.Fixtures.template!(other.id)
    other_version = Interview.Fixtures.version!(other_template.id)
    other_session = Interview.Fixtures.session!(other.id, other_version.id)

    conn = call(:post, "/session/#{other_session.id}/bootstrap")
    assert conn.status == 404
  end

  test "POST /session 500s when the dev tenant isn't seeded" do
    conn = call(:post, "/session")
    assert conn.status == 500
    assert Jason.decode!(conn.resp_body) == %{"error" => "dev_tenant_missing"}
  end

  test "GET / serves the harness page that loads the embed SDK" do
    conn = call(:get, "/")
    assert conn.status == 200
    body = to_string(conn.resp_body)

    # The harness drives the SDK; it must pull the bundle from the recorder
    # origin so we genuinely exercise cross-origin distribution.
    assert body =~ ~s|src="http://localhost:4000/embed.v1.js"|

    # And it must call YourInterview.mount — proves we're on the SDK path,
    # not the URL-fallback iframe path the Phase-0 harness used.
    assert body =~ "YourInterview.mount"
  end
end
