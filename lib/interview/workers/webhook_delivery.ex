defmodule Interview.Workers.WebhookDelivery do
  @moduledoc """
  Oban worker that POSTs `Interview.Webhooks.Delivery` payloads to the
  tenant's `webhook_url` (PLAN §3.1, §7 Phase 4, §11 #8).

  Behaviour:
    * Body is `Jason.encode!(delivery.payload)`.
    * `X-Interview-Signature: sha256=<hex>` HMAC-SHA256 over the raw body
      using `tenants.webhook_secret`.
    * 2xx → mark delivered.
    * 408/429/5xx → retry (`{:error, ...}` defers to Oban backoff).
    * Other 4xx → permanent failure (mark `failed`, no retry, drop the job).
    * Transport errors → retry; SSRF/URL-policy errors → permafail.
    * `max_attempts: 14` with Oban's default `attempt^4 + 15 + jitter`
      backoff yields ~24h coverage (sum 1..13 ≈ 89_466 s = ~24.85 h).

  Idempotency: the receiver sees a stable `delivered_at` (stamped at row
  creation) on every retry; payload bytes are byte-identical between
  retries because the HMAC must verify. If a prior worker crashed after
  flipping the row to `in_flight`, the next `perform/1` resets to
  `pending` so dashboards reflect reality before re-posting.
  """
  use Oban.Worker, queue: :webhook, max_attempts: 14, unique: [period: 60]

  require Logger

  alias Interview.Repo
  alias Interview.Tenants.Tenant
  alias Interview.Webhooks
  alias Interview.Webhooks.Delivery

  @permanent_4xx_excluded [408, 429]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"delivery_id" => id}, attempt: attempt}) do
    case Repo.get(Delivery, id) do
      nil ->
        {:discard, "delivery row missing"}

      %Delivery{state: "delivered"} ->
        :ok

      %Delivery{state: "in_flight"} = delivery ->
        # A prior worker crashed mid-POST. The row is misleadingly stuck
        # in `in_flight`; reset to `pending` before attempting again so
        # ops dashboards reflect reality. The next post_and_record will
        # flip it back to `in_flight` ahead of the actual request.
        {:ok, delivery} =
          delivery |> Delivery.changeset(%{state: "pending"}) |> Repo.update()

        deliver(delivery, attempt)

      %Delivery{} = delivery ->
        deliver(delivery, attempt)
    end
  end

  defp deliver(%Delivery{} = delivery, attempt) do
    tenant = Repo.get!(Tenant, delivery.tenant_id)

    cond do
      blank?(tenant.webhook_url) ->
        {:discard, "webhook_url cleared"}

      blank?(tenant.webhook_secret) ->
        mark_failed(delivery, attempt, nil, "missing webhook_secret", nil)
        {:discard, "missing webhook_secret"}

      true ->
        post_and_record(tenant, delivery, attempt)
    end
  end

  defp post_and_record(%Tenant{} = tenant, %Delivery{} = delivery, attempt) do
    body = Jason.encode!(delivery.payload)
    signature = "sha256=" <> Webhooks.sign(tenant.webhook_secret, body)

    headers = [
      {"Content-Type", "application/json"},
      {"User-Agent", "interview-webhook/1"},
      {"X-Interview-Event", delivery.event_type},
      {"X-Interview-Signature", signature},
      {"X-Interview-Delivery-Id", delivery.id}
    ]

    {:ok, delivery} =
      delivery
      |> Delivery.changeset(%{state: "in_flight", attempts: attempt})
      |> Repo.update()

    case Interview.Webhooks.HTTP.post(tenant.webhook_url, headers, body) do
      {:ok, %{status: status, body: resp_body}} when status in 200..299 ->
        mark_delivered(delivery, attempt, status, preview(resp_body))
        :ok

      {:ok, %{status: status, body: resp_body}}
      when status >= 400 and status < 500 and status not in @permanent_4xx_excluded ->
        mark_failed(delivery, attempt, status, "permanent #{status}", preview(resp_body))
        {:discard, "permanent 4xx (#{status})"}

      {:ok, %{status: status, body: resp_body}} ->
        record_retry(delivery, attempt, status, preview(resp_body))
        {:error, "retry status=#{status}"}

      {:error, reason} ->
        if permanent_url_error?(reason) do
          mark_failed(delivery, attempt, nil, "url: #{inspect(reason)}", nil)
          {:discard, "permanent url error (#{inspect(reason)})"}
        else
          record_retry(delivery, attempt, nil, "transport: #{inspect(reason)}")
          {:error, reason}
        end
    end
  end

  # SSRF / URL-policy rejections are not retryable — the URL itself is bad
  # and won't pass next attempt either. Treat as permanent.
  defp permanent_url_error?(:private_ip_disallowed), do: true
  defp permanent_url_error?(:dns_no_records), do: true
  defp permanent_url_error?(:invalid_url), do: true
  defp permanent_url_error?(:scheme_required), do: true
  defp permanent_url_error?(:http_disallowed), do: true
  defp permanent_url_error?(:host_required), do: true
  defp permanent_url_error?(:hostname_denied), do: true
  defp permanent_url_error?({:dns_lookup_failed, _}), do: false
  defp permanent_url_error?(_), do: false

  defp mark_delivered(%Delivery{} = d, attempts, status, preview) do
    updated =
      d
      |> Delivery.changeset(%{
        state: "delivered",
        attempts: attempts,
        last_status: status,
        last_error: nil,
        response_body_preview: preview
      })
      |> Repo.update!()

    audit(updated, "webhook.deliver_success", %{"status" => status, "attempts" => attempts})
    updated
  end

  defp mark_failed(%Delivery{} = d, attempts, status, error, preview) do
    updated =
      d
      |> Delivery.changeset(%{
        state: "failed",
        attempts: attempts,
        last_status: status,
        last_error: error,
        response_body_preview: preview
      })
      |> Repo.update!()

    maybe_trip_circuit_breaker(updated)

    audit(updated, "webhook.deliver_permafail", %{
      "status" => status,
      "attempts" => attempts,
      "error" => error
    })

    updated
  end

  # If the last N deliveries for this tenant have all permafailed, null the
  # tenant's webhook_url so we stop hammering a dead endpoint. The recruiter
  # can re-set it from the settings UI after fixing the receiver. Configurable
  # via `config :interview, Interview.Webhooks, circuit_breaker_threshold: N`.
  # `0` or negative disables the breaker entirely.
  defp maybe_trip_circuit_breaker(%Delivery{tenant_id: tid}) do
    threshold = circuit_breaker_threshold()

    if threshold > 0 and consecutive_recent_failures(tid, threshold) >= threshold do
      trip(tid, threshold)
    end

    :ok
  end

  defp consecutive_recent_failures(tenant_id, limit) do
    import Ecto.Query, only: [from: 2]

    from(d in Delivery,
      where: d.tenant_id == ^tenant_id,
      order_by: [desc: d.updated_at],
      limit: ^limit,
      select: d.state
    )
    |> Repo.all()
    |> Enum.take_while(&(&1 == "failed"))
    |> length()
  end

  defp trip(tenant_id, threshold) do
    case Repo.get(Tenant, tenant_id) do
      %Tenant{webhook_url: url} = tenant when is_binary(url) and url != "" ->
        {:ok, _} =
          tenant
          |> Tenant.changeset(%{webhook_url: nil})
          |> Repo.update()

        Interview.Audit.log!(%{
          tenant_id: tenant.id,
          actor_kind: "system",
          action: "webhook.circuit_breaker_tripped",
          subject_kind: "tenant",
          subject_id: tenant.id,
          metadata: %{
            "consecutive_failures" => threshold,
            "cleared_webhook_url" => url
          }
        })

        :telemetry.execute(
          [:interview, :webhook, :circuit_breaker_tripped],
          %{consecutive_failures: threshold},
          %{tenant_id: tenant.id}
        )

      _ ->
        :ok
    end
  end

  defp circuit_breaker_threshold do
    Application.get_env(:interview, Interview.Webhooks, [])
    |> Keyword.get(:circuit_breaker_threshold, 20)
  end

  defp record_retry(%Delivery{} = d, attempts, status, error_or_preview) do
    {error, preview} =
      case status do
        nil -> {error_or_preview, nil}
        _ -> {"retryable #{status}", error_or_preview}
      end

    updated =
      d
      |> Delivery.changeset(%{
        state: "pending",
        attempts: attempts,
        last_status: status,
        last_error: error,
        response_body_preview: preview
      })
      |> Repo.update!()

    audit(updated, "webhook.deliver_fail", %{
      "status" => status,
      "attempts" => attempts,
      "error" => error
    })

    updated
  end

  defp audit(%Delivery{} = d, action, metadata) do
    Interview.Audit.log!(%{
      tenant_id: d.tenant_id,
      actor_kind: "system",
      action: action,
      subject_kind: "webhook_delivery",
      subject_id: d.id,
      metadata: Map.merge(%{"event_type" => d.event_type, "session_id" => d.session_id}, metadata)
    })

    telemetry_event =
      case action do
        "webhook.deliver_success" -> :delivered
        "webhook.deliver_fail" -> :retry
        "webhook.deliver_permafail" -> :permafail
        _ -> nil
      end

    if telemetry_event do
      :telemetry.execute(
        [:interview, :webhook, telemetry_event],
        %{attempts: d.attempts || 0},
        %{delivery_id: d.id, event_type: d.event_type}
      )
    end
  end

  defp preview(body) when is_binary(body), do: String.slice(body, 0, 512)
  defp preview(_), do: nil

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: true
end
