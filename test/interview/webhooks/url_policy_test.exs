defmodule Interview.Webhooks.URLPolicyTest do
  use ExUnit.Case, async: true

  alias Interview.Webhooks.URLPolicy

  describe "validate_shape/2 — strict policy (production default)" do
    @strict [allow_http?: false, allow_private?: false]

    test "accepts https with a public-looking hostname" do
      assert :ok = URLPolicy.validate_shape("https://hooks.example.com/x", @strict)
    end

    test "accepts a blank or nil URL (no webhook configured)" do
      assert :ok = URLPolicy.validate_shape(nil, @strict)
      assert :ok = URLPolicy.validate_shape("", @strict)
    end

    test "rejects http://" do
      assert {:error, :http_disallowed} =
               URLPolicy.validate_shape("http://hooks.example.com/x", @strict)
    end

    test "rejects ftp:// and other schemes" do
      assert {:error, :scheme_required} =
               URLPolicy.validate_shape("ftp://hooks.example.com/x", @strict)
    end

    test "rejects unparseable URLs" do
      assert {:error, _} = URLPolicy.validate_shape("not a url", @strict)
    end

    test "rejects URLs without a host" do
      assert {:error, :host_required} = URLPolicy.validate_shape("https:///path", @strict)
    end

    test "rejects denied hostnames (localhost, *.localhost, *.internal, *.local)" do
      for host <- ~w(localhost foo.localhost bar.internal baz.local svc.lan svc.home) do
        assert {:error, :hostname_denied} =
                 URLPolicy.validate_shape("https://#{host}/hook", @strict),
               "expected #{host} to be denied"
      end
    end

    test "rejects RFC1918 IPv4 literals" do
      for ip <- ~w(10.0.0.1 172.16.0.1 172.31.255.254 192.168.1.1) do
        assert {:error, :private_ip_disallowed} =
                 URLPolicy.validate_shape("https://#{ip}/hook", @strict)
      end
    end

    test "rejects loopback / link-local / cloud-metadata IPv4 literals" do
      for ip <- ~w(127.0.0.1 169.254.169.254 169.254.0.1) do
        assert {:error, :private_ip_disallowed} =
                 URLPolicy.validate_shape("https://#{ip}/hook", @strict)
      end
    end

    test "rejects CGNAT range" do
      assert {:error, :private_ip_disallowed} =
               URLPolicy.validate_shape("https://100.64.0.1/hook", @strict)
    end

    test "accepts a public IPv4 literal" do
      assert :ok = URLPolicy.validate_shape("https://1.1.1.1/hook", @strict)
    end
  end

  describe "validate_shape/2 — relaxed policy (dev/test)" do
    @relaxed [allow_http?: true, allow_private?: true]

    test "allows http://localhost for local receivers" do
      assert :ok = URLPolicy.validate_shape("http://localhost:3000/hook", @relaxed)
    end

    test "allows http://127.0.0.1" do
      assert :ok = URLPolicy.validate_shape("http://127.0.0.1:4000/hook", @relaxed)
    end

    test "still rejects unparseable URLs" do
      assert {:error, _} = URLPolicy.validate_shape("not a url", @relaxed)
    end
  end

  describe "check_destination/2" do
    @strict [allow_private?: false]
    @relaxed [allow_private?: true]

    test "is a no-op when allow_private? is true (dev/test)" do
      assert :ok = URLPolicy.check_destination("http://localhost:3000/hook", @relaxed)
      assert :ok = URLPolicy.check_destination("http://127.0.0.1/hook", @relaxed)
    end

    test "rejects an IP literal in a private range" do
      assert {:error, :private_ip_disallowed} =
               URLPolicy.check_destination("https://10.0.0.1/hook", @strict)
    end

    test "rejects an IP literal at the cloud metadata endpoint" do
      assert {:error, :private_ip_disallowed} =
               URLPolicy.check_destination("https://169.254.169.254/latest/meta-data/", @strict)
    end

    test "accepts a public IP literal" do
      assert :ok = URLPolicy.check_destination("https://1.1.1.1/hook", @strict)
    end

    test "surfaces DNS lookup failures so the caller can retry vs permafail" do
      # `.invalid` is reserved (RFC 2606) and will never resolve.
      assert {:error, reason} =
               URLPolicy.check_destination("https://does-not-exist.invalid/hook", @strict)

      assert reason in [:dns_no_records] or match?({:dns_lookup_failed, _}, reason)
    end
  end
end
