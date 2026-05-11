defmodule Interview.Auth.BootstrapTest do
  use Interview.DataCase, async: true

  alias Interview.Auth.Bootstrap
  alias Interview.Capture.Session
  alias Interview.Fixtures
  alias Interview.Repo

  setup do
    %{session: %Session{} = s} = Fixtures.graph!()
    %{session: s}
  end

  test "mint stores jti on the session and returns a verifiable token", %{session: s} do
    assert {:ok, %{token: token, session: stored, jti: jti}} = Bootstrap.mint(s)
    assert stored.bootstrap_jti == jti
    assert is_binary(token)
  end

  test "consume returns the session once and rejects double-consume", %{session: s} do
    {:ok, %{token: token}} = Bootstrap.mint(s)
    assert {:ok, %Session{id: id}} = Bootstrap.consume(token)
    assert id == s.id
    assert %Session{bootstrap_consumed_at: %DateTime{}} = Repo.get!(Session, s.id)
    assert {:error, :consumed} = Bootstrap.consume(token)
  end

  test "rotated jti invalidates the prior token", %{session: s} do
    {:ok, %{token: old_token}} = Bootstrap.mint(s)
    {:ok, %{token: new_token}} = Bootstrap.mint(s)

    assert {:error, :invalid} = Bootstrap.consume(old_token)
    assert {:ok, _} = Bootstrap.consume(new_token)
  end

  test "garbage rejected" do
    assert {:error, :invalid} = Bootstrap.consume("garbage")
    assert {:error, :invalid} = Bootstrap.consume(nil)
  end

  test "session_not_found if session row deleted before consume", %{session: s} do
    {:ok, %{token: token}} = Bootstrap.mint(s)
    Repo.delete_all(from(x in Session, where: x.id == ^s.id))
    assert {:error, :session_not_found} = Bootstrap.consume(token)
  end
end
