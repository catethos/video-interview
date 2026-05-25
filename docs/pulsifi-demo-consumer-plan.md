# Pulsifi-demo consumer cutover — plan (commit #8)

> Goal: retire pulsifi-demo's in-process JS lattice scoring and make it a
> **consumer** of VI's new `session.scored` webhook. Scoring now happens
> inside VI (commits #0–#7); pulsifi-demo stops *running* the pipeline and
> starts *storing* the result that arrives in the webhook.
>
> This lives in the **`pulsifi-demo` repo** (the reference implementation the
> backend team builds production from). It's written from VI's side as the
> producer's spec for what the consumer must do. Companion to
> `docs/scoring-webhook-contract.md`.

## Where pulsifi-demo is today

The receiver + HMAC verify + idempotent dedup already exist — only the
*scoring* changes.

```
VI session.ready  ──▶  POST /webhooks/vi  (modules/webhooks/routes.ts)
                         │  verify HMAC (lib/crypto.ts)
                         │  dedup on (delivery_id, event_type) → webhook_events
                         ▼
                       scoreInterview(applicationId)   (modules/scoring/service.ts)
                         │  fetchScoringExport(viSessionId)        (vi-client)
                         │  runPipeline(topology, row)   ← JS lattice (lattice-lang)
                         │     · runner.ts / topology.ts / apps/backend/pipelines/
                         ▼
                       interview_scores (p1Result…p5Result jsonb) + applications.status
```

The frontend report (`apps/frontend/src/routes/recruiter/ScoringReportPage.tsx`)
reads `p1Result…p5Result` off `interview_scores` and renders per-question
scores.

## Target

```
VI session.scored  ──▶  POST /webhooks/vi
                          │  verify + dedup (UNCHANGED)
                          ▼
                        storeScore(applicationId, data)   ← NEW, no pipeline run
                          ▼
                        interview_scores + applications.status  (same columns)
```

`session.ready` stops triggering scoring; it becomes a status signal only
("recording done, score pending"). `session.scored` (and
`session.scoring_failed`) drive the score.

## The one real parity trap — read this first

The frontend reads **`p3Entry.question_text` and `p3Entry.answer_text`** off
the stored `p3Result` (and similar for `p4`). The **old** JS `stageOutputs.p3`
carried those inline (the stage's `ProcessData` SELECTed them). The **new** VI
payload deliberately prunes them — the Q+A text is carried **once** in
`data.interview_transcript` (contract §4.3/§4.4), not duplicated per stage.

So a naïve "store `data.pipeline_outputs.p3` verbatim" would leave the
report's per-question prompt/answer blank.

**Fix (thin adapter, frontend untouched):** when storing, **enrich** each
`p3`/`p4` entry with `question_text` + `answer_text` looked up from
`data.interview_transcript` by `question_number`. This reproduces the old
stored shape, so `ScoringReportPage.tsx` needs **no change**.

(Alternative considered: carry question_text/answer_text in VI's
`pipeline_outputs` p3/p4. Rejected — it duplicates the transcript per stage
per question and bloats every `session.scored` payload. The consumer already
has the transcript in the same delivery; enrich there.)

## Data → `interview_scores` mapping (the adapter)

Same columns, same derivations as today's `scoreInterview` — only the source
changes (webhook `data` instead of `fetchScoringExport` + `runPipeline`):

| Column | From |
|---|---|
| `pipelineVersion` | `data.pipeline_version` |
| `p1Result` | `data.classifications` (array; the frontend's classification extractor already accepts a bare array) |
| `p2Result` | `data.pipeline_outputs.p2` |
| `p3Result` | `data.pipeline_outputs.p3`, **each entry enriched** with `question_text`/`answer_text` from `data.interview_transcript` by `question_number` |
| `p4Result` | `data.pipeline_outputs.p4`, enriched the same way |
| `p5Result` | `data.pipeline_outputs.p5` |
| `completedAt` | `data.scored_at` |
| `error` | `null` |

`applications` update (identical logic to `scoreInterview`'s tail, now sourced
from `data.interview_transcript`):

- `status` → `"scored"`
- `viResponseIds` → `{questionNumber: response_id}` (drop null response_ids)
- `viFocusLostCounts` → `{questionNumber: focus_lost_count}` where `> 0`
- `viFocusLostDurationMs` → `{questionNumber: focus_lost_total_ms}` where `> 0`

Upsert stays keyed on `(application_id, pipeline_version)` — same idempotency
the JS path had, and it now also dedups naturally with VI's stable
`session.scored` delivery id.

## File-by-file changes (pulsifi-demo)

**`packages/shared/src/webhook-types.ts`**
- Add `"session.scored"` and `"session.scoring_failed"` to
  `ViWebhookTypeSchema`.
- Ensure `data` accepts the scoring payload. If it's a loose record today,
  no change; otherwise add a `ViScoredDataSchema` (pipeline_version,
  scored_at, classifications, pipeline_outputs, interview_transcript) and a
  `ViScoringFailedDataSchema` (pipeline_version, stage, reason, message,
  attempts).

**`apps/backend/src/modules/webhooks/routes.ts`**
- New branch `parsed.type === "session.scored"`: find the application by
  `viSessionId`, call the new `storeScore(applicationId, parsed.data)`.
- New branch `parsed.type === "session.scoring_failed"`: set the application
  to a `scoring_failed` status and persist `data.reason`/`message` (surface
  "scoring temporarily unavailable" on the report).
- **Remove** the `session.ready → scoreInterview` trigger. Keep a
  `session.ready` branch only if you want a "recording complete, awaiting
  score" status transition.

**`apps/backend/src/modules/scoring/service.ts`**
- Replace `scoreInterview/1` (fetch + runPipeline + store) with
  `storeScore(applicationId, data)` (the mapping above). No lattice, no
  `fetchScoringExport`, no `runPipeline`.

**Delete once parity is confirmed (see next section):**
- `apps/backend/src/modules/scoring/runner.ts` + `runner.test.ts`
- `apps/backend/src/modules/scoring/topology.ts`
- `apps/backend/pipelines/` (the bundle + `topology.json`)
- `lattice-lang` from `apps/backend/package.json` (+ lockfile)
- `fetchScoringExport` from `modules/vi-client/client.ts` **if** nothing else
  uses it (the transcript now arrives in the webhook; grep first).
- `OPENROUTER_API_KEY` from `apps/backend/.env*` / `env.ts` — scoring no
  longer calls an LLM here.

**`apps/frontend/.../ScoringReportPage.tsx`** — **no change** if the adapter
enriches p3/p4. Confirm the report renders identically.

## Parity verification (before deleting anything)

The JS path and the webhook path should produce the **same stored shape**.
Verify, don't assume:

1. Land the consumer changes **alongside** the old path on a branch (don't
   delete the JS files yet). Point a VI dev tenant's `webhook_url` at the
   pulsifi-demo receiver.
2. Run one real interview end-to-end through VI (Path A of
   `docs/scoring-smoke-checklist.md`). VI fires `session.scored`.
3. Diff the resulting `interview_scores` row against one produced by the old
   `scoreInterview` for the same transcript:
   - `p3Result`/`p4Result` entries have `question_number`, the score dims
     (`.score`/`.justification`), **and** `question_text`/`answer_text`.
   - `p5Result` has `overall_insights` + `question_level_evaluation`.
   - `p1Result` classifications render per question.
   - `applications.viResponseIds` / focus maps populated.
4. Load `ScoringReportPage` for the new row — it must render with no blanks
   (especially per-question prompt/answer text — the parity trap).
5. Only when the report is identical: delete the JS path (one commit), drop
   the dep + bundle (one commit).

## Rollout (pulsifi-demo commit boundaries)

1. **shared:** add the two event types (+ optional data schemas).
2. **consumer:** `storeScore` + receiver branches for `session.scored` /
   `session.scoring_failed`; stop scoring on `session.ready`. Old JS files
   still present (parity run).
3. **verify:** run the parity check above; fix any shape gap.
4. **retire:** delete runner/topology/service-pipeline, `apps/backend/pipelines/`,
   `lattice-lang`, `OPENROUTER_API_KEY`, unused `fetchScoringExport`.
5. **docs:** note in pulsifi-demo's README that scoring is VI-owned; the app
   is a consumer.

## Open questions

1. **`session.scoring_failed` UX** — show "scoring unavailable" on the report,
   or a retry affordance? v1: status + message only; recruiter sees the state.
2. **Late `session.ready` vs `session.scored` ordering** — `session.ready`
   arrives first (recording done), `session.scored` later (after VI scores).
   The application status should move ready/awaiting → scored. Confirm the UI
   handles the "awaiting score" window gracefully (it already polls —
   `refetchInterval` every 5s until a score exists).
3. **Backfill** — existing applications scored by the old JS path keep their
   rows (same shape). No migration needed; new scores arrive via webhook.
