defmodule InterviewWeb.SessionControllerTest do
  use InterviewWeb.ConnCase, async: true

  alias Interview.Auth.{Bootstrap, Tokens}
  alias Interview.Capture.Session
  alias Interview.Fixtures
  alias Interview.Repo
  alias Interview.Templates

  defp authed_conn(conn, secret) do
    conn
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> secret)
  end

  setup do
    tenant = Fixtures.tenant!()
    {_key, secret} = Fixtures.api_key!(tenant.id)
    template = Fixtures.template!(tenant.id, %{name: "T"})
    version = Fixtures.version!(template.id)
    Fixtures.question!(version.id, 1)
    {:ok, _published_version} = Templates.publish_draft(version)
    template = Repo.get!(Interview.Templates.Template, template.id)

    %{tenant: tenant, secret: secret, template: template, version: version}
  end

  describe "POST /api/sessions" do
    test "creates a session with template_id (resolves to current_version_id) + bootstrap",
         %{conn: conn, tenant: tenant, secret: secret, template: template, version: version} do
      conn =
        conn
        |> authed_conn(secret)
        |> post(~p"/api/sessions", Jason.encode!(%{"template_id" => template.id}))

      assert %{
               "id" => sid,
               "bootstrap_token" => token,
               "template_version_id" => returned_vid
             } =
               json_response(conn, 201)

      assert returned_vid == version.id

      assert {:ok, %Session{template_version_id: ^returned_vid, tenant_id: tid}} =
               {:ok, Repo.get!(Session, sid)}

      assert tid == tenant.id

      # bootstrap is consumable exactly once
      assert {:ok, %Session{}} = Bootstrap.consume(token)
      assert {:error, :consumed} = Bootstrap.consume(token)
    end

    test "creates a session with explicit template_version_id",
         %{conn: conn, secret: secret, version: version} do
      conn =
        conn
        |> authed_conn(secret)
        |> post(~p"/api/sessions", Jason.encode!(%{"template_version_id" => version.id}))

      assert %{"template_version_id" => vid} = json_response(conn, 201)
      assert vid == version.id
    end

    test "rejects template_version_id from another tenant", %{conn: conn, secret: secret} do
      other = Fixtures.tenant!()
      other_template = Fixtures.template!(other.id)
      other_version = Fixtures.version!(other_template.id)

      conn =
        conn
        |> authed_conn(secret)
        |> post(~p"/api/sessions", Jason.encode!(%{"template_version_id" => other_version.id}))

      assert json_response(conn, 404) == %{"error" => "template_version_not_found"}
    end

    test "401 without auth", %{conn: conn, template: template} do
      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post(~p"/api/sessions", Jason.encode!(%{"template_id" => template.id}))

      assert json_response(conn, 401)
    end

    test "422 with no template ref", %{conn: conn, secret: secret} do
      conn =
        conn
        |> authed_conn(secret)
        |> post(~p"/api/sessions", Jason.encode!(%{}))

      assert %{"error" => "template_id_or_template_version_id_required"} =
               json_response(conn, 422)
    end
  end

  describe "POST /api/sessions/:id/bootstrap" do
    test "rotates the jti, invalidating prior token", %{
      conn: conn,
      secret: secret,
      template: template
    } do
      conn1 =
        conn
        |> authed_conn(secret)
        |> post(~p"/api/sessions", Jason.encode!(%{"template_id" => template.id}))

      %{"id" => sid, "bootstrap_token" => first_token} = json_response(conn1, 201)

      conn2 =
        build_conn()
        |> authed_conn(secret)
        |> post(~p"/api/sessions/#{sid}/bootstrap", Jason.encode!(%{}))

      %{"bootstrap_token" => new_token} = json_response(conn2, 200)
      refute new_token == first_token

      assert {:error, :invalid} = Bootstrap.consume(first_token)
      assert {:ok, _} = Bootstrap.consume(new_token)
    end

    test "404 cross-tenant", %{conn: conn} do
      tenant_a = Fixtures.tenant!()
      tenant_b = Fixtures.tenant!()
      {_key, key_b} = Fixtures.api_key!(tenant_b.id)

      template_a = Fixtures.template!(tenant_a.id)
      version_a = Fixtures.version!(template_a.id)

      session =
        Fixtures.session!(tenant_a.id, version_a.id)

      conn =
        conn
        |> authed_conn(key_b)
        |> post(~p"/api/sessions/#{session.id}/bootstrap", Jason.encode!(%{}))

      assert json_response(conn, 404)
    end
  end

  test "returned token claims are bound to the session" do
    tenant = Fixtures.tenant!()
    {_key, secret} = Fixtures.api_key!(tenant.id)
    template = Fixtures.template!(tenant.id)
    version = Fixtures.version!(template.id)

    {:ok, _} = Interview.Templates.publish_draft(version)

    template = Repo.get!(Interview.Templates.Template, template.id)

    conn =
      build_conn()
      |> authed_conn(secret)
      |> post(~p"/api/sessions", Jason.encode!(%{"template_id" => template.id}))

    %{"id" => sid, "bootstrap_token" => token} = json_response(conn, 201)
    assert {:ok, %{sid: ^sid, tid: tid}} = Tokens.verify_bootstrap(token)
    assert tid == tenant.id
  end
end
