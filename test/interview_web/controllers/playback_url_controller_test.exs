defmodule InterviewWeb.PlaybackUrlControllerTest do
  use InterviewWeb.ConnCase, async: false

  alias Interview.Auth.Tokens
  alias Interview.Capture
  alias Interview.Fixtures

  defp authed_conn(conn, secret) do
    conn
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> secret)
  end

  defp setup_ready_response(opts \\ []) do
    %{tenant: tenant, session: session, question: question} = Fixtures.graph!()
    {_key, secret} = Fixtures.api_key!(tenant.id)
    {:ok, response, _} = Capture.claim_instance(session, question, 1, "cap-A")
    response = Fixtures.with_artifact!(response, opts)
    {tenant, secret, response}
  end

  describe "POST /api/responses/:id/playback_url" do
    test "mints a signed URL that resolves to the response's MP4", %{conn: conn} do
      {tenant, secret, response} = setup_ready_response()

      mint_conn =
        conn
        |> authed_conn(secret)
        |> post(~p"/api/responses/#{response.id}/playback_url")

      assert payload = json_response(mint_conn, 200)
      assert is_binary(payload["url"])
      assert is_binary(payload["expires_at"])

      uri = URI.parse(payload["url"])
      assert uri.path == "/playback/#{response.id}"
      assert %{"token" => token} = URI.decode_query(uri.query)

      # Verify the token round-trips correctly.
      assert {:ok, %{rid: rid, tid: tid}} = Tokens.verify_playback_url_token(token)
      assert rid == response.id
      assert tid == tenant.id

      # And the signed URL actually plays.
      play_conn = get(conn, "/playback/#{response.id}?token=#{token}")
      assert play_conn.status == 200
      assert Enum.any?(get_resp_header(play_conn, "content-type"), &(&1 =~ "video/mp4"))
    end

    test "409 when the response is not yet ready", %{conn: conn} do
      %{tenant: tenant, session: session, question: question} = Fixtures.graph!()
      {_key, secret} = Fixtures.api_key!(tenant.id)
      {:ok, response, _} = Capture.claim_instance(session, question, 1, "cap-A")
      # No artifact written — stays in `recording` state.

      mint_conn =
        conn |> authed_conn(secret) |> post(~p"/api/responses/#{response.id}/playback_url")

      assert resp = json_response(mint_conn, 409)
      assert resp["error"] == "response_not_ready"
    end

    test "404 when the response belongs to another tenant", %{conn: conn} do
      {_tenant, _secret, response} = setup_ready_response()
      other_tenant = Fixtures.tenant!()
      {_key, other_secret} = Fixtures.api_key!(other_tenant.id)

      mint_conn =
        conn
        |> authed_conn(other_secret)
        |> post(~p"/api/responses/#{response.id}/playback_url")

      assert json_response(mint_conn, 404) == %{"error" => "response_not_found"}
    end

    test "404 when the response does not exist", %{conn: conn} do
      tenant = Fixtures.tenant!()
      {_key, secret} = Fixtures.api_key!(tenant.id)

      mint_conn =
        conn
        |> authed_conn(secret)
        |> post(~p"/api/responses/#{Ecto.UUID.generate()}/playback_url")

      assert json_response(mint_conn, 404) == %{"error" => "response_not_found"}
    end

    test "rejects requests without a bearer token", %{conn: conn} do
      response_id = Ecto.UUID.generate()
      mint_conn = post(conn, ~p"/api/responses/#{response_id}/playback_url")
      assert mint_conn.status in 401..403
    end
  end

  describe "GET /playback/:response_id?token=..." do
    test "200 with a valid token", %{conn: conn} do
      {tenant, _secret, response} = setup_ready_response()
      token = Tokens.mint_playback_url_token(response.id, tenant.id)

      play_conn = get(conn, "/playback/#{response.id}?token=#{token}")
      assert play_conn.status == 200
    end

    test "404 when token's rid does not match the path param", %{conn: conn} do
      {tenant, _secret, response} = setup_ready_response()
      # Token signed for a DIFFERENT response id — should not unlock this one.
      sneaky_token = Tokens.mint_playback_url_token(Ecto.UUID.generate(), tenant.id)

      play_conn = get(conn, "/playback/#{response.id}?token=#{sneaky_token}")
      assert play_conn.status == 404
    end

    test "404 when token is missing", %{conn: conn} do
      {_tenant, _secret, response} = setup_ready_response()
      play_conn = get(conn, "/playback/#{response.id}")
      assert play_conn.status == 404
    end

    test "404 when token is malformed", %{conn: conn} do
      {_tenant, _secret, response} = setup_ready_response()
      play_conn = get(conn, "/playback/#{response.id}?token=not-a-real-token")
      assert play_conn.status == 404
    end

    test "404 when token's tenant doesn't own the response", %{conn: conn} do
      {_tenant, _secret, response} = setup_ready_response()
      other_tenant = Fixtures.tenant!()
      # Token claims a DIFFERENT tenant; Playback.get_response_for_playback
      # is tenant-scoped so it returns nil → 404.
      cross_token = Tokens.mint_playback_url_token(response.id, other_tenant.id)

      play_conn = get(conn, "/playback/#{response.id}?token=#{cross_token}")
      assert play_conn.status == 404
    end
  end
end
