defmodule Interview.Auth.ApiKeysTest do
  use Interview.DataCase, async: true

  alias Interview.Auth.ApiKeys
  alias Interview.Fixtures

  describe "create/3" do
    test "returns the secret once and stores only its hash" do
      tenant = Fixtures.tenant!()

      assert {:ok, %{api_key: key, secret: "tk_" <> _ = secret}} =
               ApiKeys.create(tenant.id, "ATS")

      assert key.tenant_id == tenant.id
      refute key.key_hash == nil
      refute is_nil(key.prefix)
      assert String.starts_with?(key.prefix, "tk_")

      # the stored hash matches sha256 of the raw secret
      "tk_" <> raw = secret
      assert :crypto.hash(:sha256, raw) == key.key_hash
    end
  end

  describe "verify/1" do
    setup do
      tenant = Fixtures.tenant!()
      {:ok, %{api_key: key, secret: secret}} = ApiKeys.create(tenant.id, "ATS")
      %{tenant: tenant, key: key, secret: secret}
    end

    test "accepts the issued bearer", %{tenant: tenant, secret: secret} do
      assert {:ok, %{tenant: returned_tenant}} = ApiKeys.verify(secret)
      assert returned_tenant.id == tenant.id
    end

    test "rejects garbage" do
      assert {:error, :invalid} = ApiKeys.verify("tk_nopeNopeNopeNopeNope")
      assert {:error, :invalid} = ApiKeys.verify("not-a-key")
      assert {:error, :invalid} = ApiKeys.verify(nil)
    end

    test "rejects revoked key", %{tenant: tenant, key: key, secret: secret} do
      assert {:ok, _} = ApiKeys.revoke(tenant.id, key.id)
      assert {:error, :revoked} = ApiKeys.verify(secret)
    end

    test "rejects bearer with valid prefix but wrong secret", %{key: key} do
      forged = key.prefix <> String.duplicate("x", 32)
      assert {:error, :invalid} = ApiKeys.verify(forged)
    end
  end

  describe "list/1" do
    test "scoped per tenant" do
      tenant_a = Fixtures.tenant!()
      tenant_b = Fixtures.tenant!()
      {:ok, %{api_key: a}} = ApiKeys.create(tenant_a.id, "a")
      {:ok, %{api_key: _}} = ApiKeys.create(tenant_b.id, "b")

      assert ApiKeys.list(tenant_a.id) |> Enum.map(& &1.id) == [a.id]
    end
  end
end
