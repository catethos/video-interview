defmodule InterviewWeb.ApiKeyControllerTest do
  use InterviewWeb.ConnCase, async: true

  alias Interview.Auth.ApiKeys
  alias Interview.Fixtures

  defp authed(conn, recruiter) do
    token = Fixtures.recruiter_session_token!(recruiter)

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
  end

  setup do
    tenant = Fixtures.tenant!()
    recruiter = Fixtures.recruiter!(tenant.id)
    %{tenant: tenant, recruiter: recruiter}
  end

  test "POST creates and returns secret once", %{conn: conn, tenant: tenant, recruiter: recruiter} do
    conn =
      conn
      |> authed(recruiter)
      |> post(~p"/api/tenant/api-keys", Jason.encode!(%{"name" => "ATS"}))

    assert %{"api_key" => %{"id" => id, "prefix" => prefix}, "secret" => secret} =
             json_response(conn, 201)

    assert String.starts_with?(secret, "tk_")
    assert String.starts_with?(prefix, "tk_")
    assert {:ok, %{tenant: t}} = ApiKeys.verify(secret)
    assert t.id == tenant.id
    assert is_binary(id)
  end

  test "POST 422 with empty name", %{conn: conn, recruiter: recruiter} do
    conn =
      conn
      |> authed(recruiter)
      |> post(~p"/api/tenant/api-keys", Jason.encode!(%{"name" => ""}))

    assert %{"error" => "name_required"} = json_response(conn, 422)
  end

  test "GET lists tenant-scoped keys (no secret)",
       %{conn: conn, tenant: tenant, recruiter: recruiter} do
    {_key, _secret} = Fixtures.api_key!(tenant.id, name: "one")
    {_key, _secret} = Fixtures.api_key!(tenant.id, name: "two")
    other = Fixtures.tenant!()
    Fixtures.api_key!(other.id, name: "leak")

    conn =
      conn
      |> authed(recruiter)
      |> get(~p"/api/tenant/api-keys")

    %{"api_keys" => keys} = json_response(conn, 200)
    assert length(keys) == 2
    refute Enum.any?(keys, &Map.has_key?(&1, "secret"))
    refute Enum.any?(keys, &(&1["name"] == "leak"))
  end

  test "DELETE revokes; verify rejects", %{conn: conn, tenant: tenant, recruiter: recruiter} do
    {key, secret} = Fixtures.api_key!(tenant.id)

    conn =
      conn
      |> authed(recruiter)
      |> delete(~p"/api/tenant/api-keys/#{key.id}")

    assert %{"api_key" => %{"revoked_at" => revoked_at}} = json_response(conn, 200)
    refute is_nil(revoked_at)
    assert {:error, :revoked} = ApiKeys.verify(secret)
  end

  test "401 without auth", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json")
      |> get(~p"/api/tenant/api-keys")

    assert json_response(conn, 401)
  end
end
