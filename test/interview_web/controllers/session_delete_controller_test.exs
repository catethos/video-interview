defmodule InterviewWeb.SessionDeleteControllerTest do
  use InterviewWeb.ConnCase, async: true
  use Oban.Testing, repo: Interview.Repo

  import Ecto.Query

  alias Interview.Capture.Session
  alias Interview.Fixtures
  alias Interview.Repo
  alias Interview.Workers.SessionDeletion

  setup do
    tenant = Fixtures.tenant!()
    {_key, secret} = Fixtures.api_key!(tenant.id)
    template = Fixtures.template!(tenant.id)
    version = Fixtures.version!(template.id)
    session = Fixtures.session!(tenant.id, version.id, %{state: "ready"})

    %{tenant: tenant, secret: secret, session: session}
  end

  defp authed(conn, secret) do
    Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> secret)
  end

  test "DELETE /api/sessions/:id returns 202, soft-deletes, enqueues deletion job", %{
    conn: conn,
    secret: secret,
    session: session
  } do
    conn = conn |> authed(secret) |> delete(~p"/api/sessions/#{session.id}")

    assert json_response(conn, 202) == %{"id" => session.id, "status" => "accepted"}
    assert assert_enqueued(worker: SessionDeletion, args: %{"session_id" => session.id})

    s = Repo.get!(Session, session.id)
    assert s.deleted_at
  end

  test "DELETE returns 404 when the session belongs to another tenant", %{conn: conn} do
    other_tenant = Fixtures.tenant!()
    {_, other_secret} = Fixtures.api_key!(other_tenant.id)
    template = Fixtures.template!(other_tenant.id)
    version = Fixtures.version!(template.id)
    session = Fixtures.session!(other_tenant.id, version.id)

    target_tenant = Fixtures.tenant!()
    {_, target_secret} = Fixtures.api_key!(target_tenant.id)

    conn = conn |> authed(target_secret) |> delete(~p"/api/sessions/#{session.id}")
    assert json_response(conn, 404)
    refute_enqueued(worker: SessionDeletion, args: %{"session_id" => session.id})
    _ = other_secret
  end

  test "DELETE is idempotent — second call returns already_deleted", %{
    conn: conn,
    secret: secret,
    session: session
  } do
    Repo.update_all(
      from(s in Session, where: s.id == ^session.id),
      set: [deleted_at: DateTime.utc_now()]
    )

    conn = conn |> authed(secret) |> delete(~p"/api/sessions/#{session.id}")
    assert json_response(conn, 202) == %{"id" => session.id, "status" => "already_deleted"}
  end
end
