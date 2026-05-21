defmodule Interview.Webhooks do
  @moduledoc """
  Per-tenant webhook fan-out (PLAN §3.1, §7 Phase 4, §11 #8).

  v1 events:
    * `session.submitted` — candidate hit submit (matches `sessions.state`).
    * `session.ready`     — finalizer rolled up to ready.
    * `session.failed`    — finalizer permanently failed.
    * `session.deleted`   — retention sweeper or right-to-delete consumed
      the recording.

  Wire format documented in `interview/docs/integration.md` §8. Payload
  carries `"v": 1`. New fields may be added but never removed (backward-
  compat constraint); receivers without `v` should treat as `v=1`.

  Delivery flow:
    1. `enqueue/3` upserts a `webhook_deliveries` row keyed on
       `(session_id, event_type)` and inserts an Oban job in the `:webhook`
       queue. `delivered_at` is stamped once at row creation so retries
       send a stable value to the receiver.
    2. `Interview.Workers.WebhookDelivery` POSTs the payload, signs the raw
       body with HMAC-SHA256 over `tenants.webhook_secret`, and updates the
       row state.

  Per-event `data` shapes (extra keys callers may pass via `enqueue/3`):
    * `session.submitted` — `responses_count`, `submitted_at`.
    * `session.ready`     — `completed_at`, `responses_count`,
      `duration_total_ms`.
    * `session.failed`    — `reason` (caller-supplied).
    * `session.deleted`   — `reason` (caller-supplied; "retention" |
      "user_request").
  """
  import Ecto.Query, warn: false

  alias Interview.Capture.{Response, Session, SessionQuestion}
  alias Interview.Repo
  alias Interview.Tenants.Tenant
  alias Interview.Webhooks.Delivery

  @payload_version 1

  @doc """
  Idempotently enqueue a webhook for `(session, event_type)`.

  Looks up the tenant via the session, builds the payload, upserts a
  `webhook_deliveries` row, and inserts an Oban job. Calling twice for the
  same `(session_id, event_type)` is safe: the row is updated in place,
  `occurred_at` advances, and a fresh Oban job is enqueued (the worker
  itself is idempotent on `state == "delivered"`).

  Returns `{:ok, delivery}` even when the tenant has no `webhook_url` set
  — we still record the row so observability can see the would-be-event.
  In that case the row stays in `pending` and no job is enqueued.
  """
  def enqueue(%Session{} = session, event_type, data \\ %{})
      when event_type in [
             "session.submitted",
             "session.ready",
             "session.failed",
             "session.deleted"
           ] do
    case Repo.get(Tenant, session.tenant_id) do
      nil ->
        {:error, :tenant_not_found}

      %Tenant{} = tenant ->
        do_enqueue(tenant, session, event_type, data)
    end
  end

  defp do_enqueue(%Tenant{} = tenant, %Session{} = session, event_type, data) do
    now = DateTime.utc_now()

    delivery =
      case Repo.get_by(Delivery,
             session_id: session.id,
             event_type: event_type
           ) do
        nil ->
          %Delivery{}
          |> Delivery.changeset(%{
            tenant_id: tenant.id,
            session_id: session.id,
            event_type: event_type,
            state: "pending",
            payload: build_payload(tenant, session, event_type, data, now),
            occurred_at: now,
            delivered_at: now
          })
          |> Repo.insert!()

        %Delivery{state: "delivered"} = existing ->
          existing

        %Delivery{} = existing ->
          # Re-enqueue: refresh occurred_at and payload (event data may
          # differ between fires), but keep `delivered_at` stable so the
          # receiver sees the same stamp on retries.
          existing
          |> Delivery.changeset(%{
            state: "pending",
            payload: build_payload(tenant, session, event_type, data, now),
            occurred_at: now
          })
          |> Repo.update!()
      end

    if blank?(tenant.webhook_url) or delivery.state == "delivered" do
      {:ok, delivery}
    else
      {:ok, _job} =
        %{"delivery_id" => delivery.id}
        |> Interview.Workers.WebhookDelivery.new()
        |> Oban.insert()

      {:ok, delivery}
    end
  end

  defp build_payload(%Tenant{} = tenant, %Session{} = session, type, extra_data, now) do
    %{
      "v" => @payload_version,
      "type" => type,
      "tenant_id" => tenant.id,
      "session_id" => session.id,
      "external_id" => session.external_id,
      "occurred_at" => DateTime.to_iso8601(now),
      "delivered_at" => DateTime.to_iso8601(now),
      "data" => derive_data(type, session, extra_data)
    }
  end

  defp derive_data("session.submitted", %Session{} = session, extra) do
    %{
      "submitted_at" => iso(now_or(session.completed_at)),
      "responses_count" => count_selected_responses(session.id)
    }
    |> Map.merge(stringify(extra))
  end

  defp derive_data("session.ready", %Session{} = session, extra) do
    %{
      "completed_at" => iso(session.completed_at),
      "responses_count" => count_selected_responses(session.id),
      "duration_total_ms" => sum_selected_durations_ms(session.id)
    }
    |> Map.merge(stringify(extra))
  end

  defp derive_data("session.failed", _session, extra), do: stringify(extra)
  defp derive_data("session.deleted", _session, extra), do: stringify(extra)

  defp count_selected_responses(session_id) do
    Repo.one(
      from sq in SessionQuestion,
        where: sq.session_id == ^session_id and not is_nil(sq.selected_response_id),
        select: count(sq.id)
    ) || 0
  end

  defp sum_selected_durations_ms(session_id) do
    Repo.one(
      from sq in SessionQuestion,
        join: r in Response,
        on: r.id == sq.selected_response_id,
        where: sq.session_id == ^session_id,
        select: coalesce(sum(r.duration_ms), 0)
    ) || 0
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp now_or(nil), do: DateTime.utc_now()
  defp now_or(%DateTime{} = dt), do: dt

  # Webhook receivers expect string keys. Callers may pass atoms; normalise.
  defp stringify(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp stringify(_), do: %{}

  @doc """
  HMAC-SHA256 over `body` using `secret`. Returned string is the raw hex
  digest (caller wraps it in `"sha256=" <> hex`).
  """
  def sign(secret, body) when is_binary(secret) and is_binary(body) do
    :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
  end

  @doc "List the webhook event types we emit. Used for documentation/tests."
  def event_types, do: ["session.submitted", "session.ready", "session.failed", "session.deleted"]

  @doc "Current payload schema version emitted in the `v` field."
  def payload_version, do: @payload_version

  @doc """
  Recent `webhook_deliveries` rows for a tenant, newest first. Used by the
  recruiter settings dashboard.
  """
  def list_recent_deliveries(tenant_id, limit \\ 50) when is_binary(tenant_id) do
    from(d in Delivery,
      where: d.tenant_id == ^tenant_id,
      order_by: [desc: d.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Send a one-off `webhook.test` POST to the tenant's configured endpoint.
  Synchronous, bypasses the `webhook_deliveries` ledger — used by the
  recruiter "Send test webhook" button to verify a receiver before going
  live. Returns `{:ok, %{status: ...}}` or `{:error, reason}`. Adds **no**
  delivery row and **no** Oban job, so the test never counts toward the
  circuit breaker or the retry schedule.

  The receiver sees a payload with `"type": "webhook.test"` so it can
  distinguish from real session events.
  """
  def send_test_event(%Tenant{webhook_url: url}) when url in [nil, ""],
    do: {:error, :not_configured}

  def send_test_event(%Tenant{webhook_secret: secret}) when secret in [nil, ""],
    do: {:error, :missing_secret}

  def send_test_event(%Tenant{} = tenant) do
    now = DateTime.to_iso8601(DateTime.utc_now())

    payload = %{
      "v" => @payload_version,
      "type" => "webhook.test",
      "tenant_id" => tenant.id,
      "occurred_at" => now,
      "delivered_at" => now,
      "data" => %{
        "message" => "Test event from interview platform recruiter settings."
      }
    }

    body = Jason.encode!(payload)
    signature = "sha256=" <> sign(tenant.webhook_secret, body)

    headers = [
      {"Content-Type", "application/json"},
      {"User-Agent", "interview-webhook/1"},
      {"X-Interview-Event", "webhook.test"},
      {"X-Interview-Signature", signature},
      {"X-Interview-Delivery-Id", Ecto.UUID.generate()}
    ]

    Interview.Webhooks.HTTP.post(tenant.webhook_url, headers, body)
  end

  @doc """
  Manually re-enqueue a delivery for another POST attempt. Used by the
  recruiter "retry this delivery" action and ops tooling.

  Idempotent: replaying a row that is already `delivered` returns the
  same row unchanged. For any other state, the row is flipped to
  `pending` (preserving `delivered_at` and `payload` so the receiver
  still sees a stable byte-identical body and Delivery-Id), and a fresh
  Oban job is inserted. Honours the same "no tenant webhook_url" guard
  as `enqueue/3` — a tripped circuit-breaker leaves the row unjobbed.

  Returns `{:ok, %Delivery{}}`, `{:error, :not_found}`, or
  `{:error, :tenant_not_configured}`.
  """
  def replay(delivery_id) when is_binary(delivery_id) do
    case Repo.get(Delivery, delivery_id) do
      nil ->
        {:error, :not_found}

      %Delivery{state: "delivered"} = d ->
        {:ok, d}

      %Delivery{} = d ->
        tenant = Repo.get(Tenant, d.tenant_id)

        cond do
          is_nil(tenant) ->
            {:error, :tenant_not_found}

          blank?(tenant.webhook_url) ->
            {:error, :tenant_not_configured}

          true ->
            {:ok, updated} =
              d
              |> Delivery.changeset(%{state: "pending", last_error: nil})
              |> Repo.update()

            {:ok, _job} =
              %{"delivery_id" => updated.id}
              |> Interview.Workers.WebhookDelivery.new()
              |> Oban.insert()

            {:ok, updated}
        end
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: true
end
