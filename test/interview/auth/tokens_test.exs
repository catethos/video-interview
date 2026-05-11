defmodule Interview.Auth.TokensTest do
  use Interview.DataCase, async: true

  alias Interview.Auth.Tokens

  describe "bootstrap" do
    test "round-trips a valid token" do
      sid = Ecto.UUID.generate()
      tid = Ecto.UUID.generate()
      {jti, token} = Tokens.mint_bootstrap(sid, tid)

      assert {:ok, %{sid: ^sid, tid: ^tid, jti: ^jti}} = Tokens.verify_bootstrap(token)
    end

    test "rejects garbage" do
      assert {:error, :invalid} = Tokens.verify_bootstrap("not-a-token")
      assert {:error, :invalid} = Tokens.verify_bootstrap(nil)
    end
  end

  describe "audience separation" do
    test "an upload bearer cannot be verified as a bootstrap" do
      bearer = Tokens.mint_upload_bearer(Ecto.UUID.generate())
      assert {:error, :invalid} = Tokens.verify_bootstrap(bearer)
    end

    test "a recruiter session token cannot be verified as an upload bearer" do
      token = Tokens.mint_recruiter_session(Ecto.UUID.generate(), Ecto.UUID.generate())
      assert {:error, :invalid} = Tokens.verify_upload_bearer(token)
    end
  end

  describe "upload bearer" do
    test "round-trips" do
      sid = Ecto.UUID.generate()
      bearer = Tokens.mint_upload_bearer(sid)
      assert {:ok, %{sid: ^sid}} = Tokens.verify_upload_bearer(bearer)
    end
  end

  describe "recruiter session" do
    test "round-trips with rk_ prefix" do
      rid = Ecto.UUID.generate()
      tid = Ecto.UUID.generate()
      token = Tokens.mint_recruiter_session(rid, tid)

      assert "rk_" <> _ = token
      assert {:ok, %{rid: ^rid, tid: ^tid}} = Tokens.verify_recruiter_session(token)
    end

    test "verify accepts the bare token (cookie-stripped form)" do
      rid = Ecto.UUID.generate()
      tid = Ecto.UUID.generate()
      "rk_" <> bare = Tokens.mint_recruiter_session(rid, tid)

      assert {:ok, %{rid: ^rid, tid: ^tid}} = Tokens.verify_recruiter_session(bare)
    end
  end
end
