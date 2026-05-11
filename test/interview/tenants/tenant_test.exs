defmodule Interview.Tenants.TenantTest do
  use Interview.DataCase, async: true

  alias Interview.Repo
  alias Interview.Tenants.Tenant

  defp base_attrs(extra) do
    Map.merge(%{name: "Acme", slug: "acme-#{System.unique_integer([:positive])}"}, extra)
  end

  describe "changeset/2 — webhook_url validation" do
    test "accepts a https URL with a public hostname" do
      cs = Tenant.changeset(%Tenant{}, base_attrs(%{webhook_url: "https://hooks.example.com/x"}))
      assert cs.valid?
    end

    test "accepts nil and blank webhook_url (no webhook configured)" do
      assert Tenant.changeset(%Tenant{}, base_attrs(%{webhook_url: nil})).valid?
      assert Tenant.changeset(%Tenant{}, base_attrs(%{webhook_url: ""})).valid?
    end

    test "rejects http:// in strict (test) mode" do
      cs = Tenant.changeset(%Tenant{}, base_attrs(%{webhook_url: "http://hooks.example.com/x"}))
      refute cs.valid?
      assert {"must use https:// (http:// not allowed)", _} = cs.errors[:webhook_url]
    end

    test "rejects localhost" do
      cs = Tenant.changeset(%Tenant{}, base_attrs(%{webhook_url: "https://localhost/hook"}))
      refute cs.valid?
      assert {"must not point at an internal hostname", _} = cs.errors[:webhook_url]
    end

    test "rejects a private IPv4 literal" do
      cs = Tenant.changeset(%Tenant{}, base_attrs(%{webhook_url: "https://10.0.0.1/hook"}))
      refute cs.valid?
      assert {"must not point at a private IP", _} = cs.errors[:webhook_url]
    end

    test "rejects the cloud metadata endpoint" do
      cs =
        Tenant.changeset(
          %Tenant{},
          base_attrs(%{webhook_url: "https://169.254.169.254/latest/meta-data/"})
        )

      refute cs.valid?
      assert {"must not point at a private IP", _} = cs.errors[:webhook_url]
    end

    test "rejects unparseable URLs" do
      cs = Tenant.changeset(%Tenant{}, base_attrs(%{webhook_url: "not a url"}))
      refute cs.valid?
      assert {_, _} = cs.errors[:webhook_url]
    end
  end

  describe "auto-generated webhook_secret" do
    test "new tenants get a 32-byte URL-safe secret when none is supplied" do
      {:ok, t} = %Tenant{} |> Tenant.changeset(base_attrs(%{})) |> Repo.insert()

      assert is_binary(t.webhook_secret)
      # 32 bytes base64url, no padding = 43 chars.
      assert byte_size(t.webhook_secret) >= 40
      refute String.contains?(t.webhook_secret, "=")
    end

    test "honours a caller-supplied webhook_secret on insert" do
      attrs = base_attrs(%{webhook_secret: "i-brought-my-own"})
      {:ok, t} = %Tenant{} |> Tenant.changeset(attrs) |> Repo.insert()
      assert t.webhook_secret == "i-brought-my-own"
    end

    test "does NOT regenerate the secret on update" do
      {:ok, t} = %Tenant{} |> Tenant.changeset(base_attrs(%{})) |> Repo.insert()
      original = t.webhook_secret

      {:ok, t2} = t |> Tenant.changeset(%{name: "Acme renamed"}) |> Repo.update()
      assert t2.webhook_secret == original
    end
  end
end
