defmodule Interview.WebhooksTest do
  use Interview.DataCase, async: false
  use Oban.Testing, repo: Interview.Repo

  alias Interview.Capture
  alias Interview.Capture.Session
  alias Interview.Repo
  alias Interview.Tenants.Tenant
  alias Interview.Webhooks
  alias Interview.Webhooks.Delivery
  alias Interview.Workers.WebhookDelivery

  defp configured_tenant!(opts \\ []) do
    tenant = Interview.Fixtures.tenant!()

    {:ok, t} =
      tenant
      |> Tenant.changeset(%{
        webhook_url: Keyword.get(opts, :webhook_url, "https://example.test/hook"),
        webhook_secret: Keyword.get(opts, :webhook_secret, "shh-secret")
      })
      |> Repo.update()

    t
  end

  defp session_for(tenant) do
    template = Interview.Fixtures.template!(tenant.id)
    version = Interview.Fixtures.version!(template.id)

    Interview.Fixtures.session!(tenant.id, version.id, %{
      external_id: "ats-123",
      state: "in_progress"
    })
  end

  describe "enqueue/3" do
    test "inserts a webhook_deliveries row + Oban job for a tenant with webhook_url" do
      tenant = configured_tenant!()
      session = session_for(tenant)

      {:ok, %Delivery{} = d} = Webhooks.enqueue(session, "session.submitted", %{"position" => 1})

      assert d.tenant_id == tenant.id
      assert d.session_id == session.id
      assert d.event_type == "session.submitted"
      assert d.state == "pending"
      assert d.payload["v"] == 1
      assert d.payload["external_id"] == "ats-123"
      # Caller extras merge over the derived defaults.
      assert d.payload["data"]["position"] == 1
      assert d.payload["data"]["responses_count"] == 0
      assert is_binary(d.payload["data"]["submitted_at"])
      assert assert_enqueued(worker: WebhookDelivery, args: %{"delivery_id" => d.id})
    end

    test "is idempotent on (session, event_type) — second enqueue updates the same row" do
      tenant = configured_tenant!()
      session = session_for(tenant)

      {:ok, %Delivery{id: id, delivered_at: stamp}} = Webhooks.enqueue(session, "session.submitted")
      {:ok, %Delivery{id: ^id, delivered_at: ^stamp}} = Webhooks.enqueue(session, "session.submitted")

      assert Repo.aggregate(Delivery, :count, :id) == 1
    end

    test "no-ops the Oban job when tenant has no webhook_url, but still records the row" do
      %{tenant: tenant} = Interview.Fixtures.graph!()
      session = session_for(tenant)

      {:ok, %Delivery{state: "pending"}} = Webhooks.enqueue(session, "session.ready")

      refute_enqueued(worker: WebhookDelivery)
    end
  end

  describe "WebhookDelivery worker" do
    test "signs the body with HMAC-SHA256 over the raw payload, marks delivered on 2xx" do
      tenant = configured_tenant!(webhook_secret: "topsecret")
      session = session_for(tenant)
      {:ok, %Delivery{id: id, payload: payload}} = Webhooks.enqueue(session, "session.submitted")

      Interview.WebhookStub.program([{:ok, %{status: 200, body: "ok", headers: []}}])

      assert :ok = perform_job(WebhookDelivery, %{"delivery_id" => id})

      [{:webhook_post, post}] = Interview.WebhookStub.calls()
      assert post.url == "https://example.test/hook"
      assert post.headers["Content-Type"] == "application/json"
      assert post.headers["User-Agent"] == "interview-webhook/1"
      assert post.headers["X-Interview-Event"] == "session.submitted"
      assert post.headers["X-Interview-Delivery-Id"] == id

      expected_body = Jason.encode!(payload)
      assert post.body == expected_body

      expected_sig =
        "sha256=" <>
          (:crypto.mac(:hmac, :sha256, "topsecret", expected_body) |> Base.encode16(case: :lower))

      assert post.headers["X-Interview-Signature"] == expected_sig

      d = Repo.get!(Delivery, id)
      assert d.state == "delivered"
      assert d.last_status == 200
      assert d.attempts >= 1
      assert d.response_body_preview == "ok"
    end

    test "retries on 500" do
      tenant = configured_tenant!()
      session = session_for(tenant)
      {:ok, %Delivery{id: id}} = Webhooks.enqueue(session, "session.ready")

      Interview.WebhookStub.program([{:ok, %{status: 500, body: "boom", headers: []}}])

      assert {:error, _} = perform_job(WebhookDelivery, %{"delivery_id" => id})

      d = Repo.get!(Delivery, id)
      assert d.state == "pending"
      assert d.last_status == 500
      assert d.last_error =~ "retryable 500"
    end

    test "retries on 429 (Retry-After-eligible)" do
      tenant = configured_tenant!()
      session = session_for(tenant)
      {:ok, %Delivery{id: id}} = Webhooks.enqueue(session, "session.ready")

      Interview.WebhookStub.program([
        {:ok, %{status: 429, body: "rate-limited", headers: [{"Retry-After", "5"}]}}
      ])

      assert {:error, _} = perform_job(WebhookDelivery, %{"delivery_id" => id})

      d = Repo.get!(Delivery, id)
      assert d.state == "pending"
      assert d.last_status == 429
    end

    test "permanently fails on 410 (4xx other than 408/429)" do
      tenant = configured_tenant!()
      session = session_for(tenant)
      {:ok, %Delivery{id: id}} = Webhooks.enqueue(session, "session.failed")

      Interview.WebhookStub.program([{:ok, %{status: 410, body: "gone", headers: []}}])

      assert {:discard, _} = perform_job(WebhookDelivery, %{"delivery_id" => id})

      d = Repo.get!(Delivery, id)
      assert d.state == "failed"
      assert d.last_status == 410
    end

    test "transport error → retry" do
      tenant = configured_tenant!()
      session = session_for(tenant)
      {:ok, %Delivery{id: id}} = Webhooks.enqueue(session, "session.ready")

      Interview.WebhookStub.program([{:error, :timeout}])

      assert {:error, _} = perform_job(WebhookDelivery, %{"delivery_id" => id})

      d = Repo.get!(Delivery, id)
      assert d.state == "pending"
      assert d.last_error =~ "transport"
    end

    test "permafails when tenant.webhook_secret is missing" do
      tenant = configured_tenant!(webhook_secret: nil)
      session = session_for(tenant)

      {:ok, %Delivery{id: id}} = Webhooks.enqueue(session, "session.submitted")

      assert {:discard, _} = perform_job(WebhookDelivery, %{"delivery_id" => id})

      d = Repo.get!(Delivery, id)
      assert d.state == "failed"
      assert d.last_error =~ "missing webhook_secret"
    end

    test "skip-already-delivered" do
      tenant = configured_tenant!()
      session = session_for(tenant)
      {:ok, %Delivery{id: id}} = Webhooks.enqueue(session, "session.submitted")

      Repo.update_all(
        from(d in Delivery, where: d.id == ^id),
        set: [state: "delivered"]
      )

      assert :ok = perform_job(WebhookDelivery, %{"delivery_id" => id})
      assert Interview.WebhookStub.calls() == []
    end
  end

  describe "submit_session emits session.submitted" do
    test "fires once on the first submit, even when rollup also fires session.ready" do
      tenant = configured_tenant!()
      version = Interview.Fixtures.version!(Interview.Fixtures.template!(tenant.id).id)
      _q = Interview.Fixtures.question!(version.id, 1, %{required: false})
      session = Interview.Fixtures.session!(tenant.id, version.id, %{state: "in_progress"})

      # No required questions → submit promotes to "submitted" then rolls
      # straight up to "ready" (vacuously all-required-ready).
      assert {:ok, %Session{state: "ready"}} = Capture.submit_session(session)

      assert Repo.all(Delivery) |> Enum.map(& &1.event_type) |> Enum.sort() ==
               ["session.ready", "session.submitted"]
    end
  end

  describe "payload data derivation" do
    test "session.ready carries completed_at, responses_count, duration_total_ms" do
      tenant = configured_tenant!()
      version = Interview.Fixtures.version!(Interview.Fixtures.template!(tenant.id).id)
      q = Interview.Fixtures.question!(version.id, 1, %{required: true})
      session = Interview.Fixtures.session!(tenant.id, version.id, %{state: "in_progress"})

      {:ok, response, _} = Capture.claim_instance(session, q, 1, "cap-A")
      {:ok, _} = Capture.record_capture_complete(response.id, "cap-A", 100)
      {:ok, %Session{state: "submitted"}} = Capture.submit_session(session)

      {:ok, _} =
        Capture.mark_ready(response.id, %{
          storage_key: "x",
          duration_ms: 1234,
          format: "mp4"
        })

      ready =
        Repo.all(Delivery)
        |> Enum.find(&(&1.event_type == "session.ready"))

      assert ready
      assert ready.payload["v"] == 1
      assert is_binary(ready.payload["data"]["completed_at"])
      assert ready.payload["data"]["responses_count"] == 1
      assert ready.payload["data"]["duration_total_ms"] == 1234
    end

    test "session.deleted carries reason from worker args" do
      tenant = configured_tenant!()
      session = session_for(tenant)

      {:ok, %Delivery{} = d} =
        Webhooks.enqueue(session, "session.deleted", %{"reason" => "user_request"})

      assert d.payload["data"]["reason"] == "user_request"
    end

    test "atom-keyed extras are normalised to string keys" do
      tenant = configured_tenant!()
      session = session_for(tenant)

      {:ok, %Delivery{} = d} =
        Webhooks.enqueue(session, "session.failed", %{reason: "finalizer_giveup"})

      assert d.payload["data"]["reason"] == "finalizer_giveup"
    end
  end

  describe "stale in_flight recovery" do
    test "resets in_flight → pending before re-attempting POST" do
      tenant = configured_tenant!()
      session = session_for(tenant)
      {:ok, %Delivery{id: id}} = Webhooks.enqueue(session, "session.submitted")

      # Simulate a prior worker that crashed mid-POST.
      Repo.update_all(
        from(d in Delivery, where: d.id == ^id),
        set: [state: "in_flight"]
      )

      Interview.WebhookStub.program([{:ok, %{status: 200, body: "ok", headers: []}}])

      assert :ok = perform_job(WebhookDelivery, %{"delivery_id" => id})

      d = Repo.get!(Delivery, id)
      assert d.state == "delivered"
    end
  end

  describe "replay/1" do
    test "no-ops on a delivered row" do
      tenant = configured_tenant!()
      session = session_for(tenant)
      {:ok, %Delivery{id: id}} = Webhooks.enqueue(session, "session.submitted")

      Repo.update_all(
        from(d in Delivery, where: d.id == ^id),
        set: [state: "delivered"]
      )

      assert {:ok, %Delivery{state: "delivered"}} = Webhooks.replay(id)
      refute_enqueued(worker: WebhookDelivery, args: %{"delivery_id" => id, "_replay" => true})
    end

    test "resets a failed row to pending and enqueues a fresh job" do
      tenant = configured_tenant!()
      session = session_for(tenant)
      {:ok, %Delivery{id: id}} = Webhooks.enqueue(session, "session.failed", %{"reason" => "x"})

      Repo.update_all(
        from(d in Delivery, where: d.id == ^id),
        set: [state: "failed", last_error: "permanent 410"]
      )

      assert {:ok, %Delivery{state: "pending", last_error: nil}} = Webhooks.replay(id)
      assert_enqueued(worker: WebhookDelivery, args: %{"delivery_id" => id})
    end

    test "returns :tenant_not_configured when webhook_url is cleared" do
      tenant = configured_tenant!()
      session = session_for(tenant)
      {:ok, %Delivery{id: id}} = Webhooks.enqueue(session, "session.submitted")

      Repo.update_all(
        from(t in Interview.Tenants.Tenant, where: t.id == ^tenant.id),
        set: [webhook_url: nil]
      )

      assert {:error, :tenant_not_configured} = Webhooks.replay(id)
    end

    test "returns :not_found for unknown ids" do
      assert {:error, :not_found} = Webhooks.replay(Ecto.UUID.generate())
    end
  end

  describe "circuit breaker" do
    setup do
      prev = Application.get_env(:interview, Interview.Webhooks, [])
      Application.put_env(:interview, Interview.Webhooks, Keyword.put(prev, :circuit_breaker_threshold, 3))
      on_exit(fn -> Application.put_env(:interview, Interview.Webhooks, prev) end)
      :ok
    end

    test "nulls the tenant.webhook_url after N consecutive permafails" do
      tenant = configured_tenant!()

      # 3 prior permafailed rows, all on the same tenant.
      for _ <- 1..3 do
        session = session_for(tenant)
        {:ok, d} = Webhooks.enqueue(session, "session.failed", %{"reason" => "x"})

        Repo.update_all(
          from(row in Delivery, where: row.id == ^d.id),
          set: [state: "failed", updated_at: DateTime.utc_now()]
        )
      end

      # One more failed delivery that triggers the breaker via the worker.
      session = session_for(tenant)
      {:ok, %Delivery{id: id}} = Webhooks.enqueue(session, "session.failed", %{"reason" => "x"})

      Interview.WebhookStub.program([{:ok, %{status: 410, body: "gone", headers: []}}])
      assert {:discard, _} = perform_job(WebhookDelivery, %{"delivery_id" => id})

      tenant_after = Repo.get!(Interview.Tenants.Tenant, tenant.id)
      assert tenant_after.webhook_url in [nil, ""]
    end

    test "leaves a healthy tenant alone" do
      tenant = configured_tenant!()
      session = session_for(tenant)
      {:ok, %Delivery{id: id}} = Webhooks.enqueue(session, "session.failed", %{"reason" => "x"})

      Interview.WebhookStub.program([{:ok, %{status: 410, body: "gone", headers: []}}])
      assert {:discard, _} = perform_job(WebhookDelivery, %{"delivery_id" => id})

      tenant_after = Repo.get!(Interview.Tenants.Tenant, tenant.id)
      assert tenant_after.webhook_url == tenant.webhook_url
    end
  end

  describe "rollup_session emits session.ready" do
    test "fires when all required responses reach ready" do
      tenant = configured_tenant!()
      version = Interview.Fixtures.version!(Interview.Fixtures.template!(tenant.id).id)
      q = Interview.Fixtures.question!(version.id, 1, %{required: true})
      session = Interview.Fixtures.session!(tenant.id, version.id, %{state: "in_progress"})

      {:ok, response, _} = Capture.claim_instance(session, q, 1, "cap-A")
      {:ok, _} = Capture.record_capture_complete(response.id, "cap-A", 100)

      {:ok, %Session{state: "submitted"}} = Capture.submit_session(session)

      # Promote the response to ready, which should trigger rollup -> ready and webhook.
      {:ok, _} =
        Capture.mark_ready(response.id, %{
          storage_key: "x",
          duration_ms: 1000,
          format: "mp4"
        })

      events =
        Repo.all(Delivery)
        |> Enum.map(& &1.event_type)
        |> Enum.sort()

      assert events == ["session.ready", "session.submitted"]
    end
  end
end
