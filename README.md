# Interview

An embeddable, network-resilient async video interview platform. Recruiters
author question templates and ship a link to a candidate; the candidate
records video answers in their browser; the recordings stream up tus-style
through Phoenix to object storage. The whole UI is a Phoenix LiveView app;
the embed SDK is a ~5 KB JS file that drops the recorder into a third-party
iframe.

Architecture, decisions, and trade-offs live in [`/Users/catethos/workspace/video/PLAN.md`](../PLAN.md). This
README is the "0 to 1" onboarding for a new developer.

---

## 1. What's in the box

| Layer | Tech |
|---|---|
| Web framework | Phoenix `~> 1.8.7`, LiveView `~> 1.1` |
| Language / runtime | Elixir `~> 1.15` on Erlang/OTP 28 |
| Database | Postgres (Ecto + Postgrex) |
| Background jobs | Oban `~> 2.18` |
| Object storage | Local filesystem in dev (`priv/uploads`); S3-compatible (Tigris) in prod via an adapter |
| Asset bundling | esbuild + Tailwind v4 (no `tailwind.config.js`); daisyUI plugin |
| Transcoding | `ffmpeg` (`libx264`) — required on PATH for the finalizer worker |
| Transcripts | OpenAI Whisper API (optional; off by default) |
| HTTP server | Bandit |

Two top-level namespaces:
- `Interview.*` — domain contexts (`Capture`, `Templates`, `PromptAssets`,
  `Auth`, `Tenants`, `Storage`, `Webhooks`, `Workers`, …).
- `InterviewWeb.*` — Phoenix endpoint, router, controllers, LiveViews,
  plugs, the tus upload Plug, the third-party iframe harness router.

---

## 2. Prerequisites

You need:

- **Erlang/OTP 28** and **Elixir 1.19** (or any `~> 1.15` compatible). Use
  [`asdf`](https://asdf-vm.com/) or [`mise`](https://mise.jdx.dev/) — the
  repo doesn't pin a tool-version file, but those are what the project was
  developed against.
- **Postgres 14+** running locally. The default config connects via
  `localhost` as your unix user with an empty password — see §4.
- **ffmpeg** on `PATH`. The finalizer Oban worker shells out to it for
  WebM → MP4 transcodes. On macOS: `brew install ffmpeg`.
- **Node is _not_ required** at runtime — esbuild and Tailwind ship as
  Elixir packages that download static binaries to `_build/` on first
  use.

Optional:

- **`OPENAI_API_KEY`** in your shell — turns on Whisper transcript
  generation for recorded answers. Without it, transcript jobs permafail
  with a harmless warning; everything else works.

---

## 3. First-time setup

From a fresh clone:

```bash
mix setup
```

That alias does, in order:

1. `mix deps.get` — fetch hex deps.
2. `mix ecto.create` — create the `interview_dev` Postgres database.
3. `mix ecto.migrate` — run all migrations under `priv/repo/migrations/`.
4. `mix run priv/repo/seeds.exs` — seed a dev tenant, template, recruiter,
   and API key (see §5).
5. `mix tailwind.install` + `mix esbuild.install` — download the bundler
   binaries.
6. `mix tailwind interview` + `mix esbuild interview` + `mix esbuild embed`
   — build the initial CSS / JS bundles.

Then:

```bash
mix phx.server
```

Open <http://localhost:4000>. You're done.

---

## 4. Database

Postgres is required. The dev `Repo` is configured from environment
variables (`config/dev.exs`):

| Env var | Default |
|---|---|
| `PGUSER` | your `$USER` |
| `PGPASSWORD` | empty |
| `PGHOST` | `localhost` |
| `PGDATABASE` | `interview_dev` |

If your local Postgres has a different setup (e.g. a `postgres` superuser
with password `postgres`), export the env vars before running `mix
ecto.*`:

```bash
export PGUSER=postgres
export PGPASSWORD=postgres
mix ecto.create
```

The test config (`config/test.exs`) is hard-coded to `postgres`/`postgres`
on `localhost` against `interview_test`.

### Migrations

- All migrations live in `priv/repo/migrations/` (17 of them at the time
  of writing). They're additive — versioning rules (PLAN §3.4) mean we
  never `Repo.update` published rows; we evolve via new migrations.
- Apply: `mix ecto.migrate`.
- Roll back the last one: `mix ecto.rollback`.
- Nuke and rebuild from scratch: `mix ecto.reset` (drops + recreates +
  re-seeds).

### Seeds

`priv/repo/seeds.exs` is **idempotent** — safe to re-run. It creates:

- A `Dev Tenant` (slug `dev`) with `frame_ancestors` allowlisting the
  local harness origins.
- `Dev Template` with one published version + one question.
- A recruiter `dev@example.com` (role `owner`).
- A tenant API key whose **secret prints once to stdout** on first run.
  Save it if you want to call the JSON API; it's only recoverable by
  re-running seeds against a fresh DB.

---

## 5. Running the app

```bash
mix phx.server               # foreground
iex -S mix phx.server        # with an IEx shell attached
```

Three things start:

| URL | What it is |
|---|---|
| `http://localhost:4000` | The Phoenix app — recruiter dashboard, candidate `/capture/<id>` page, JSON API. |
| `http://localhost:5174` | The third-party iframe **harness** (`InterviewWeb.HarnessRouter`). A fake customer site on a different origin, used to exercise cross-site iframe behaviour (IndexedDB partitioning, postMessage origin checks). |
| `http://localhost:4000/dev/dashboard` | Phoenix LiveDashboard (dev-only). |

### Signing in (recruiter)

There are no passwords. Sign-in is magic-link via email; in dev there is
no email — the link is printed to the server log.

```bash
curl -X POST http://localhost:4000/api/auth/magic-links \
     -H "Content-Type: application/json" \
     -d '{"email":"dev@example.com"}'
```

The server log emits:

```
magic_link_url=http://localhost:4000/auth/magic-link/<token> email=dev@example.com
```

Open that URL — single-use, ≤15 min TTL. You land in the recruiter app.

### Being a candidate (dev shortcut)

```
http://localhost:4000/capture/new
```

Mints a fresh session against the seeded dev tenant + template, generates
a bootstrap token, and redirects to `/capture/<id>?token=<token>`. No
recruiter sign-in needed.

For the real flow (`POST /api/sessions` from a customer backend), see
[`docs/tutorial.md`](docs/tutorial.md) and [`docs/integration.md`](docs/integration.md).

---

## 6. Project layout

```
lib/
├── interview/                  # Domain contexts (no web concerns)
│   ├── application.ex          # OTP supervision tree, Oban + Repo + Endpoint
│   ├── audit/                  # Append-only audit log
│   ├── auth/                   # Recruiter sessions, magic links, API keys, bootstrap tokens
│   ├── capture/                # Sessions, responses (the candidate side)
│   ├── playback/               # Recruiter-side listing and playback queries
│   ├── prompt_assets.ex        # Recruiter-recorded video prompts + attachments
│   ├── storage/                # Adapter behaviour + Local FS adapter
│   ├── templates/              # Templates, versions, questions, draft/publish state machine
│   ├── tenants/                # Tenant (frame_ancestors, retention, webhook config)
│   ├── transcripts.ex          # Whisper integration (off without OPENAI_API_KEY)
│   ├── webhooks.ex             # Signed outbound webhooks + URL policy
│   └── workers/                # Oban jobs (finalizer, sweeper, retention, transcripts, webhook deliveries)
└── interview_web/
    ├── endpoint.ex             # Bandit, Plug pipeline, asset routes
    ├── router.ex               # All routes (browser, LV, JSON API, embed)
    ├── harness_router.ex       # The :5174 fake-customer site
    ├── plugs/                  # RecruiterAuth, RequireRecruiter, RateLimit, …
    ├── controllers/            # Auth, capture session, attachment upload, playback, JSON API
    ├── live/                   # CaptureLive, RecruiterTemplate{s}Live, RecruiterSession{s}Live, …
    ├── tus/                    # Custom tus PATCH handlers for response + prompt-asset uploads
    └── components/             # Layouts, core_components (zen-styled buttons, eyebrows, etc.)

assets/
├── css/app.css                 # Tailwind v4 imports + the "Quiet Studio" theme (zen-*, shutters, recorder pulse)
├── js/
│   ├── app.js                  # LiveSocket setup + hook registry
│   ├── hooks/                  # Recorder, RecruiterRecorder, AttachmentForm
│   └── recorder/core.js        # RecorderCore — MediaRecorder + IndexedDB + tus uploader (shared by both recorder hooks)
└── embed/                      # The customer-side embed SDK (esbuild target `embed`)

priv/
├── repo/
│   ├── migrations/             # 17 numbered migrations
│   └── seeds.exs               # Idempotent dev fixtures
├── harness/index.html          # The fake-customer page served by the harness router
└── uploads/                    # Where Storage.Local writes recorded bytes (gitignored)

docs/                           # Phase-by-phase findings, integration guide, tutorial
PLAN.md                         # The product/architecture plan (one level up)
AGENTS.md                       # Conventions and guardrails for code-changing agents
```

---

## 7. Object storage

In dev, `Interview.Storage.Local` writes to `priv/uploads/`:

```
priv/uploads/
├── responses/<response_id>/<capture_instance_id>/blob.webm        # In-flight tus body
├── tenants/<tenant_id>/sessions/<session_id>/q<n>_a<m>.{webm,mp4}  # Finalized artifact
├── prompt_assets/<asset_id>/...                                    # Recruiter-recorded prompt
└── ...
```

Configured in `config/config.exs`:

```elixir
config :interview, Interview.Storage,
  adapter: Interview.Storage.Local,
  root: "priv/uploads"
```

For production the same `Interview.Storage` behaviour is implemented by an
S3 adapter (Tigris on Fly per PLAN decision #3); swap by changing
`:adapter` in `config/runtime.exs`. The contract is documented at the top
of `lib/interview/storage.ex`.

---

## 8. Running tests

```bash
mix test                       # full suite
mix test test/path/to/file_test.exs
mix test --failed              # just last-run failures
```

The test config creates and migrates `interview_test` automatically; you
don't need to do anything beyond `mix test`. Tests run async where possible
and use `Ecto.Adapters.SQL.Sandbox` for isolation.

The full suite is ~380 tests and finishes in ~2 seconds.

There is also a `precommit` alias that runs warnings-as-errors compile,
unused-deps check, format, and the test suite together:

```bash
mix precommit
```

Run this before any meaningful change set.

---

## 9. Architecture in one screen

```
[Candidate browser]                                        [Phoenix app]                [Postgres]
                                                                                        [Tigris/Local FS]
LiveView mount /capture/<id>?token=…  ─────────────────►  bootstrap consume,
                                                          mint upload bearer
                                          ◄────────────── recorder UI
JS hook (assets/js/hooks/recorder.js)
  ↓
RecorderCore (assets/js/recorder/core.js)
  ↓ MediaRecorder timeslice 2s
  ↓ IndexedDB queue (durable before upload)
  ↓ tus PATCH /uploads/tus/<sid>/<rid>  ─────────────────► Plug writes bytes,
     (Upload-Offset, Tus-Resumable)                         updates question_responses.bytes_uploaded
                                          ◄──────────────  204 + new Upload-Offset
  ↓ explicit POST .../capture_complete  ─────────────────► row → capture_complete,
                                                            enqueue Oban finalizer
                                                                                          ↓
                                                          finalizer worker:               concat → ffmpeg transcode → MP4
                                                          ─ thumbnail
                                                          ─ Whisper transcript (if key)
                                                          ─ session rollup, fire webhook
```

Key invariants (full detail in PLAN §5):

- **Chunks are durable in IndexedDB before any upload attempt.**
- **Chunks are deleted from IndexedDB only after the server ACKs durability
  AND the `bytes_uploaded` row is committed.**
- **Finalization is triggered by an explicit `capture_complete` POST,
  never by "looks idle" inference.**
- **Sessions reference an immutable `template_version_id` frozen at
  session creation** — editing a published template never changes a
  candidate's experience mid-flight.

---

## 10. Common dev tasks

| Task | Command |
|---|---|
| Run the server | `mix phx.server` |
| Reset DB to a clean slate | `mix ecto.reset` |
| Apply new migrations | `mix ecto.migrate` |
| Roll back one migration | `mix ecto.rollback` |
| Run all tests | `mix test` |
| Run one test file | `mix test test/foo_test.exs` |
| Run just failed tests | `mix test --failed` |
| Format code | `mix format` |
| Pre-commit gate | `mix precommit` |
| Rebuild assets one-shot | `mix assets.build` |
| Mint a fresh recruiter magic link | `curl -X POST -H 'content-type: application/json' -d '{"email":"dev@example.com"}' http://localhost:4000/api/auth/magic-links`, then grep server log for `magic_link_url=` |
| Start a candidate session quickly | open `http://localhost:4000/capture/new` |
| Inspect Oban jobs | open `http://localhost:4000/dev/dashboard` → Oban tab |

---

## 11. Where to read next

- [`PLAN.md`](../PLAN.md) — the master architecture document: every
  decision, why it was made, and what the trigger is to reopen it.
- [`AGENTS.md`](AGENTS.md) — guardrails and conventions for anyone (human
  or otherwise) editing this codebase.
- [`docs/tutorial.md`](docs/tutorial.md) — drive every screen once,
  recruiter side and candidate side.
- [`docs/integration.md`](docs/integration.md) — how a customer drops the
  embed SDK into their site.
- [`docs/phase{0..4}-findings.md`](docs/) — what we learned in each build
  phase. Useful when you're touching a subsystem and want to know "why is
  it like this".
- [`docs/safari-soak-checklist.md`](docs/safari-soak-checklist.md) —
  manual regression checklist for the candidate recorder path.

---

## 12. Things that surprise newcomers

- **Phoenix code reload only watches `lib/interview_web/`.** Changes to
  `lib/interview/...` modules (Templates, Capture, etc.) are picked up by
  the reloader on the next request but not always reliably; if a change
  doesn't seem to take effect, restart `mix phx.server`.
- **Tailwind v4 has no `tailwind.config.js`.** Sources are declared in
  `assets/css/app.css` via `@source` lines.
- **Streams in LiveView don't diff their items.** If you bind UI state
  to assigns that should re-render rows, use a plain assign list (not
  `stream/3`) or call `stream_insert` per row.
- **`phx-update="ignore"` skips the whole element from morphdom**,
  attributes included. To toggle CSS on something inside an ignored
  region, drive it from a `data-*` attribute on a LV-owned parent.
- **The recorder always uses Chrome/Edge desktop only in v1**
  (PLAN decision #14). The SDK shows a "complete this on desktop Chrome"
  block on Firefox, Safari, and any mobile browser.
- **`SessionDeletion` soft-deletes the `sessions` row** (sets `deleted_at`)
  but keeps it around for audit. Hard-deletion happens only when the
  parent template version is deleted — see `Templates.delete_version/3`.
