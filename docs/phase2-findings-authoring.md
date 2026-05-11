# Phase 2 — recruiter authoring + importers + REST API, findings

> Status as of 2026-05-07.
> Authoring code lives in `lib/interview/templates/`, the LiveView at
> `lib/interview_web/live/recruiter_template_live.ex`, the JSON API at
> `lib/interview_web/controllers/template_controller.ex`, and the dev
> auth plug at `lib/interview_web/plugs/dev_token_auth.ex`.
> Tests: `mix precommit` green, 107 tests (was 58 at the candidate-flow
> session exit).
>
> Phase 2 still has unchecked rows in PLAN §7 — recruiter-recorded
> video prompts, image/PDF prompt assets, real tenant/JWT bootstrap,
> upload-bearer tokens, and the Whisper transcript Oban job. See
> "Carries into next session".

## What was built

| Capability | Where | Status |
|---|---|---|
| `Interview.Templates` context: `create_template`, `list_templates`, `get_template_with_current_version`, `create_draft_version` (clones from `current_version`), `update_draft_version`, `update_draft_question(s)`, `reorder_draft_questions` (two-stage to dodge `UNIQUE(template_version_id, position)`), `publish_draft` (atomic flip in a `Multi`), `apply_spec_to_draft`, `version_to_spec` | `lib/interview/templates.ex` | ✅ |
| Versioning rule enforced at the context layer: `update_draft_*` and `apply_spec_to_draft` reject `%Version{published_at: not_nil}` with `{:error, :published_immutable}` (PLAN §3.4 — published is immutable, edits create a draft) | `lib/interview/templates.ex` | ✅ |
| `Interview.Templates.Spec` — canonical intermediate. `from_map/1` is pure shape coercion (accepts the YAML/MD shorthand `prompt:` and the DB `prompt_text:`); `validate/1` returns `[%{path, message}]` with structured paths; `path_to_json_pointer/1` per RFC 6901. One validator, three front doors. | `lib/interview/templates/spec.ex` | ✅ |
| YAML importer/exporter: `YamlImporter.parse/1` (via `:yaml_elixir`) and `dump/1` (hand-rolled emitter, ~80 lines, block-scalar `|` for multi-line markdown). Round-trips parse → dump → parse. Validation errors get a heuristic `line:` via post-parse source scan. | `lib/interview/templates/yaml_importer.ex` | ✅ |
| Markdown-with-frontmatter importer: split on standalone `---`, first frontmatter is template metadata (string shorthand or full `{name, description}` map both accepted), subsequent (frontmatter, body) pairs are questions. Same Spec, same validator. Errors get the question's frontmatter line. | `lib/interview/templates/markdown_importer.ex` | ✅ |
| Recruiter authoring LiveView at `/recruiter/templates/:id` on the `:browser` pipeline (NOT `:embed`): lists versions, autosaves on `phx-blur` per field, up/down reorder, add/delete question, publish. | `lib/interview_web/live/recruiter_template_live.ex`, `lib/interview_web/router.ex` | ✅ |
| JSON REST API: `POST/GET /api/templates`, `GET /api/templates/:id`, `POST /api/templates/:id/versions`, `PUT /api/templates/:id/versions/:vid/questions`, `POST /api/templates/:id/versions/:vid/publish`, `POST /api/templates/:id/import` (content-type negotiated YAML or markdown). Validation errors carry RFC 6901 JSON pointers; import errors also carry `line`. | `lib/interview_web/controllers/template_controller.ex` | ✅ |
| `InterviewWeb.Plugs.DevTokenAuth` — header-based tenant auth stub. `Authorization: Bearer dev-<slug>` resolves to a tenant; in test/dev `x-tenant-id: <uuid>` is also accepted (gated on `Application.compile_env(:interview, :dev_routes)`). Real JWT/tenant auth replaces the entire plug in a later session. | `lib/interview_web/plugs/dev_token_auth.ex` | ✅ |
| `:yaml_elixir ~> 2.11` added to deps. Pure-Erlang via `:yamerl`; no NIF compile. Dumping is hand-rolled — no second YAML dep. | `mix.exs`, `mix.lock` | ✅ |
| `config/test.exs` sets `dev_routes: true` so the recruiter API's `x-tenant-id` test bypass works under ExUnit. | `config/test.exs` | ✅ |
| Tests: 49 new across `spec_test.exs`, `yaml_importer_test.exs`, `markdown_importer_test.exs`, `templates_test.exs`, `recruiter_template_live_test.exs`, `template_controller_test.exs`. Round-trip, validation-error class coverage (one negative test per importer per error class), publish_draft semantics, reorder, autosave, candidate flow against templates created via the new path. | `test/interview/templates*`, `test/interview_web/live/recruiter_template_live_test.exs`, `test/interview_web/controllers/template_controller_test.exs` | ✅ |

## Partial / known gaps

- **Drag-handle reorder is up/down arrow buttons.** PLAN §3.4 calls for
  drag-handle. Up/down buttons keep the LiveView pure (no JS dep,
  testable end-to-end without browser automation) and the underlying
  `reorder_draft_questions/2` is identical to what a drag handler would
  call. Replacing with a Sortable-style hook is ~40 lines of JS + a
  `phx_event "reorder", ids` callback — pure polish, no model change.
- **YAML validation `line:` is heuristic, not authoritative.** `yaml_elixir`
  doesn't surface per-node positions, so the importer scans the raw source
  for the question's start line and the offending field's key. Good
  enough for human-readable errors; if a customer's recruiter ever
  needs precise positions for a tooling integration, switch to
  `yamerl_constr` with `node_mods` or a different parser.
- **`prompt_asset_id` / `attachment_asset_id` referenced from importers
  pass through to the DB without existence checks.** A YAML/MD/JSON
  payload that names a UUID for a non-existent (or other-tenant) asset
  will fail at `Ecto.insert` with a foreign-key error mapped to
  `{:error, :reason}`. PLAN §3.4 says recruiters upload assets first
  and reference the returned ids; until the asset upload endpoint
  exists, this code path is unexercised. Tighten when the asset
  pipeline lands.
- **`POST /api/templates/:id/import` does not accept `application/json`
  bodies.** YAML and markdown only. JSON-as-wire-format flows through
  `PUT /api/templates/:id/versions/:vid/questions` instead, which is
  the intended split per PLAN §3.4 ("JSON is the API wire format. Not
  exposed as a hand-authored import format"). If a customer wants a
  single endpoint that accepts all three on the same path, the
  controller's `parse_result` `cond` already has the hook.
- **No webhook delivery yet.** PLAN §3.4 says webhook payloads carry
  `external_id`; the API round-trips `external_id` on every question
  in responses, but Phase 4 owns webhook signing/delivery.

## Numbers gathered

This session was code-only — no fresh load test or transcode bench.
Phase 1's 50/100-uploader numbers and ~9× realtime VP9→H264 figure
still stand and need re-validation when the work calls for it.

The new authoring path adds no per-recording overhead — it's all in the
recruiter request path (low-volume). The most expensive operation is
`apply_spec_to_draft/2`, which is `delete_all` + N inserts in one
`Multi`; for a 20-question template that's 21 statements in one
transaction.

## Decision-log changes

No PLAN §11 decisions overturned. Two clarifications worth recording:

1. **YAML library choice.** `:yaml_elixir` (pure Erlang via `:yamerl`)
   for parsing; hand-rolled dumper for the closed template-version
   schema. Avoids a second dep (`:ymlr` would also work but adds API
   surface for ~80 lines of focused emission). Rationale: CSV is
   already rejected (PLAN §3.4), the schema is fixed, and the only
   non-trivial dump case is the multi-line markdown prompt — handled
   with a `|` block scalar.
2. **One intermediate, three front doors — implementation shape.**
   Importers are responsible for translating Spec validation paths
   into human-readable locations:
   - YAML → heuristic `line:` via source scan.
   - Markdown → `line:` from the question's frontmatter block start.
   - JSON API → RFC 6901 pointer (`/questions/0/max_answer_seconds`).
   Spec itself carries only the structured `path:` so the validator
   stays format-agnostic. PLAN §3.4 importer-error contract is
   satisfied without a parser-aware validator.

## Gotchas worth knowing for next session

- **`Question.inserted_at` is `:naive_datetime`**, not `:utc_datetime_usec`.
  This bit Phase 2 candidate flow too (see the prior findings doc) and
  bit `Templates.clone_questions/3` again here. If you ever
  `insert_all` `template_questions` rows directly, use
  `NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)` for
  `inserted_at`/`updated_at` — the schema's default `timestamps()`
  macro doesn't match the `:utc_datetime_usec` used elsewhere.
- **`reorder_draft_questions/2` is two-stage on purpose.** Stage 1
  flips every position to a unique negative integer, Stage 2 settles
  to the final 1..N. A naive single-pass swap trips the
  `UNIQUE(template_version_id, position)` constraint. Don't simplify.
- **`Templates.create_draft_version/1` is idempotent.** A second call
  on a template that already has an open draft returns the existing
  draft instead of creating a second one. The LiveView mount and the
  `POST /api/templates/:id/versions` endpoint both rely on this.
- **`%Spec{spec | retake_policy: ...}` triggers a typing warning
  under Elixir 1.19 if the spec value is `dynamic()`.** Use a plain
  map update — `%{spec | ...}` — after pattern-matching on `%Spec{}`
  in the function head. `template_controller.ex` already does this.
- **Path segments are strings, not atoms.** `Spec.validate/1` returns
  paths like `["questions", 0, "max_answer_seconds"]`. Don't
  `Atom.to_string/1` segments — the controller learned this once.
- **`config :interview, dev_routes: true` is now set in
  `config/test.exs`** so the recruiter API's test-mode `x-tenant-id`
  bypass works. If you split prod auth off `DevTokenAuth`, also
  audit this flag — anything else gated on `dev_routes` will start
  firing in test.
- **`mix precommit` runs `format`, which rewrites your files.** If
  you edit a template-related file and then run precommit, expect the
  formatter to rearrange whitespace (multi-line keyword lists, `|>`
  pipelines). The Edit tool will fail on stale `old_string` matches
  after a format pass — re-read before editing.
- **`render_hook` does not return the LiveView's `:reply` payload.**
  Same gotcha as Phase 2 candidate flow — confirmed again here for
  the `update_field` event. Tests check the DB after the hook fires.

## Carries into next session

Inputs the next session should pick up:

- **Real tenant model + JWT bootstrap (single-use, ≤5 min) + upload
  bearer (≤60 min, refreshable)** (PLAN §4.2). Replaces
  `InterviewWeb.Plugs.DevTokenAuth` end-to-end. Gates the Phase 3
  embed SDK.
- **Recruiter-recorded video prompts + image/PDF attachments** —
  reuse the candidate MediaRecorder + IDB + tus pipeline; stored as
  `prompt_assets`. The authoring LiveView has hooks for
  `prompt_asset_id` / `attachment_asset_id` per question already; the
  upload UI and asset endpoints are the missing piece.
- **Whisper transcript Oban job** per `question_response` (PLAN §11
  decision #9). Independent of authoring; can slot in any time.
- **Drag-handle reorder polish** above (replace up/down buttons with
  a Sortable-style JS hook).
- **`POST /api/templates/:id/import` JSON body support**, if
  customers ask. The cond branch is already in `template_controller.ex`.
- **Asset-reference existence checks in importers** before they hit
  Ecto. Gated on the asset pipeline existing.

Carries forward from prior sessions still open:

- **Loadtest driver hardening**: re-HEAD on transport errors so the
  cascading-409 noise drops out (Phase 1 carry-forward).
- **Safari multi-question soak** on real hardware (Phase 2
  candidate-flow carry-forward).
- **Fly transcode bench** (`shared-cpu-2x`, `dedicated-cpu-2x`) —
  PLAN §12.3 / §12.7 finalizer sizing.
- **Think-time countdown UI gap** (Phase 2 candidate-flow
  carry-forward, ~20 lines).
- **`pageshow.persisted` BFCache path between questions** (Phase 2
  candidate-flow carry-forward).

## Phase-2 authoring exit checklist

Rows from PLAN §7 Phase 2 this session covered:

- [x] Template + version + question data model (§3.2). Versions are
      immutable; `sessions` reference a frozen `template_version_id`.
      (Schemas existed; this session added the context layer that
      enforces the immutability rule.)
- [x] Recruiter authoring UI (§3.4): LiveView template builder with
      autosave drafts and "Publish" creating a new version.
      Drag-handle is up/down buttons for now (see "Partial / known
      gaps").
- [x] YAML import/export of a template version + markdown-with-frontmatter
      importer; both normalise to the same intermediate `Spec` as the
      JSON API. Validation errors cite line numbers / JSON pointers
      with the offending field. CSV explicitly not supported.
- [x] Template + question REST API covering create / publish / list /
      get / import; webhook payloads (when delivery lands) carry
      `external_id`.
- [x] `mix precommit` green (107 tests).

Rows still open for Phase 2 (see "Carries into next session"):

- [ ] Recruiter-recorded video prompts via the candidate MediaRecorder
      + IDB + tus pipeline.
- [ ] Image/PDF prompt attachments uploaded via tus.
- [ ] Tenant model + JWT bootstrap tokens + upload bearer tokens.
- [ ] Whisper API transcript Oban job per `question_response`.
