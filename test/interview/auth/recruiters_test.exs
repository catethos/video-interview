defmodule Interview.Auth.RecruitersTest do
  use Interview.DataCase, async: true

  alias Interview.Auth.Recruiters
  alias Interview.Auth.Recruiters.{MagicLink, User}
  alias Interview.Fixtures
  alias Interview.Repo

  describe "create_user/1" do
    test "downcases + trims email" do
      tenant = Fixtures.tenant!()

      assert {:ok, %User{email: "alice@example.com"}} =
               Recruiters.create_user(%{
                 tenant_id: tenant.id,
                 email: "  Alice@Example.COM  "
               })
    end

    test "rejects duplicate email globally" do
      tenant_a = Fixtures.tenant!()
      tenant_b = Fixtures.tenant!()
      assert {:ok, _} = Recruiters.create_user(%{tenant_id: tenant_a.id, email: "x@x.com"})

      assert {:error, cs} =
               Recruiters.create_user(%{tenant_id: tenant_b.id, email: "X@X.COM"})

      assert "has already been taken" in errors_on(cs).email
    end
  end

  describe "request_magic_link/2" do
    test "issues a token, stores its hash, returns the raw url" do
      tenant = Fixtures.tenant!()
      user = Fixtures.recruiter!(tenant.id, %{email: "rec@example.com"})

      assert {:ok, %{user: ^user, token: raw, url: url}} =
               Recruiters.request_magic_link("rec@example.com", "127.0.0.1")

      assert is_binary(raw)
      assert String.contains?(url, raw)

      hash = :crypto.hash(:sha256, raw)
      assert %MagicLink{} = Repo.get_by(MagicLink, token_hash: hash)
    end

    test "unknown email → :not_found" do
      assert {:error, :not_found} = Recruiters.request_magic_link("nobody@example.com")
    end
  end

  describe "consume_magic_link/1" do
    setup do
      tenant = Fixtures.tenant!()
      user = Fixtures.recruiter!(tenant.id, %{email: "rec@example.com"})
      {:ok, %{token: raw}} = Recruiters.request_magic_link("rec@example.com")
      %{user: user, raw: raw}
    end

    test "consumes a fresh token", %{user: user, raw: raw} do
      assert {:ok, returned} = Recruiters.consume_magic_link(raw)
      assert returned.id == user.id
      refute is_nil(returned.last_seen_at)
    end

    test "double-consume rejected", %{raw: raw} do
      assert {:ok, _} = Recruiters.consume_magic_link(raw)
      assert {:error, :consumed} = Recruiters.consume_magic_link(raw)
    end

    test "expired rejected", %{raw: raw} do
      hash = :crypto.hash(:sha256, raw)
      past = DateTime.utc_now() |> DateTime.add(-1, :second)

      from(l in MagicLink, where: l.token_hash == ^hash)
      |> Repo.update_all(set: [expires_at: past])

      assert {:error, :expired} = Recruiters.consume_magic_link(raw)
    end

    test "garbage rejected" do
      assert {:error, :invalid} = Recruiters.consume_magic_link("nope")
    end
  end
end
