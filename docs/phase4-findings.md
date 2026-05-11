# Phase 4 — hardening

> Status as of 2026-05-11.
> Closes PLAN §7 Phase 4. Tests 284 → 307 (Elixir) green; the 7 standing
> failures (page/capture HTML-string mismatches) are pre-existing and
> untouched by this phase. `mix precommit` runs.

## What was built

Phase 4 is mostly closing gaps in code that was already standing up:
audit log, retention/deletion, and webhook delivery were all scaffolded
through Phases 2–3. This phase made them production-shaped.

### Webhook delivery — P0 / P1 / P2

| Capability | Where | Status |
|---|---|---|
| **TLS peer verification** on outbound POSTs. `:httpc` defaulted to `verify_none`; now passes explicit `verify: :verify_peer`, system CA bundle via `:public_key.cacerts_get/0`, hostname check, TLS 1.2 + 1.3 only, SNI. | `lib/interview/webhooks/http.ex` | ✅ |
| **SSRF guard** — `Interview.Webhooks.URLPolicy` validates URL shape in the Tenant changeset (https-only in prod, deny `localhost` / `*.localhost` / `*.internal` / `*.local` / RFC1918 / loopback / link-local / cloud metadata / CGNAT IPv4 literals) AND resolves DNS at request time in the `Httpc` adapter to catch DNS-rebinding or operator mistakes. Config-flag relaxation for dev/test (`allow_http_urls`, `allow_private_destinations`). | `lib/interview/webhooks/url_policy.ex`, `lib/interview/tenants/tenant.ex`, `lib/interview/webhooks/http.ex` | ✅ |
| **Response body cap** sliced to 8 KB before storing the preview so a misbehaving receiver can't bloat `webhook_deliveries.response_body_preview`. Full streaming cap is a P3 follow-up (requires moving off `:httpc`). | `lib/interview/webhooks/http.ex` | ✅ |
| **URL-policy errors classified as permafail** in the worker so SSRF/DNS/scheme errors don't burn through 14 retries before discarding. | `lib/interview/workers/webhook_delivery.ex` | ✅ |
| **Payload `v:1`** added so receivers can branch on schema version. Receivers without `v` should treat as `v=1` (documented). | `lib/interview/webhooks.ex` | ✅ |
| **Enriched `session.ready` / `session.submitted` data** — `responses_count`, `duration_total_ms` (canonical answers only, via `session_questions.selected_response_id`), `completed_at` / `submitted_at`. Atom-keyed caller extras get string-normalised. | `lib/interview/webhooks.ex` | ✅ |
| **`session.deleted` carries `reason`** — `retention` or `user_request`. Right-to-delete and retention sweeps both populate it. | `lib/interview/workers/session_deletion.ex` | ✅ |
| **`max_attempts: 12 → 14`** so Oban's default `attempt^4 + 15 + jitter` backoff sums to ~24.85 h, matching the 24h promise in the integration docs. | `lib/interview/workers/webhook_delivery.ex` | ✅ |
| **Stale `in_flight` recovery** — `perform/1` resets a row that's stuck in `in_flight` (prior worker crash) to `pending` before the next attempt so dashboards reflect reality. | `lib/interview/workers/webhook_delivery.ex` | ✅ |
| **Auto-generated `webhook_secret` on tenant create** — new tenants ship with a 32-byte URL-safe random secret; never regenerated on update. `Tenant.generate_webhook_secret/0` is exposed for the rotate flow. | `lib/interview/tenants/tenant.ex` | ✅ |
| **Circuit breaker** — after N (default 20) consecutive permafails on a tenant, the worker nulls `webhook_url`, audit-logs `webhook.circuit_breaker_tripped`, and emits a telemetry event. Recruiter sets a new URL via settings UI after fixing the receiver. | `lib/interview/workers/webhook_delivery.ex` | ✅ |
| **`Webhooks.replay/1`** — manual re-enqueue for a failed row. Idempotent on `delivered`. Powers the recruiter "Replay" button. | `lib/interview/webhooks.ex` | ✅ |
| **`Webhooks.send_test_event/1`** — synchronous `webhook.test` POST that bypasses the ledger entirely (no row, no Oban job, no circuit-breaker counter). Used by the "Send test webhook" button. | `lib/interview/webhooks.ex` | ✅ |
| **`/recruiter/settings` LiveView** — edit `webhook_url`, masked secret display, **Rotate secret**, **Send test webhook**, and a 50-row recent-deliveries table with **Replay** buttons on failed rows. Audit logs every action. | `lib/interview_web/live/recruiter_settings_live.ex` | ✅ |
| **Webhook delivery prune** — daily cron drops `webhook_deliveries` older than 90 days. Configurable via `config :interview, Interview.Webhooks, deliveries_retention_days: N`. | `lib/interview/workers/webhook_deliveries_prune.ex` | ✅ |
| Updated **integration docs** §8: `v:1`, per-event `data` shapes, 14-attempt / 24h backoff curve. | `docs/integration.md` | ✅ |

### Audit log

Already shipped through Phase 2/3 — schema (`audit_events`), indexes,
`Interview.Audit.log/log!/list_for_tenant/list_for_subject`, and 19 call
sites covering session lifecycle, auth, template publish, webhook events,
deletion, settings actions. This phase added:

| Capability | Where | Status |
|---|---|---|
| **Audit log prune** — daily cron drops `audit_events` older than 365 days. Configurable via `config :interview, Interview.Audit, retention_days: N`. SOC-2 baseline. | `lib/interview/workers/audit_prune.ex` | ✅ |

### Retention / deletion

Already shipped — `RetentionSweeper` cron, `SessionDeletion` worker
(deletes storage artifacts + scrubs response rows + soft-sets
`sessions.deleted_at`), `DELETE /api/sessions/:id` for right-to-delete,
per-tenant `retention_days`. This phase made one behavioural change:

| Capability | Where | Status |
|---|---|---|
| **`session.deleted` fires on retention sweeps**, not just right-to-delete. Customers get a durable receipt for compliance. The `data.reason` field is `"retention"` vs `"user_request"` so receivers can filter. Was previously suppressed via `emit_webhook: false`. | `lib/interview/workers/retention_sweeper.ex` | ✅ |

### Operational / non-code — deferred to post-deploy validation

These two gates were scoped as "Phase 4 manual jobs" but are
**deliberately deferred until a Fly staging deploy is up**. Running
them on a local laptop doesn't reflect Fly NIC / TLS CPU /
Phoenix→Tigris internal bandwidth / Neon pooler latency — the numbers
would be cosmetic, not the §12.2 capacity claims they're supposed to
validate. PLAN §7 Phase 4 now calls these out as "post-deploy
validation gates." They block "Phase 4 signed off" but do not block any
code work or downstream phases.

| Item | Where | Status |
|---|---|---|
| **Safari macOS soak** — **retired by decision #14** (Chrome+Edge only for v1). The multi-hour Safari soak gate is no longer part of Phase 4 exit. `docs/safari-soak-checklist.md` is preserved as the v1.1 reopening playbook. | `docs/safari-soak-checklist.md` | 🗄️ retired |
| **Multi-hour Chrome desktop soak** against the deployed Fly endpoint — what replaces the Safari soak. Same scenario matrix, repurposed for Chrome. | (carry from `docs/safari-soak-checklist.md`) | ⏳ blocked on Fly deploy |
| **Load test 500 concurrent** — `mix loadtest.run --concurrency 500` against the deployed Fly endpoint. Driver shipped earlier (Phase 1 had 50-concurrent floor); the actual 500-uploader bench has to wait for real-network conditions to mean anything. | `lib/mix/tasks/loadtest.run.ex` | ⏳ blocked on Fly deploy |

## Decision-log changes

None. Phase 4 implements PLAN §7 Phase 4 as written.

## Gotchas worth knowing for next session

- **`:httpc` doesn't stream response bodies.** We slice to 8 KB after read
  so the DB preview is bounded, but a malicious receiver can still spike
  worker memory up to the `timeout: 15_000` window × their bandwidth.
  Moving to Finch/Mint with `stream: ...` is the proper fix; mentioned
  in `lib/interview/webhooks/http.ex` moduledoc as a P3 follow-up.

- **The `webhook.test` event is invisible to the ledger.** It's
  synchronous, never persists a `webhook_deliveries` row, never trips
  the circuit breaker. Tenants confused by "I sent a test but I don't
  see it in the deliveries panel" — that's by design. Add a note in the
  recruiter UI if customers ask.

- **URL-policy denial messages.** The Tenant changeset surfaces "must
  not point at a private IP" / "must not point at an internal hostname"
  to the recruiter. The strings are user-facing; treat as part of the
  product copy.

- **`config :interview, Interview.Webhooks`** is now a multi-key bag:
  `adapter` (test stub), `allow_http_urls`, `allow_private_destinations`,
  `circuit_breaker_threshold`, `deliveries_retention_days`. Strict in
  prod, relaxed in dev. Tests inherit prod-strict so prod-shaped
  validation is exercised in CI; the stub adapter bypasses the runtime
  destination check entirely.

- **`session.deleted` will fire for retention sweeps now.** A tenant
  with 90-day retention and 100 sessions/day past the threshold will
  see ~100 webhooks/night. If a tenant pushes back on volume, options
  are: per-tenant opt-out flag, or a daily roll-up event. v1 commits
  to per-session emit for compliance-receipt clarity.

- **Circuit breaker thresholds are global.** A 20-permafail threshold
  is shared across all tenants. A per-tenant override knob is easy to
  add when customer support asks ("we're rolling out a new receiver, can
  you bump our threshold for 24h?").

- **Audit-log retention is global** (365 days). No per-tenant override.
  SOC-2 typically wants 1y; longer is operationally a problem because
  the table is hot-write. If a customer needs >1y retention, archive to
  S3 cold storage rather than keeping in Postgres.

- **`webhook_deliveries.session_id` is `on_delete: :nilify_all`** but
  sessions are never hard-deleted (only soft-deleted via `deleted_at`),
  so the FK never nilifies. The prune job is what actually cleans up.

- **`Httpc` adapter checks DNS at request time, NOT at enqueue time.**
  This is intentional defence-in-depth (DNS rebinding) but it also
  means a tenant who configures a freshly-registered domain whose DNS
  hasn't propagated yet will see transient `{:dns_lookup_failed, _}`.
  Those are *retryable* (not classified as permanent URL errors).

- **`mix loadtest.run` does not call `capture_complete`** by default.
  Driver leaves rows in `recording` state; the abandoned-session
  sweeper cleans up after the test. Pass `--complete true` to fire
  EOFs at the end if you want a clean ledger.

## Carries into next session

- **Phase 4 manual jobs**: the multi-hour Safari soak and the
  500-concurrent loadtest still need to be **run**, not just coded for.
  Block on real hardware + a deployed staging endpoint.

- **`:httpc` → Finch migration** for proper streaming response cap
  (P3, security follow-up).

- **Per-tenant overrides** for circuit-breaker threshold and webhook
  event filtering (defer until customer asks).

- **Recruiter-facing audit log view** (LiveView on top of
  `Audit.list_for_tenant/2`). Not strictly needed for compliance —
  audit_events is a DB query away — but a nice operations surface.

- **Webhook signature key rotation grace window** (P2 #11 in the
  webhook plan): currently rotating the secret is a hard cutover.
  Adding `previous_webhook_secret` + an expiry would let customers
  validate against either secret during a switchover. Defer until
  pulled by a real customer.

- **Drop `sessions.signed_token`** once confirmed unused (auth carry).

- **Swoosh for real magic-link email** (auth carry).

- **Asset-reference existence checks in importers** (auth carry).

- **JS test runner in `mix precommit`** (Phase 3 carry).

- **CDN-fronted `embed.v1.js`** (Phase 3 deploy concern).

## Phase-4 exit checklist

PLAN §7 Phase 4 lines (post decision #14 scope cut):

- [x] Webhook delivery (signed, retried). Plus: TLS verify, SSRF guard,
      circuit breaker, replay, settings UI, prune.
- [x] Audit log. Plus: prune job.
- [x] Retention/deletion jobs. Plus: `session.deleted` webhook on
      retention.
- [ ] **Post-deploy:** Extended Chrome/Edge desktop soak (multi-hour,
      real-world WiFi) against the Fly staging endpoint. Replaces the
      retired Safari soak (decision #14). Checklist at
      `docs/safari-soak-checklist.md` — repurpose the scenario matrix
      against Chrome.
- [ ] **Post-deploy:** Load test: 500 concurrent recordings against the
      Fly staging endpoint; verify §12.2 numbers. Driver ready
      (`mix loadtest.run`).

**Code-side of Phase 4 is done.** The two unticked boxes are
post-deploy validation gates — running them on a local laptop is
theatre (clean WiFi, idle CPU, no Fly NIC / TLS / internal-network
path). They block "Phase 4 signed off" but do **not** block code work
on Phase 5, on Phase 3 carries, or on the Fly deployment itself.
Schedule them as the first thing after staging is up.

## Verification

```
mix precommit                                  # 307 Elixir tests, 7 pre-existing failures
mix test test/interview/webhooks*                # 28 tests
mix test test/interview/workers/                 # 13 tests
mix test test/interview_web/live/recruiter_settings_live_test.exs  # 7 tests
```

Manual end-to-end:

1. `mix phx.server`
2. Sign in as a recruiter, visit `/recruiter/settings`.
3. Set a webhook URL, hit **Send test webhook** — receiver gets a
   `webhook.test` POST with `v:1` and an HMAC-SHA256 signature.
4. Submit a session as a candidate. Verify the receiver gets
   `session.submitted` and `session.ready` with the documented `data`
   fields.
5. Point the URL at a 500-only endpoint, watch the deliveries table
   accumulate `failed` rows, hit **Replay** to re-attempt.
6. With `circuit_breaker_threshold` set low (e.g., 3) in dev, watch
   `webhook_url` get nulled after the threshold and an audit event
   recorded.
