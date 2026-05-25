# Scoring integration — implementation plan

> Goal: bring the five-stage lattice scoring pipeline into
> cathethos-video-interview, so the candidate flow ends in a
> `session.scored` webhook to the consumer (Talent App in
> production, Pulsifi-demo in dev) with all five P-stage outputs
> already computed. Pulsifi-demo's JS scoring runner is retired in
> the same workstream — it becomes a webhook consumer, not a
> pipeline executor.

## Scope (v1)

In scope:
- New Elixir scoring context (`Interview.Scoring`) wrapping the
  lattice runtime.
- New worker `Interview.Workers.ScorePipeline` that runs after the
  last per-response transcript lands.
- Two new webhook events: `session.scored` and
  `session.scoring_failed`. Contract specified in
  `docs/scoring-webhook-contract.md`.
- Per-template-version classification cache (one-shot P1 reuse),
  protected by a Postgres advisory lock so concurrent first
  candidates for the same template can't double-bill an LLM call.
- A small `session_scores` row recording every pipeline run so VI
  itself can answer "was this session scored, with which pipeline
  version, when?" — feeds observability + cost-guard on webhook
  retries.
- Pipeline bundle shipped in `priv/pipelines/` so the artifact is
  versioned with the code.

Explicitly out of scope (carry to a later phase):
- Recruiter-side UI to display classifications. The webhook
  carries them; surfacing them is a Talent App concern.
- Per-tenant pipeline overrides. v1 ships one pipeline for every
  tenant; rotate by editing `priv/pipelines/topology.json`.
- A `/api/sessions/:id/rescore` endpoint. Rescoring is a follow-up
  if/when the pipeline schema breaks compat.
- Pre-computing P1 at template-publish time. v1 is lazy: the first
  candidate's scoring run does P1 + caches it for everyone else.
- Migration of pre-existing scored applications. Old VI scoring
  rows (if any) are stale; consumers re-score on their own.

## Architecture

```
                                                           ┌──────────────┐
candidate browser                                          │ webhook URL  │
       │                                                   │ (Talent App, │
       │ records video                                     │  Pulsifi-demo)│
       ▼                                                   └──────────────┘
┌──────────────────────────────────────────────┐                  ▲
│ cathethos-video-interview                    │                  │
│                                              │                  │
│ ┌─────────────────────────────────────────┐  │                  │
│ │ Capture pipeline (existing)             │  │                  │
│ │  upload → finalize → transcribe         │  │                  │
│ └────────────────────┬────────────────────┘  │                  │
│                      │ all transcripts ready │                  │
│                      ▼                       │                  │
│ ┌─────────────────────────────────────────┐  │                  │
│ │ Workers.ScorePipeline (new)             │  │                  │
│ │  1. fetch ScoringExport.build/2         │  │                  │
│ │  2. classification cache hit? P1 if not │  │                  │
│ │  3. run P2..P5 via lattice runner       │  │                  │
│ │  4. enqueue session.scored webhook ─────┼──┼──────────────────┘
│ │  on error: enqueue session.scoring_failed
│ │                                         │  │
│ └─────────────────────────────────────────┘  │
│                                              │
│ ┌─────────────────────────────────────────┐  │
│ │ Interview.Scoring (new context)         │  │
│ │  - get/upsert TemplateClassification    │  │
│ │  - run_pipeline/2 — lattice runner      │  │
│ │  - reads priv/pipelines/                │  │
│ └─────────────────────────────────────────┘  │
└──────────────────────────────────────────────┘
```

## Phase machine — where scoring fits

The candidate session already passes through this lifecycle
(simplified):

```
in_progress
    │
    ├── responses arrive, transcoded, transcribed
    │
    ▼
ready                                  ←── (existing) Capture.rollup_session/1
    │                                       fires `session.ready` webhook
    │
    │   NEW: rollup_session/1 also enqueues Workers.ScorePipeline when
    │        Scoring.eligible_for_scoring?(session_id) returns true
    │        (state ready + every selected response has a transcript).
    ▼
ScorePipeline runs
    │
    ├── on success → `session.scored` webhook
    └── on failure → `session.scoring_failed` webhook
```

The `ready` state isn't gated on scoring — `session.ready` continues
to fire as soon as the finalizer rolls up. `session.scored` is an
additional event that arrives later (typically 10-60s after `ready`,
gated by Whisper + LLM latency).

This separation is deliberate. Consumers that only care about "is
the recording done?" (e.g., for retention triggers, manual review
queues) can keep listening to `session.ready`. Consumers that
need the scoring result listen to `session.scored`.

## File-by-file changes

### Database

**`priv/repo/migrations/<ts>_create_template_classifications.exs`**

```elixir
create table(:template_classifications, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :template_version_id, references(:interview_template_versions,
                                       type: :binary_id, on_delete: :delete_all),
      null: false
  add :pipeline_version, :string, null: false
  add :provider, :string                   # which LLM provided P1
  add :result, :map, null: false            # P1 output as stored JSON
  add :computed_at, :utc_datetime_usec, null: false
  timestamps(updated_at: false)
end

create unique_index(:template_classifications,
                   [:template_version_id, :pipeline_version])
```

- **Key shape:** `(template_version_id, pipeline_version)`. Bumping
  pipeline_version (a string in topology.json) invalidates the
  cache naturally — new pipeline → new row.
- **CASCADE on delete** so dropping a template_version cleans up
  its classifications. Matches the lifecycle of
  `question_response_focus_events`.

**`priv/repo/migrations/<ts+1>_create_session_scores.exs`**

```elixir
create table(:session_scores, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :session_id, references(:sessions, type: :binary_id,
                              on_delete: :delete_all), null: false
  add :pipeline_version, :string, null: false
  add :status, :string, null: false        # "ready" | "failed"
  add :error_reason, :string                # null on success; e.g. "rate_limited"
  add :computed_at, :utc_datetime_usec, null: false
  timestamps(updated_at: false)
end

create unique_index(:session_scores, [:session_id, :pipeline_version])
create index(:session_scores, [:status])
```

- **Compact by design.** No pipeline outputs stored — those go out
  via the webhook payload. The row is a metadata-only record that
  scoring _happened_, so VI can:
    1. Skip re-running the pipeline on webhook retries (cost guard).
    2. Answer "scored / failed / which pipeline" without touching
       the consumer.
    3. Power a future `/api/sessions/:id/rescore` admin endpoint.
- **Key shape `(session_id, pipeline_version)`** lets us re-score
  the same session against a newer pipeline (different row, same
  session) without conflict.

### Schemas

**`lib/interview/scoring/session_score.ex`** (new)

```elixir
defmodule Interview.Scoring.SessionScore do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(ready failed)

  schema "session_scores" do
    field :pipeline_version, :string
    field :status, :string
    field :error_reason, :string
    field :computed_at, :utc_datetime_usec

    belongs_to :session, Interview.Capture.Session

    timestamps(updated_at: false)
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [:session_id, :pipeline_version, :status,
                    :error_reason, :computed_at])
    |> validate_required([:session_id, :pipeline_version, :status,
                          :computed_at])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:session_id, :pipeline_version])
  end

  def statuses, do: @statuses
end
```

**`lib/interview/scoring/template_classification.ex`** (new)

```elixir
defmodule Interview.Scoring.TemplateClassification do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "template_classifications" do
    field :pipeline_version, :string
    field :provider, :string
    field :result, :map
    field :computed_at, :utc_datetime_usec

    belongs_to :template_version, Interview.Templates.Version

    timestamps(updated_at: false)
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [:template_version_id, :pipeline_version,
                    :provider, :result, :computed_at])
    |> validate_required([:template_version_id, :pipeline_version,
                          :result, :computed_at])
    |> unique_constraint([:template_version_id, :pipeline_version])
  end
end
```

### Context module

**`lib/interview/scoring.ex`** (new) — the public API for the
scoring subsystem.

Functions:

| Function | Returns | Used by |
|----------|---------|---------|
| `get_classification(template_version_id, pipeline_version)` | `TemplateClassification` \| `nil` | the worker, before running P1 |
| `upsert_classification(attrs)` | `{:ok, TemplateClassification}` \| `{:error, changeset}` | the worker, after P1 lands |
| `with_classification_lock(template_version_id, fun)` | `fun.()` return value | wraps a `Repo.transaction` and takes `pg_advisory_xact_lock(hashtext(template_version_id))` before running `fun`. Used when computing P1 on cache miss so concurrent workers don't double-spend the LLM. |
| `classify(template_version_id, questions)` | `{:ok, %{result, provider}}` \| `{:error, term()}` | runs the P1 stage alone against a list of questions. Used by the worker on cache miss (inside `with_classification_lock`). Pure compute — no DB writes. |
| `score_session(session_id)` | `{:ok, payload}` \| `{:error, term()}` | the worker. Orchestrates: fetch export → check cache → `classify` if needed (under advisory lock) → run P2..P5 → return the full scoring payload. Does NOT enqueue the webhook + does NOT write `session_scores` (the worker does both, so it can branch on success vs failure). |
| `record_score(session_id, status, opts)` | `{:ok, SessionScore}` | the worker. Writes the `session_scores` row after either success or failure. Idempotent on `(session_id, pipeline_version)`. |
| `already_scored?(session_id, pipeline_version)` | `boolean()` | the worker, FIRST check before doing anything. If `true` → no-op (Oban retry on a worker that already finished). The webhook delivery is on its own separate Oban job and has its own retry semantics — the scoring worker does NOT re-fire webhooks. |
| `eligible_for_scoring?(session_id)` | `boolean()` | called from `Capture.rollup_session/1` to decide whether to enqueue the worker. Returns `true` iff session state is `ready` AND every selected response has `transcript_ready_at != nil`. |
| `pipeline_version()` | `String.t()` | derived from `topology.json` via `@external_resource` at compile time. Stable for the request; bumping requires a recompile (intentional — pipeline version is artifact-versioned). |

### Lattice runner

**`lib/interview/scoring/runner.ex`** (new)

Mirrors Pulsifi-demo's `runner.ts` line-for-line but in Elixir.
The exposed function:

```elixir
@spec run_pipeline(Topology.t(), input_row :: map()) ::
        {:ok, %{stage_outputs: %{String.t() => list()}, pipeline_version: String.t()}}
        | {:error, {atom(), term()}}
def run_pipeline(topology, input_row)
```

Internals:
- One `Lattice.Runtime` instance **per stage** (matches the JS
  parity bug from the runner.ts comment: stage1's `GenerateOutput/2`
  and stage2's `GenerateOutput/1` collide in the same runtime
  because lattice's function registry is keyed by name only, not
  arity).
- `Lattice.eval/2` to load each stage's `.lat` file.
- `Lattice.set_global/3` to bind dependencies per stage. Supports
  the `"from:as"` aliasing already in topology.json (e.g.
  `"p4_results:input_data"` — P5 sees P4's output bound to the
  global name `input_data`).
- `Lattice.call/3` with the stage's `entrypoint` (always
  `"RunBatch"` today, but loaded from topology so it's not
  hardcoded).
- Serializes complex stage outputs (nested List<Struct>) to JSON
  strings before binding them as the next stage's input — same
  `serializeRowsForNextStage` quirk that runner.ts has, documented
  there as the lattice/DuckDB nested-Arrow issue.

### Topology loader

**`lib/interview/scoring/topology.ex`** (new)

Reads `priv/pipelines/topology.json` once at application boot
(`Application.app_dir(:interview, "priv/pipelines/topology.json")`)
and parses into a `%Topology{}` struct. Resolves the `:bind` syntax.

Mirrors Pulsifi-demo's `topology.ts` — same JSON file, same parse
shape, just Elixir structs instead of TS types.

### Pipeline bundle

**`priv/pipelines/`**

```
priv/pipelines/
  ├── topology.json
  └── smoke_test_Pipeline_2_2026-05-25-<HHMM>/
      └── stages/
          ├── 01_VI_P1_Classify_v1/lattice.lat
          ├── 02_VI_P5_Aggregate_v2/lattice.lat
          ├── 03_VI_P2_Extract_Evidence_v1/lattice.lat
          ├── 04_VI_P4_Layer_2_Scoring_v2_per-question/lattice.lat
          └── 05_VI_P3_Layer_1_Scoring_v2_per-question/lattice.lat
```

- Bundle copied from the user's `~/Downloads/smoke_test_Pipeline_2_2026-05-25-0423.zip`
- `topology.json` keyed by stage id (`p1`..`p5`), referencing the
  `lattice.lat` paths under `stages/`.
- `pipeline_version` field on topology.json is the string we
  cache against and emit in the webhook.

### Worker

**`lib/interview/workers/score_pipeline.ex`** (new)

```elixir
use Oban.Worker,
  queue: :scoring,
  max_attempts: 6,
  # Within a 60-second window, the same session_id can only be
  # enqueued once. mark_ready/2 may fire eligibility checks from
  # multiple parallel transcript landings; this catches the
  # accidental duplicates before they reach the worker.
  unique: [period: 60, fields: [:args], keys: [:session_id]]
```

Args: `%{"session_id" => session_id}`.

Sequence:

1. Look up the session. `:discard` if not found.
2. `Scoring.already_scored?(session_id, pipeline_version)` — if
   `true`, no-op (`:ok`). This is the cost guard: Oban retry on a
   worker that already finished does NOT re-run the pipeline.
3. Build the scoring export via
   `Interview.ExternalIntegration.ScoringExport.build/2`. If it
   returns `:not_ready` (session state not `ready` yet OR
   transcripts still pending), return `{:snooze, 30}` — Oban will
   retry in 30s. This handles the case where the worker was
   enqueued from `rollup_session` but a slow Whisper job for a
   late response is still landing.
4. Resolve P1 classification:
   a. `Scoring.get_classification(template_version_id, pipeline_version)`.
   b. If `nil`, wrap step 4c in `Scoring.with_classification_lock/2`
      (advisory lock) and re-check inside the lock — another
      worker may have just populated it.
   c. `Scoring.classify(template_version_id, questions)` — runs
      P1 alone. `Scoring.upsert_classification/1` writes the cache
      row. Advisory lock releases on transaction commit.
5. Run P2..P5 via `Scoring.run_pipeline/2`, with the cached P1
   output bound as `p1_results`.
6. Build the webhook payload (see scoring-webhook-contract.md).
7. Single `Repo.transaction` wrapping:
   a. `Scoring.record_score(session_id, :ready, ...)` — writes
      `session_scores` metadata row.
   b. `Interview.Webhooks.enqueue(session, "session.scored",
      payload_data)` — upserts the `webhook_deliveries` row and
      inserts the delivery Oban job. Atomic with (a) so the
      "scored" record and the outbound delivery are never out of
      sync.

Error policy (mirrors `WhisperTranscript`):

| Error | Action |
|-------|--------|
| `{:missing_api_key, _}` | `:discard` + operator log |
| `{:unauthorized, _}` | `:discard` + operator log |
| `{:rate_limited, _}` | `{:error, :rate_limited}` (retry) |
| `{:server_error, _, _}` | retry |
| `{:transport, _}` | retry |
| stage-specific error (e.g. decode failure on P3) | retry until `attempt == max_attempts`. On the final attempt: `Scoring.record_score(session_id, :failed, error_reason: …)` + enqueue `session.scoring_failed` webhook, return `:ok` (not `{:error, _}`). Returning `:ok` marks the Oban job as `completed` rather than `discarded`/`retryable` — important because the actual outcome (failure) is recorded in `session_scores` + delivered via the webhook; Oban's retry semantics should not double-fire the failure event. |

The webhook on terminal failure is important — without it, Talent
App would never know scoring isn't coming for this session.

### Webhook event registration

**`lib/interview/webhooks.ex`** — two-line edit + two new
`derive_data/3` clauses.

Add to the allowed-events list:
```elixir
event_type in [
  "session.submitted",
  "session.ready",
  "session.failed",
  "session.deleted",
  "session.scored",            # new
  "session.scoring_failed"     # new
]
```

Add the `derive_data/3` clauses:
- `"session.scored"` — passes through `extra` (which carries the
  full scoring payload from the worker)
- `"session.scoring_failed"` — passes through `extra` (carries
  stage + reason + message + attempts)

### Trigger from the capture pipeline

**`lib/interview/capture.ex`** — extend `rollup_session/1` (NOT
`mark_ready/2`).

Why `rollup_session/1`: it's the function that flips
`sessions.state = "ready"` and fires the existing `session.ready`
webhook. By that point ALL selected responses' finalizers have
run. Hooking scoring there gives us a single, well-defined moment
to enqueue.

We can't safely enqueue from `mark_ready/2` because:
- `mark_ready` is per-response; it fires for every individual
  response transcript landing.
- At that moment, `sessions.state` may still be `in_progress`
  (rollup hasn't run yet).
- `ScoringExport.build/2` requires `state == "ready"`, so the
  worker would `:snooze` repeatedly until rollup ran — wasteful.

The enqueue call (added at the tail of `rollup_session/1`, after
the existing `session.ready` webhook is enqueued):

```elixir
if Interview.Scoring.eligible_for_scoring?(session.id) do
  %{session_id: session.id}
  |> Interview.Workers.ScorePipeline.new()
  |> Oban.insert()
end
```

The `unique: [period: 60, keys: [:session_id]]` on the worker
itself catches accidental duplicate enqueues (e.g., if
`rollup_session/1` ever fires twice for the same session because
of a retry race).

### Pipeline-version constant

**`lib/interview/scoring.ex` derives this** from
`priv/pipelines/topology.json`. Read once at module load
(`@external_resource` for hot-reload friendliness in dev), exposed
as `pipeline_version/0`. Used by the worker to key the
classification cache + by the webhook payload.

## Tests

### Elixir

**`test/interview/scoring_test.exs`** (new)
- `get_classification` returns nil when absent.
- `upsert_classification` inserts; second call no-ops on conflict.
- `with_classification_lock` serializes concurrent callers
  (assert lock + double-check pattern works under contention).
- `score_session` happy path (with stubbed lattice — see below).
- `score_session` returns `:not_ready` when transcripts pending.
- `score_session` uses cached classification when present (assert
  P1 NOT re-run).
- `already_scored?` returns true after `record_score`.
- `record_score` is idempotent on `(session_id, pipeline_version)`.

**`test/interview/workers/score_pipeline_test.exs`** (new)
- Enqueues `session.scored` webhook on success + writes
  `session_scores` row with status `ready`.
- On terminal failure: writes `session_scores` row with status
  `failed` + enqueues `session.scoring_failed` webhook + returns
  `:ok` (not `{:error, _}`).
- Idempotent: re-running a job that already has a `session_scores`
  row no-ops (the `already_scored?` short-circuit).
- `:snooze` when scoring_export returns `:not_ready`.
- `:discard` when session not found.
- Advisory lock under contention: two workers racing the same
  cache miss → only one P1 call hits the stub adapter, both
  workers complete successfully.

**`test/interview/webhooks_test.exs`** (extend)
- `enqueue/3` accepts the two new event types.
- `derive_data/3` for `session.scored` passes `extra` through.

**`test/interview/capture_test.exs`** (extend)
- `rollup_session` enqueues `Workers.ScorePipeline` when the
  session becomes fully transcribed (state ready + all selected
  responses' `transcript_ready_at` populated).
- `rollup_session` does NOT enqueue if any transcript is still
  pending (transient case — `rollup_session` doesn't normally
  fire in this state, but the helper should be defensive).
- Idempotent enqueue: two calls to `rollup_session` in quick
  succession produce one Oban job (`unique` constraint catches
  the dupe).

### Lattice stub for tests

The lattice runtime makes real LLM calls. Tests cannot.

Pattern (mirrors `TranscriptsStub`):
- Add a behaviour `Interview.Scoring.PipelineRunner` with
  `run_pipeline/2`.
- Real adapter: `Interview.Scoring.LatticeRunner` — calls
  `Lattice.eval/call`.
- Test adapter: `Interview.Scoring.StubRunner` — process-local
  scripted responses keyed by stage id, plus a default that
  returns a small known-good payload for parity smoke tests.
- Wire selection via `Application.get_env(:interview, Interview.Scoring,
  [])[:runner]` (default: LatticeRunner; tests config flips to
  StubRunner).

This keeps test runs free of OpenAI/Gemini cost + deterministic
across CI runs.

## Pulsifi-demo migration (after VI side is stable)

Out of this repo's commit boundary, but planned:

1. Pulsifi-demo adds a webhook listener for `session.scored`.
2. The listener stores the payload in the existing
   `interview_scores` table (same shape — pipeline_outputs +
   classifications + transcript).
3. Once the listener is confirmed working in parallel with the
   existing JS lattice path (both run, results compared), the JS
   path is removed: `apps/backend/src/modules/scoring/{runner,topology,service}.ts`
   deleted, `lattice-lang` dep removed, `apps/backend/pipelines/`
   deleted.

The webhook payload deliberately matches the on-disk shape
Pulsifi-demo already stores, so the cutover is a thin adapter
not a rewrite.

## Open questions / deferred decisions

1. **Should the worker run P1 inline OR enqueue a separate
   `Workers.ClassifyTemplate` job?** v1: inline. P1 is one LLM
   call — splitting it into another job adds complexity for ~5s
   savings on first-candidate latency. Revisit if P1 grows to
   multiple sub-calls or becomes slow.

2. **What happens if the recruiter publishes a new template
   version mid-flight (candidates have submitted but not been
   scored yet)?** Sessions reference a frozen `template_version_id`,
   so they continue scoring against the version they were created
   against. The classification cache key is
   `(template_version_id, pipeline_version)` so the old
   classification stays valid. Confirmed safe.

3. **Should `session.scoring_failed` retry mechanism include a
   recruiter-facing "retry scoring" action?** v1: no. Failed
   scoring rows are logged via `session_scores.status = "failed"`;
   we add a manual `Workers.ScorePipeline` re-enqueue admin path
   in a follow-up. The webhook with the failure reason gives the
   consumer enough to show "scoring temporarily unavailable"
   without our help.

4. **Multi-tenancy isolation on the classification cache:** the
   cache row is implicitly scoped via `template_version_id`,
   which is tenant-scoped via `template`. No additional
   `tenant_id` column needed. Confirm during implementation.

5. **Pre-computing P1 at template-publish time** (vs lazy on
   first candidate). v1 is lazy. Pre-computing would mean adding
   a `Workers.PrecomputeClassification` enqueue inside
   `Templates.publish_draft` — straightforward but pre-empts
   work the recruiter may not need (e.g., template never used).
   Revisit once we have data on how often candidates submit
   immediately after publish.

## Rollout

**Branch: continue on `feature/external-integration-v1`.**

The scoring work depends on changes already on this branch
(scoring_export carries `response_id`, `duration_ms`,
`focus_lost_count`, `focus_lost_total_ms` — all introduced by
earlier candidate-UX commits). Branching from `main` would lose
those, and the webhook payload would be missing fields. Branching
from `external-integration-v1` itself works too but adds a
rebase step later; continuing on the same branch is simpler when
the same developer owns both workstreams.

Commit boundaries:

1. **chore: copy v2 pipeline bundle into priv/pipelines/** — pure
   file move, no behavior change.
2. **add migration + schemas** —
   `template_classifications` + `session_scores` tables and the
   two new Ecto schemas. No business logic yet.
3. **add Interview.Scoring context + lattice runner + topology
   loader** — code only, not wired into anything. Tests with
   stub adapter.
4. **add Workers.ScorePipeline** — worker code + tests covering
   already-scored short-circuit, snooze on transcripts pending,
   advisory-lock cache miss, failure path. Not wired into the
   capture pipeline yet.
5. **register session.scored + session.scoring_failed in
   Webhooks** — webhook events + tests.
6. **trigger scoring from Capture.mark_ready** — the wire-up.
   Existing tests should still pass; new tests assert the
   enqueue.
7. **end-to-end smoke (dev manual)** — score a real session,
   verify the webhook payload matches the contract.
8. **Pulsifi-demo consumer + JS lattice retirement** (separate
   repo, after #7 lands).

Each VI commit must pass `mix test`, `mix format`, and `mix
precommit` clean. No `--no-verify`. No skipping hooks.
