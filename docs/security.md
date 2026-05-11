# Security posture

This document captures the security mechanisms currently in the codebase
and the gaps you'd want to close before pointing this at real customer
data. It's organized as **what's done**, **what's still missing**, and a
**deployment checklist** at the end.

Audience: engineers evaluating production-readiness, auditors, and
operators reviewing the multi-tenant boundary.

---

## 1. Authentication

### What's done

- **No passwords, ever.** Recruiter sign-in is a magic link sent to a
  pre-provisioned email. The link is **single-use**, ≤15 min TTL, marked
  consumed in `recruiter_magic_links` on use. In dev, the URL prints to
  the server log; in prod, an email transport delivers it.
- **Phoenix.Token, audience-scoped salts.**
  `lib/interview/auth/tokens.ex` defines four token classes with separate
  salts, so a token minted for one purpose can't be replayed for another:
  | Token | Salt | TTL | Use |
  |---|---|---|---|
  | bootstrap | `interview-bootstrap-v1` | **5 min** | hand-off from customer backend → iframe |
  | upload_bearer | `interview-upload-v1` | **60 min**, refreshable | candidate's tus PATCHes |
  | recruiter_upload | `interview-rec-upload-v1` | 60 min | recruiter-recorded prompt-asset uploads |
  | recruiter_session | `interview-rec-session-v1` | **24 h**, refreshable | recruiter dashboard |
- **Bootstrap tokens are single-use AND short-TTL.** Consume is atomic
  via a DB row in `sessions.bootstrap_consumed_at`; replay attempts
  return `:already_consumed`.
- **Tenant API keys** are hashed at rest. Only `prefix` (for lookup) +
  `key_hash` (SHA-256 of the secret) live in the DB; the cleartext is
  shown **once** at creation. See `lib/interview/auth/api_keys.ex`.
- **No third-party-cookie dependency.** Cross-site iframes can't rely on
  cookies (Safari ITP, Chrome partitioning). All flow continuity (LV
  reconnect, tus PATCH, postMessage) is driven by tokens, not cookies.
  See PLAN §4.2.

### What's missing

- **No rate limiting on `POST /api/auth/magic-links`.** An attacker can
  enumerate registered emails (request → log scrape would be needed in
  prod, but timing/error responses still leak existence) or DoS the
  email queue. Add a per-IP and per-email throttle.
- **No CAPTCHA / bot protection** on the magic-link request endpoint.
- **No 2FA / MFA.** The magic link IS the "what you have" factor, but
  there's no TOTP option.
- **`recruiter_users.role`** field exists with a default of `"owner"` —
  but is **not enforced anywhere**. Every authenticated recruiter has
  full tenant access. There is no read-only / viewer role.
- **Magic-link consume route doesn't accept a `?return_to=` param**
  (good — no open-redirect vector). Don't add one without a strict
  allowlist.

---

## 2. Multi-tenant isolation

### What's done

- **Shared DB + `tenant_id` column** on every tenant-owned table
  (`interview_templates`, `interview_template_versions`,
  `template_questions` via version, `sessions`, `question_responses` via
  session, `prompt_assets`, `recruiter_users`, `tenant_api_keys`,
  `audit_events`, `webhook_deliveries`).
- **All read queries are tenant-scoped at the context layer.**
  `Interview.Playback.list_sessions/2`, `get_session/2`,
  `get_response_for_playback/2`, `list_templates_with_sessions/1` all
  take `tenant_id` as the first argument and emit
  `where: x.tenant_id == ^tenant_id`. This is the load-bearing
  invariant for the recruiter dashboard.
- **`InterviewWeb.Plugs.RecruiterAuth`** is the canonical authentication
  + tenant-resolution plug. It resolves a session cookie OR
  `Authorization: Bearer rk_…` to a `(recruiter, tenant)` pair and
  assigns `:current_recruiter` / `:tenant` / `:current_scope`. Every
  recruiter-side LV / controller reads its tenant from this assign
  rather than a URL parameter.
- **Existing tests verify cross-tenant isolation.** See
  `test/interview_web/live/recruiter_sessions_live_test.exs` — the test
  "lists only this tenant's sessions" creates a second tenant and
  asserts none of its data appears in the first tenant's listing.
- **Storage keys are per-tenant-prefixed:**
  `tenants/<tenant_id>/sessions/<session_id>/...` (see
  `lib/interview/storage/local.ex`). An adapter bug that ignored a key
  prefix would still produce a path that includes the tenant id, so
  cross-tenant overwrites are extremely unlikely.
- **`InterviewWeb.Plugs.EmbedCSP`** looks up the candidate session, walks
  to its tenant, and emits a `Content-Security-Policy: frame-ancestors`
  header from `tenant.frame_ancestors`. The CSP comes from the **stored
  tenant config**, never from a JWT claim or query parameter — a
  malicious customer can't expand its own frame-ancestors by tampering
  with their bootstrap token.

### What's missing

- **No row-level security at the DB layer.** Tenant isolation is
  enforced in application code only. If a future query forgets the
  `where tenant_id == ^tid` clause, it leaks. Postgres RLS would
  belt-and-brace this; it's not currently configured.
- **No automated cross-tenant audit on every query.** Adding a custom
  Ecto.Repo callback to refuse queries on tenant tables that don't
  include a `tenant_id` filter would catch the omission class above.
  Not implemented.
- **`recruiter_users.role`** doesn't currently differentiate access
  inside a tenant. If you want viewer-only recruiters who can replay
  but not delete, that gate needs writing.

---

## 3. Embed / iframe security (cross-site)

### What's done

- **Per-tenant `frame-ancestors` CSP** on the embed page
  (`lib/interview_web/plugs/embed_csp.ex`):
  - Looked up from `tenants.frame_ancestors` based on the URL session_id.
  - **Wildcards disallowed by default** (PLAN §4.4). Tenants must
    enumerate explicit origins. Wildcards require an admin override
    with a documented risk acknowledgement (any subdomain takeover by
    the tenant becomes a clickjacking vector).
  - If no ancestors are configured for the tenant, default is
    `'self'` (deny external embedding).
- **`X-Frame-Options` is explicitly stripped** on the embed pipeline —
  it would override CSP in older browsers if both were sent.
- **`Referrer-Policy: strict-origin-when-cross-origin`** — query-string
  tokens (the fallback path when postMessage can't deliver early) don't
  leak to other origins.
- **`Permissions-Policy: camera=(self), microphone=(self), autoplay=(self)`** —
  only the embed origin can grant camera/mic. Even if a parent page
  iframes us hostilely, it can't proxy our permissions to a third frame.
- **postMessage protocol is versioned + nonce-protected.** Both ends
  validate:
  - `event.origin` against a per-tenant server-issued allowlist;
  - `event.source` matches the expected window reference;
  - a session-scoped `channelId` nonce, established at the
    `ready`/handshake;
  - the message schema (`v`, `type`, required fields) — anything
    unknown is rejected.
  Origin alone is not sufficient (any same-origin frame on the host
  could otherwise spoof messages).
- **Cookies are not part of auth continuity** in the embed flow. This
  was deliberate to survive Chrome partitioning + Safari ITP.

### What's missing

- **No Content-Security-Policy outside the embed page.** The recruiter
  dashboard runs on `put_secure_browser_headers` defaults (which add
  `X-Frame-Options: SAMEORIGIN`, `X-Content-Type-Options: nosniff`,
  etc.) but no `Content-Security-Policy` is set. Any XSS in the
  recruiter app would have free run. Adding a CSP with `'self'` for
  scripts/styles + nonce-based inline allowances is recommended.
- **No SRI** (Subresource Integrity) on the embed SDK script tag in
  `docs/integration.md`. A compromise of the CDN delivery path could
  ship malicious JS to candidates. SRI hashes per release would
  mitigate.
- **The "parent-trust" boundary is intentional.** The plan does NOT
  protect the candidate from a malicious host tenant: the host can
  withhold the token, overlay the iframe, or read postMessages we send
  to it. CSP only prevents *unrelated* sites from embedding the
  session. PLAN §4.4 names this explicitly — flag it in customer
  agreements.

---

## 4. CSRF, cookies, transport

### What's done

- **`protect_from_forgery`** on every `:browser`, `:embed`, and
  `:recruiter_form` pipeline. All HTML forms include a CSRF token
  (`<input type="hidden" name="_csrf_token" ...>`); LV channel join
  also validates it.
- **`put_secure_browser_headers`** plug — adds
  `X-Content-Type-Options`, `X-Frame-Options`, `X-XSS-Protection`,
  `X-Download-Options`, `X-Permitted-Cross-Domain-Policies`.
- **Session cookie**: signed (not encrypted), `same_site: "Lax"`.
- **Migrations / direct DB endpoint commitment** in PLAN §13: app
  connects via the pooler endpoint, migrations + LISTEN/NOTIFY use the
  **direct** endpoint, `prepare: :unnamed` set for transaction-mode
  pgbouncer compatibility. Reduces the chance of a misconfigured
  long-lived connection that could blow up under load.

### What's missing

- **Cookie not marked `secure: true`** by default. In production the
  endpoint should `force_ssl: [hsts: true]` (PLAN §runtime.exs has the
  example commented out). Without that, a downgrade on first request
  could expose the session cookie. **Action: enable `force_ssl` and
  HSTS in `config/runtime.exs` before prod deploy.**
- **Session cookie is signed, not encrypted.** That's fine for the
  current contents (`recruiter_token` is itself a signed token, no
  PII), but if you ever store anything sensitive in the session, enable
  `encryption_salt` in `endpoint.ex`.
- **No request-size limit beyond Plug.Parsers defaults.** Bandit
  enforces some, but tus PATCHes are explicitly large; if you ever
  expose a non-tus upload, set an explicit cap.

---

## 5. Webhooks

### What's done

- **HMAC-SHA256 signature** over the raw request body, sent as
  `X-Interview-Signature: sha256=<hex>`. Customer side verifies with
  their stored `webhook_secret`.
- **Per-tenant secret** auto-bootstrapped on tenant creation
  (`Tenant.generate_webhook_secret/0`, 32 random bytes → base64url).
  Recruiters can rotate via the dashboard.
- **URL policy** (`Interview.Webhooks.URLPolicy`) refuses, in prod:
  - `http://` (only `https://` allowed);
  - hostname suffixes `.localhost`, `.internal`, `.local`, `.lan`,
    `.home`, `.corp`, `.intranet`;
  - explicit hostnames `localhost`, `ip6-localhost`, `ip6-loopback`;
  - IPv4 literals in private/loopback/link-local/CGNAT ranges;
  - IPv6 unique-local / link-local / loopback ranges.
- **Dev overrides** (`allow_http_urls: true`, `allow_private_destinations: true`)
  are scoped to `config/dev.exs` and `config/test.exs` only.
- **Delivery retries via Oban** with exponential backoff;
  `webhook_deliveries` table records every attempt; pruner job sweeps
  successful deliveries older than 90 days (configurable).

### What's missing

- **Webhook secrets are stored plaintext in the DB.** They must be
  retrievable to sign outbound bodies (one-way hash won't work). To
  belt-and-brace this, encrypt the column at rest with a separate KMS
  key — `cloak`/`vault` libraries cover this. Not implemented.
- **No customer-side public-key verification option** (RSA/Ed25519). All
  webhooks use shared-secret HMAC. For enterprise customers, offering
  signed webhooks with a public key they can pin is the next step.
- **No webhook delivery TLS pinning.** We trust the system trust store;
  a compromised CA could MitM webhook deliveries.

---

## 6. Storage

### What's done

- **Per-tenant prefix on storage keys.** Adapter routing alone can't
  cross tenants without an explicit programming error visible in code
  review.
- **tus capture-instance fencing.** Every tus PATCH carries an
  `Upload-Offset` and is bound to a single
  `(response_id, capture_instance_id)`. A second tab / BFCache restore
  trying to write with the wrong instance gets HTTP **410 Gone** and is
  fenced. See PLAN §5.1.
- **Atomic durability invariant.** The PATCH handler writes bytes to
  the storage adapter, *then* opens a tiny DB transaction to commit
  `bytes_uploaded`. The IDB queue on the client only deletes a chunk
  after both ACKs land. This prevents the "we accepted bytes but
  they're not durable" failure mode.
- **No long-running DB transactions wrap object-store I/O.** This is a
  PLAN §12.5 commitment to avoid pgbouncer footguns.
- **Right-to-delete plumbing.** `Interview.Capture.soft_delete_session/2`
  flips `deleted_at`; the `Workers.SessionDeletion` Oban worker scrubs
  storage artifacts (idempotent), hard-deletes the response rows, fires
  the `session.deleted` webhook, and writes an audit event. The
  session row itself is preserved by default (audit trail) and
  hard-deleted only when its parent template_version is removed.

### What's missing

- **No encryption at rest in the Local adapter.** Files are on the host
  filesystem unencrypted. The S3 adapter (when configured) should
  enable SSE-KMS — PLAN §8.3 names this as required but it's not
  wired in.
- **No tus `Upload-Checksum` extension.** PLAN §5.1 mandated SHA-1
  per-chunk integrity; the server doesn't enforce it yet and the
  client doesn't send it. A malicious or buggy uploader could write
  bytes that don't match what the candidate recorded. Pre-existing
  gap, flagged in the v1.0 known-issues list.
- **No virus / malware scan** on uploaded attachments (PDFs, images).
  Recruiters upload these from their own machines, so the risk surface
  is limited — but if any of those files get re-exposed (sharing,
  links, AI parsing), a scanner like ClamAV is worth adding.
- **Playback streams through Phoenix.** The recruiter playback
  controller checks tenant ownership, then streams bytes from storage
  through the app. Fine for low scale; at higher tenancy counts you'd
  want **short-TTL signed CDN URLs** that bypass the app — not
  implemented.

---

## 7. Audit logging

### What's done

- `audit_events` table records `tenant_id`, `actor_kind`, `actor_id`,
  `action`, `subject_kind`, `subject_id`, `ip_address`, `user_agent`,
  free-form `metadata` map, and `occurred_at`.
- Recorded actions include (non-exhaustive): `magic_link.request`,
  `magic_link.consume`, `template.publish`, `template.set_current_version`,
  `template.delete_version`, `session.delete_request`, `session.delete`,
  `api_key.create`, `api_key.delete`, `webhook_secret.rotate`.
- Retention sweeper (`Interview.Workers.AuditPrune`) deletes rows
  older than 365 days by default; the limit is configurable per
  deployment.
- The `tenant_id` FK is `ON DELETE nilify_all` so deleting a tenant
  preserves the audit history (with `tenant_id = NULL`).

### What's missing

- **No tamper-evidence.** Audit rows can be modified by anyone with DB
  write access. For compliance regimes that require it, you'd want
  hash-chained rows or a write-only append log.
- **No structured shipping to a SIEM.** Audit rows live in the DB;
  surfacing them to e.g. Datadog/Splunk for retention beyond 365 days
  isn't wired up.

---

## 8. Input validation, SQL safety

### What's done

- **All queries go through Ecto** with parameterized bindings — SQL
  injection is not reachable.
- **`String.to_existing_atom/1`** is used on user-supplied keys (e.g.
  the section toggle uses `"versions" | "retake_policy" | "questions"`
  → atom). `String.to_atom/1` is never called on user input.
- **File-upload MIME whitelist** for recruiter attachments:
  `image/png`, `image/jpeg`, `image/webp`, `image/gif`,
  `application/pdf` only. **25 MB max** per file.
  Unsupported types get a 422 with `error: unsupported_type`.

### What's missing

- **No XSS sanitization for `template_questions.prompt_text`.** It's
  declared as markdown; the recruiter authoring path stores it
  verbatim, and the candidate-side LV renders it without HTML escape
  via Phoenix's default safe HEEx escaping. As long as we never use
  `Phoenix.HTML.raw/1` on user content, this is fine — but the field
  *invites* future "render as HTML" feature requests. **Flag any PR
  that introduces `Phoenix.HTML.raw` on a recruiter-authored field.**
- **PDF/image attachments are not stripped of metadata.** EXIF in
  photos and document metadata in PDFs can leak recruiter PII. Not
  scrubbed.

---

## 9. Secrets in the codebase

### What's done

- `SECRET_KEY_BASE` is required at boot in prod (`config/runtime.exs`
  raises if missing).
- `DATABASE_URL` and `OPENAI_API_KEY` are env-driven; `OPENAI_API_KEY`
  is *optional* — without it, transcript jobs permafail with a
  warning, everything else works.

### What's missing

- **`config/dev.exs` has a hard-coded `secret_key_base`** and
  `config/test.exs` has another. They're well-known and only used in
  dev/test, but a developer who copy-pastes the file to a "staging"
  deploy would expose it. **Treat any dev secret as compromised.**
- **No `mix deps.audit` in CI.** Dependency vulnerabilities will not be
  surfaced without manual hex security advisory checks. Recommend
  adding `mix hex.audit` (Hex 2.0+) or third-party `sobelow` to the
  `precommit` alias.
- **`.gitignore` covers `.env` / `.envrc` / `.DS_Store`** but the
  pre-existing dev `secret_key_base` is still in `config/dev.exs`.
  Acceptable for dev convenience but worth flagging.

---

## 10. PII and data handling

### What's done

- **Candidate recordings are PII.** Per-tenant `retention_days` (default
  90) drives `Interview.Workers.RetentionSweeper`, which enqueues
  `SessionDeletion` for any session whose `completed_at + retention_days`
  is past. Storage + response rows are scrubbed.
- **Right-to-delete API**: `DELETE /api/sessions/:id` triggers the same
  worker.
- **`prompt_assets`** (recruiter-recorded video prompts) are kept
  forever by design (PLAN §3.4 + `lib/interview/templates/prompt_asset.ex`
  module doc). They're studio content, not candidate PII.

### What's missing

- **PII in logs.** `candidate_email`, `recruiter_email`, and IP
  addresses appear in audit rows and routinely in `[debug]` log lines.
  No PII redaction filter is configured. For GDPR jurisdictions add a
  `Logger.add_translator` or use a structured logger backend that
  redacts known fields.
- **No data-residency switching.** Storage adapter is single-region.
  PLAN §12.8 names "EU customer signs" as the trigger for regional
  buckets / regional Phoenix — not implemented.

---

## 11. Deployment checklist (pre-prod)

Treat this as the required hardening pass before pointing real
customers at the app.

- [ ] Set a strong `SECRET_KEY_BASE` (≥64 bytes) via env. Never reuse
      the dev value.
- [ ] Enable `force_ssl: [hsts: true]` in `config/runtime.exs`. Confirm
      HSTS includes subdomains if the embed origin needs it.
- [ ] Set `cookie: secure: true` once HTTPS is enforced.
- [ ] Configure Plug.SSL with `rewrite_on: [:x_forwarded_proto]` if
      behind a load balancer.
- [ ] Switch the storage adapter from `Interview.Storage.Local` to the
      S3/Tigris adapter; enable SSE-KMS encryption at rest.
- [ ] Confirm `Interview.Webhooks` runs with **`allow_http_urls: false`**
      and **`allow_private_destinations: false`** (defaults in
      `config/config.exs`; only `config/dev.exs` and `config/test.exs`
      flip them on).
- [ ] Configure DNS + TLS for the recorder origin (`interview.yourdomain.com`)
      and the CDN delivering the embed SDK.
- [ ] For every tenant, set `frame_ancestors` explicitly. Refuse to
      deploy with `[]` or `["*"]` unless that tenant has signed the
      wildcard-risk acknowledgement.
- [ ] Tighten the `:browser` pipeline with an explicit
      Content-Security-Policy header (script-src 'self', etc.) — not
      just `put_secure_browser_headers`.
- [ ] Add rate limiting to `POST /api/auth/magic-links`,
      `POST /api/sessions`, and the bootstrap-consume path. `PlugAttack`
      or `hammer` are the usual choices.
- [ ] Wire up `mix hex.audit` (or `sobelow`) in CI; fail builds on
      advisories.
- [ ] Configure a log shipper with a PII redaction filter for
      `email`, `ip_address`, `user_agent`.
- [ ] Enable Postgres SSL (`ssl: true` in `config/runtime.exs` — example
      is commented).
- [ ] Roll over the dev `recruiter_users` and tenant API keys before
      seeding production tenants.
- [ ] Decide retention for `audit_events`. Default 365 d may not match
      your compliance regime.
- [ ] Confirm DPA template + SOC 2 controls owner (PLAN §8.3 flags
      these as out-of-scope for the code, in-scope for legal).

---

## 12. Quick reference: tenant boundary in code

When reviewing a PR for tenant-isolation safety, check that:

1. **Every Ecto query** on a tenant-owned table includes
   `where: x.tenant_id == ^tenant_id` or joins through a parent that
   does.
2. **The tenant id comes from `socket.assigns.tenant.id` or
   `conn.assigns.tenant.id`**, never from a path/query/body param.
3. **`Interview.Playback.*` functions** that take `tenant_id` are
   called with `current_recruiter.tenant_id` (or equivalent).
4. **Storage keys** are constructed with the tenant id as the first
   prefix component.
5. **Webhook recipients** are looked up from `tenant.webhook_url` —
   not from request bodies or referrer headers.
6. **Audit log entries** carry the correct `tenant_id`. Missing
   tenant_id = orphaned audit row.

The class of bug to look for is *"this LV/controller is mounted under
`:recruiter` so I have a current_scope, but the query inside this
helper takes a bare id from the URL and doesn't re-check the tenant
boundary."* That's IDOR.
