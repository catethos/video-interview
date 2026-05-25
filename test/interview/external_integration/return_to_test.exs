defmodule Interview.ExternalIntegration.ReturnToTest do
  use ExUnit.Case, async: true

  alias Interview.ExternalIntegration.ReturnTo

  describe "validate/2" do
    test "accepts an https URL whose origin is whitelisted" do
      assert {:ok, %URI{host: "pulsifi.demo"}} =
               ReturnTo.validate("https://pulsifi.demo/cb", ["https://pulsifi.demo"])
    end

    test "preserves path + query on the parsed URI" do
      assert {:ok, %URI{path: "/api/jobs/123/cb", query: "src=vi"}} =
               ReturnTo.validate(
                 "https://pulsifi.demo/api/jobs/123/cb?src=vi",
                 ["https://pulsifi.demo"]
               )
    end

    test "rejects a URL whose origin is not in the whitelist" do
      assert {:error, :return_to_origin_not_whitelisted} =
               ReturnTo.validate("https://evil.example/cb", ["https://pulsifi.demo"])
    end

    test "rejects an http URL when whitelist contains only https" do
      assert {:error, :return_to_origin_not_whitelisted} =
               ReturnTo.validate("http://pulsifi.demo/cb", ["https://pulsifi.demo"])
    end

    test "accepts an http URL when its http origin is whitelisted (dev case)" do
      assert {:ok, _} =
               ReturnTo.validate("http://localhost:4001/cb", ["http://localhost:4001"])
    end

    test "normalizes default ports for origin comparison" do
      # https://x.com:443/p == https://x.com/p
      assert {:ok, _} = ReturnTo.validate("https://x.com:443/p", ["https://x.com"])
      assert {:ok, _} = ReturnTo.validate("https://x.com/p", ["https://x.com:443"])
    end

    test "rejects non-http schemes" do
      assert {:error, :return_to_scheme_disallowed} =
               ReturnTo.validate("javascript:alert(1)", ["https://x.com"])

      assert {:error, :return_to_scheme_disallowed} =
               ReturnTo.validate("file:///etc/passwd", ["https://x.com"])
    end

    test "rejects malformed urls" do
      assert {:error, :return_to_malformed} = ReturnTo.validate("ht!tp:/broken", [])
    end

    test "rejects nil/empty as return_to_required" do
      assert {:error, :return_to_required} = ReturnTo.validate(nil, ["https://x.com"])
      assert {:error, :return_to_required} = ReturnTo.validate("", ["https://x.com"])
    end

    test "rejects an empty whitelist for any url (default-safe)" do
      assert {:error, :return_to_origin_not_whitelisted} =
               ReturnTo.validate("https://anything.com/cb", [])
    end
  end

  describe "build_redirect/2" do
    test "appends params to a URL with no existing query string" do
      {:ok, uri} = ReturnTo.validate("https://x.com/cb", ["https://x.com"])

      url =
        ReturnTo.build_redirect(uri, %{"template_id" => "abc", "state" => "xyz"})

      parsed = URI.parse(url)
      assert parsed.scheme == "https"
      assert parsed.host == "x.com"
      assert parsed.path == "/cb"
      assert URI.decode_query(parsed.query) == %{"template_id" => "abc", "state" => "xyz"}
    end

    test "preserves existing query params and does not overwrite them" do
      {:ok, uri} =
        ReturnTo.validate("https://x.com/cb?source=email&state=preserve", ["https://x.com"])

      url =
        ReturnTo.build_redirect(uri, %{
          "template_id" => "abc",
          "state" => "would-overwrite"
        })

      parsed = URI.parse(url)
      decoded = URI.decode_query(parsed.query)
      # Existing keys are preserved (put_new semantics).
      assert decoded["state"] == "preserve"
      assert decoded["source"] == "email"
      # New key fills the gap.
      assert decoded["template_id"] == "abc"
    end

    test "omits nil values" do
      {:ok, uri} = ReturnTo.validate("https://x.com/cb", ["https://x.com"])

      url = ReturnTo.build_redirect(uri, %{"template_id" => "abc", "state" => nil})

      parsed = URI.parse(url)
      decoded = URI.decode_query(parsed.query)
      assert decoded == %{"template_id" => "abc"}
    end
  end
end
