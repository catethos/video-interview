defmodule InterviewWeb.TemplateControllerTest do
  use InterviewWeb.ConnCase, async: false

  alias Interview.Fixtures
  alias Interview.Templates

  setup %{conn: conn} do
    tenant = Fixtures.tenant!()
    {_key, secret} = Fixtures.api_key!(tenant.id)
    conn = put_req_header(conn, "authorization", "Bearer " <> secret)
    {:ok, conn: conn, tenant: tenant}
  end

  describe "POST /api/templates" do
    test "creates a template scoped to the auth tenant", %{conn: conn, tenant: tenant} do
      conn = post(conn, ~p"/api/templates", %{name: "New", description: "D"})
      assert %{"id" => id, "tenant_id" => tid, "name" => "New"} = json_response(conn, 201)
      assert tid == tenant.id
      assert id
    end

    test "rejects unauthenticated requests" do
      conn = build_conn() |> post(~p"/api/templates", %{name: "X"})
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end
  end

  describe "GET /api/templates" do
    test "returns only templates of the auth tenant", %{conn: conn, tenant: tenant} do
      _ = Fixtures.template!(tenant.id, %{name: "Mine"})
      other_tenant = Fixtures.tenant!()
      _ = Fixtures.template!(other_tenant.id, %{name: "Theirs"})

      resp = conn |> get(~p"/api/templates") |> json_response(200)
      names = resp["templates"] |> Enum.map(& &1["name"])
      assert "Mine" in names
      refute "Theirs" in names
    end
  end

  describe "GET /api/templates/:id" do
    test "returns the template + current_version + draft", %{conn: conn, tenant: tenant} do
      template = Fixtures.template!(tenant.id, %{name: "T"})
      v = Fixtures.version!(template.id, %{version_number: 1})
      _ = Fixtures.question!(v.id, 1, %{prompt_text: "Q"})
      {:ok, _} = Templates.publish_draft(v)

      resp = conn |> get(~p"/api/templates/#{template.id}") |> json_response(200)
      assert resp["template"]["name"] == "T"
      assert resp["current_version"]["id"]
    end

    test "404 for a template owned by another tenant", %{conn: conn} do
      other = Fixtures.tenant!()
      template = Fixtures.template!(other.id)

      assert json_response(conn |> get(~p"/api/templates/#{template.id}"), 404)
    end
  end

  describe "POST /api/templates/:id/versions" do
    test "creates a draft", %{conn: conn, tenant: tenant} do
      template = Fixtures.template!(tenant.id)
      resp = conn |> post(~p"/api/templates/#{template.id}/versions") |> json_response(201)
      assert resp["version"]["published_at"] == nil
      assert is_list(resp["version"]["questions"])
    end
  end

  describe "PUT /api/templates/:id/versions/:vid/questions" do
    test "replaces the draft's question list", %{conn: conn, tenant: tenant} do
      template = Fixtures.template!(tenant.id)
      {:ok, draft} = Templates.create_draft_version(template)

      payload = %{
        questions: [
          %{position: 1, prompt: "First", max_answer_seconds: 60, required: true, tags: []},
          %{position: 2, prompt: "Second", required: false, tags: []}
        ]
      }

      resp = put(conn, ~p"/api/templates/#{template.id}/versions/#{draft.id}/questions", payload)
      body = json_response(resp, 200)
      assert length(body["version"]["questions"]) == 2
      assert Enum.map(body["version"]["questions"], & &1["prompt_text"]) == ["First", "Second"]
    end

    test "returns JSON-pointer errors for invalid input", %{conn: conn, tenant: tenant} do
      template = Fixtures.template!(tenant.id)
      {:ok, draft} = Templates.create_draft_version(template)

      payload = %{questions: [%{position: 1, prompt: "X", max_answer_seconds: 0}]}
      resp = put(conn, ~p"/api/templates/#{template.id}/versions/#{draft.id}/questions", payload)
      assert %{"errors" => [%{"pointer" => ptr, "message" => msg}]} = json_response(resp, 422)
      assert ptr == "/questions/0/max_answer_seconds"
      assert msg =~ "integer"
    end
  end

  describe "POST /api/templates/:id/versions/:vid/publish" do
    test "publishes the draft and flips current_version_id", %{conn: conn, tenant: tenant} do
      template = Fixtures.template!(tenant.id)
      v = Fixtures.version!(template.id, %{version_number: 1})
      _ = Fixtures.question!(v.id, 1, %{prompt_text: "Q"})

      resp = post(conn, ~p"/api/templates/#{template.id}/versions/#{v.id}/publish")
      body = json_response(resp, 200)
      assert body["version"]["published_at"]

      template = Templates.get_template!(template.id)
      assert template.current_version_id == v.id
    end

    test "returns 409 if the version is already published", %{conn: conn, tenant: tenant} do
      template = Fixtures.template!(tenant.id)
      v = Fixtures.version!(template.id, %{version_number: 1})
      _ = Fixtures.question!(v.id, 1, %{prompt_text: "Q"})
      {:ok, _} = Templates.publish_draft(v)

      resp = post(conn, ~p"/api/templates/#{template.id}/versions/#{v.id}/publish")
      assert json_response(resp, 409) == %{"error" => "version_already_published"}
    end
  end

  describe "POST /api/templates/:id/import" do
    @yaml """
    template:
      name: ignored
    retake_policy:
      max_attempts: 2
      mode: last
    questions:
      - position: 1
        prompt: Hello world
        max_answer_seconds: 90
        external_id: q-1
      - position: 2
        prompt: Goodbye
        required: false
    """

    @markdown """
    ---
    template: ACME
    retake_policy: { max_attempts: 1, mode: first_only }
    ---

    ---
    position: 1
    external_id: md-1
    ---

    Hello from markdown.
    """

    test "imports YAML and writes the draft's questions", %{conn: conn, tenant: tenant} do
      template = Fixtures.template!(tenant.id)

      resp =
        conn
        |> put_req_header("content-type", "application/yaml")
        |> post(~p"/api/templates/#{template.id}/import", @yaml)

      body = json_response(resp, 200)
      qs = body["version"]["questions"]
      assert length(qs) == 2
      assert hd(qs)["external_id"] == "q-1"
      # webhook payloads carry external_id (PLAN §3.4): in the API
      # payload, external_id is round-tripped on every question.
      assert Enum.all?(qs, &Map.has_key?(&1, "external_id"))
    end

    test "imports markdown when content-type says so", %{conn: conn, tenant: tenant} do
      template = Fixtures.template!(tenant.id)

      resp =
        conn
        |> put_req_header("content-type", "text/markdown")
        |> post(~p"/api/templates/#{template.id}/import", @markdown)

      body = json_response(resp, 200)
      [q] = body["version"]["questions"]
      assert q["external_id"] == "md-1"
      assert q["prompt_text"] =~ "from markdown"
    end

    test "validation errors carry pointer + line", %{conn: conn, tenant: tenant} do
      template = Fixtures.template!(tenant.id)

      bad = """
      template:
        name: T
      questions:
        - position: 1
          prompt: ok
          max_answer_seconds: 0
      """

      resp =
        conn
        |> put_req_header("content-type", "application/yaml")
        |> post(~p"/api/templates/#{template.id}/import", bad)

      assert %{"errors" => [err]} = json_response(resp, 422)
      assert err["pointer"] == "/questions/0/max_answer_seconds"
      assert err["line"]
    end
  end
end
