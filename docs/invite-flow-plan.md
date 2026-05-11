# Recruiter-driven invite flow — implementation plan

> Goal: a recruiter signed into the dashboard can create a template,
> generate a shareable link bound to one specific candidate, hand that
> link off (copy / email manually for v1, real email later), and later
> see exactly who got which link and where they are in the funnel.
>
> Today the candidate journey is API-driven (`POST /api/sessions` from
> a customer backend). This plan adds an in-app path that does not
> require any external integration — useful for solo recruiters and
> for demos.

## Scope (v1)

In scope:

- **Invite create UI** on the template editor page: form for candidate
  email + optional display name, "Generate link" button.
- **Invite list** per template: one row per invite with state, copy
  link button, revoke button.
- **Invite endpoint** (`GET /invite/:invite_token`): public, idempotent;
  resolves the invite, mints a fresh bootstrap token, redirects to
  `/capture/:sid?token=…`.
- **Cross-tenant invites tab** at `/recruiter/invites`: a flat list of
  every invite for the tenant, mirroring the existing sessions list.
  Filterable by template + state.

Explicitly out of scope (carry to v2):

- Sending the email itself. v1 prints the URL in the dashboard +
  copies to clipboard; the recruiter pastes it wherever. (Phase 4 ships
  Swoosh; we revisit then.)
- Bulk invite (CSV upload). One at a time for v1.
- Reminder cadences ("nudge after 3 days").
- Per-invite expiry override. v1 uses a tenant-wide default (15 days).
- Per-template invite link ("anyone with this URL can take it"); v1 is
  always per-candidate. Reduces blast radius if a link leaks.
- Template-version selection in the UI: invite always uses the
  template's current published version at click time. (Frozen in the
  Session at first click, per existing PLAN §3.4 versioning rule.)

## Data model

One narrow change: extend `sessions` so an invite *is* a session.

We considered a separate `session_invites` table but it duplicates 90%
of `sessions` and forces a dance to materialise a session on first
click. Pre-creating the session at invite time is simpler, and the
existing soft-delete + tenant scoping all just work.

### `sessions` migration

Add three columns, two indexes:

```elixir
add :invite_token,        :binary_id              # null until invited
add :invite_token_hash,   :binary                 # sha256 of invite_token
add :invite_expires_at,   :utc_datetime_usec     # null until invited
add :invite_revoked_at,   :utc_datetime_usec
add :invited_at,          :utc_datetime_usec
add :invited_by,          :binary_id              # recruiter_user_id
add :candidate_name,      :string

create unique_index(:sessions, [:invite_token_hash], where: "invite_token_hash IS NOT NULL")
```

Storage choice: keep the **plaintext** `invite_token` in the DB *and*
its sha256. Rationale:

- The link is meant to be shared — it isn't a secret in the same way a
  bootstrap_token is. Recruiters need to read it back to copy it.
- Hashing alone (like magic links) would force a one-way "show once,
  paste it now or lose it" UX, which defeats the purpose of an invite
  the recruiter pulls up two days later.
- We still index the **hash** so invite lookup at click time is
  constant-time and side-channel resistant against timing attacks on
  the token bytes.

Token format: `iv_` + 32-byte url-safe base64 (no padding). The
prefix lets us tell invites apart from other tokens in logs.

### State machine (no schema change, just doc)

`sessions.state` already covers what we need:

- `pending`     — invited, never visited.
- `in_progress` — first click consumed bootstrap.
- `submitted`   — candidate hit submit.
- `ready`       — finalize promoted it.
- `failed` / `expired` — terminal.

Plus `invite_revoked_at IS NOT NULL` orthogonally marks "recruiter
killed the link". A revoked invite still keeps its row (audit trail)
but the invite endpoint refuses to mint a bootstrap.

## Routes

```
# Public — no auth, just a long token in the URL.
get "/invite/:invite_token", InviteController, :show

# Recruiter authenticated — inside live_session :recruiter
live "/recruiter/invites", RecruiterInvitesLive, :index
```

The existing template editor (`/recruiter/templates/:id`) gains an
"Invites" section in-page; no new route for it.

`InviteController` lives outside the recruiter pipeline because the
candidate side is unauthenticated (the bearer is the URL itself). It
sits in the `:browser` pipeline so the eventual redirect to
`/capture/:sid?token=…` works in the same browsing context.

## Auth & security

- **Invite token entropy**: 32 bytes (256 bits) — same as our magic
  links and bootstrap. Collision-impossible.
- **Rate limit**: `InviteController.show` calls (cheap DB lookup, then
  bootstrap mint, then redirect) get a per-IP token bucket. Aim 30
  req/min/IP. Brute-forcing a 256-bit token is infeasible; the limit is
  there to keep an attacker from amplifying a leaked link.
- **Revocation**: setting `invite_revoked_at` is a single `update_all`
  scoped to `(tenant_id, id)`. The invite endpoint does the freshness
  check with `is_nil(invite_revoked_at) AND invite_expires_at > now()`.
- **Tenant scoping**: invites belong to a tenant via the session row's
  `tenant_id`. Cross-tenant reads return 404, same pattern as the
  playback queries.
- **Audit log entries**: `invite.create`, `invite.revoke`,
  `invite.consume` (per click). Per-click logging means we can answer
  "did this candidate ever open the link" even before they consume the
  bootstrap.
- **CSRF**: the invite URL is a GET — no CSRF token needed since it has
  no side effects on its own (mint+redirect is idempotent from the
  candidate's POV; multiple clicks in the same minute simply produce
  multiple bootstrap tokens, all single-use, only one of which the
  browser will end up consuming).

## Context functions

All in a new `Interview.Invites` module:

| Function | Purpose |
|---|---|
| `create_invite(tenant_id, template_id, %{candidate_email, candidate_name, invited_by})` | Resolve the template's current published version, insert a `Session` with `state="pending"` and the invite columns set, return `{:ok, %Session{}, url}`. |
| `list_invites(tenant_id, opts)` | All sessions where `invite_token_hash IS NOT NULL`. Optional `:template_id`, `:state`, `:include_revoked` filters. |
| `revoke_invite(tenant_id, session_id)` | Set `invite_revoked_at`. Idempotent. |
| `consume_invite(token)` | Lookup by sha256 hash; verify not expired/revoked; bump `invited_consumed_count` (or just rely on audit log); return `{:ok, %Session{}}` or `{:error, reason}`. |
| `invite_url(session)` | Helper: `endpoint_url() <> "/invite/" <> session.invite_token`. |

`create_invite` rejects if the template has no published current
version (we'd have nothing to point the session at).

## UI

### Template editor — new "Invites" section

Placed below the existing "Questions" / "Publish" sections.

```
Invites
─────────────────────────────────────────
[ candidate email____________ ] [ name (optional) ] [ Generate link ]

| Email           | Name | State        | Sent     | Last seen | Link              |
|-----------------|------|--------------|----------|-----------|-------------------|
| alice@…         | —    | pending      | 2d ago   | —         | [Copy] [Open] [✕] |
| bob@…           | Bob  | in_progress  | 1d ago   | 2h ago    | [Copy] [Open] [✕] |
| carol@…         | —    | ready        | 5d ago   | 4d ago    | [Open session]    |
```

- **Copy** copies the URL to clipboard (JS hook on the button).
- **Open** opens the URL in a new tab so the recruiter can preview
  what the candidate sees.
- **✕** revokes (with `data-confirm`).
- **Open session** (when state ≥ submitted) deep-links to
  `/recruiter/sessions/:id` for playback.

### Standalone `/recruiter/invites`

A flat list across all templates. Same columns + a template column.
Filters: state (chips), template (dropdown). Revoked invites stay in
the list with a strikethrough on the email + a "revoked" badge —
recruiter still needs to see them as part of the audit trail.
Mirrors `RecruiterSessionsLive` so the implementation is mostly
copy-shape-paste.

Add a top-nav link "Invites" between Sessions and Templates.

## Invite controller

```elixir
def show(conn, %{"invite_token" => raw}) do
  case Interview.Invites.consume_invite(raw) do
    {:ok, %Session{} = session} ->
      {:ok, %{token: bootstrap}} = Bootstrap.mint(session)

      Interview.Audit.log!(%{
        tenant_id: session.tenant_id,
        actor_kind: "candidate",
        action: "invite.consume",
        subject_kind: "session",
        subject_id: session.id,
        ip_address: client_ip(conn),
        user_agent: user_agent(conn)
      })

      redirect(conn, to: ~p"/capture/#{session.id}?token=#{bootstrap}")

    {:error, reason} ->
      conn
      |> put_status(:not_found)
      |> put_view(InterviewWeb.InviteHTML)
      |> render(:not_found, reason: reason)
  end
end
```

`reason` is one of `:not_found | :revoked | :expired` so the error
page can say "this link has been revoked" vs "this link has expired"
vs "this link is not valid". (We never tell the candidate the link is
*revoked* explicitly if it could have just been a typo — show the
generic "not valid" copy for `:not_found` only.)

## Files added / changed

New:

- `priv/repo/migrations/<ts>_add_invite_to_sessions.exs`
- `lib/interview/invites.ex` — context.
- `lib/interview_web/controllers/invite_controller.ex`
- `lib/interview_web/controllers/invite_html.ex` + `invite_html/not_found.html.heex`
- `lib/interview_web/live/recruiter_invites_live.ex`
- `test/interview/invites_test.exs`
- `test/interview_web/controllers/invite_controller_test.exs`
- `test/interview_web/live/recruiter_invites_live_test.exs`

Changed:

- `lib/interview/capture/session.ex` — add the new fields to the schema
  + changeset cast list.
- `lib/interview_web/live/recruiter_template_live.ex` — add the
  invites section + handlers.
- `lib/interview_web/router.ex` — two new routes.
- `lib/interview_web/components/layouts.ex` — add "Invites" nav link
  between Sessions and Templates.
- `docs/tutorial.md` — replace the API-only "mint a session" section
  with the in-app invite flow as the primary path; keep the API as the
  alternative.

## Tests

| Test | File | Asserts |
|---|---|---|
| `create_invite` rejects when template has no published version | `invites_test.exs` | `{:error, :no_current_version}` |
| `create_invite` writes a session with `pending` state and an `iv_` token | same | inserted row matches; URL helper returns full URL. |
| `consume_invite` returns the session for a valid token | same | `{:ok, %Session{}}` |
| `consume_invite` returns `:expired` past `invite_expires_at` | same | wall-clock advanced via fixture. |
| `consume_invite` returns `:revoked` after `revoke_invite` | same | revoke_at stamped. |
| `list_invites` is tenant-scoped | same | another tenant's invites don't appear. |
| `GET /invite/:token` redirects to `/capture/:sid?token=…` | controller | location header parsed; bootstrap token verifiable. |
| `GET /invite/<bad>` returns 404 with the friendly page | controller | renders "not valid". |
| Recruiter creates an invite from the template editor | template_live test | new session row visible; URL appears in DOM. |
| Recruiter revokes; the row renders struck-through and the URL stops working | invites_live test | row still in DOM; follow-up GET to `/invite/:token` is 404. |

## Manual demo path

1. `mix phx.server` and sign in as the dev recruiter.
2. Create a template (or open the seeded one) and publish a version.
3. Open the template — scroll to the new "Invites" section.
4. Type `you@example.com`, click "Generate link". Copy the URL.
5. Open the copied URL in an incognito window — lands on the capture
   page, records, submits.
6. Back in the recruiter window, the invite row should now read
   `submitted` (or `ready` once the finalizer runs); click through to
   the playback page.
7. Generate a second invite for `bob@example.com`, then click the ✕.
   Open that URL — should render "this link is no longer valid".

## Effort

~½ day for the migration, context, controller, and the template
editor's invite section. +2-3 h for the standalone `/recruiter/invites`
list with filters and the rate limiter on the invite endpoint. Most of
the time is in the LiveView polish (clipboard JS hook, confirm
dialogs); the data path is a thin wrapper over what `POST /api/sessions`
already does.

## Carries (not blocking v1)

- Real email delivery via Swoosh — Phase 4.
- CSV bulk invite.
- Per-template "open invite" mode (link is shareable, not bound to one
  email). Need to think about quotas + abuse before shipping.
- Reminder emails ("you haven't started yet").
- Recruiter-side notes on each invite ("referred by X, JD attached").
- Webhook events for the new lifecycle steps (`session.invited` when
  the link is generated, `session.opened` on first click). Useful for
  customers driving the flow via the API who want progress signals
  before submit; the in-app invite UI doesn't need them since the
  dashboard already shows the same info.
