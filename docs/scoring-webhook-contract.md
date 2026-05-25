# `session.scored` webhook contract

> Goal: pin down the exact wire contract for the two scoring events
> the platform emits once the lattice pipeline finishes —
> `session.scored` (success) and `session.scoring_failed` (terminal
> failure). This is the seam between VI (the producer) and the
> consumer (Talent App in production, Pulsifi-demo in dev). It is the
> reference both sides code against and QA tests against.
>
> Companion to `docs/integration.md` §8, which documents the four
> existing session events. This doc is §8 for scoring. Everything
> about transport — envelope, headers, signing, retries — is
> **identical** to the existing events; only two new `type` strings
> and their `data` shapes are new.

## 1. The one thing to understand first

The scoring events are not a new delivery mechanism. They ride the
**exact same pipe** as `session.ready` and friends:

- Same ledger table (`webhook_deliveries`, one row per
  `(session_id, event_type)`).
- Same Oban delivery worker (`Interview.Workers.WebhookDelivery`).
- Same envelope, same five headers, same HMAC signing, same retry
  schedule, same circuit breaker.

(Oban is the background-job runner — think of it as a durable task
queue, like Celery or a managed Lambda retry loop. The "delivery
worker" is one job type on that queue whose whole purpose is "POST
this payload to the tenant's URL and record what happened.")

The only net-new code on the webhook side is:

1. Two strings added to the allowed-events list in
   `Interview.Webhooks` (`"session.scored"`,
   `"session.scoring_failed"`).
2. Two `derive_data/3` clauses that pass the worker-built `data`
   through.

If you already verify `session.ready`, your scoring receiver is 90%
written. The new work is purely **understanding the `data` shape**,
which is what the rest of this doc is about.

```
ScorePipeline worker (the new producer)
      │  builds the scoring `data` map
      ▼
Interview.Webhooks.enqueue(session, "session.scored", data)
      │  upserts webhook_deliveries row + inserts Oban job
      ▼
Interview.Workers.WebhookDelivery   ← unchanged, shared with all events
      │  Jason.encode! → sign → POST
      ▼
consumer endpoint  (verifies signature, dedupes, stores)
```

## 2. Transport — the HTTP request

| Property | Value |
|---|---|
| Method | `POST` |
| URL | the tenant's configured `webhook_url` |
| Body | `Jason.encode!(payload)` — UTF-8 JSON, no trailing newline |
| TLS | required in production (the only thing that stops a body being captured for replay — see §7) |

Headers on **every** POST (byte-identical convention to the existing
events, emitted by `WebhookDelivery.post_and_record/3`):

| Header | Value | Notes |
|---|---|---|
| `Content-Type` | `application/json` | |
| `User-Agent` | `interview-webhook/1` | |
| `X-Interview-Event` | `session.scored` \| `session.scoring_failed` | same as the envelope `type` |
| `X-Interview-Delivery-Id` | a UUID | **stable** per `(session_id, event_type)` across retries — your idempotency key (§8) |
| `X-Interview-Signature` | `sha256=<hex>` | HMAC-SHA256 over the **raw request body** using the tenant's `webhook_secret` (§6) |

There is no `X-Interview-Timestamp` header. The timestamps live
inside the signed body (`occurred_at`, `delivered_at`); see §7 for
why that is, and what it does and doesn't buy you.

## 3. The envelope

Identical structure to the four existing events. Only `type` and the
contents of `data` differ.

```json
{
  "v": 1,
  "type": "session.scored",
  "tenant_id": "b1c3…",
  "session_id": "9af2…",
  "external_id": "willo-app-12345",
  "occurred_at": "2026-05-25T04:31:07.412233Z",
  "delivered_at": "2026-05-25T04:31:07.412233Z",
  "data": { … }
}
```

| Field | Type | Meaning |
|---|---|---|
| `v` | int | Payload schema version. Currently `1`. An absent `v` means `1`. New fields may be **added** but never removed (append-only — see §11). |
| `type` | string | `"session.scored"` or `"session.scoring_failed"`. |
| `tenant_id` | string (UUID) | The VI tenant the session belongs to. |
| `session_id` | string (UUID) | VI's canonical session id. The join key into your own store. |
| `external_id` | string \| null | The id the tenant supplied at bootstrap (e.g. their application id). Often your real primary key; use it when present, fall back to `session_id`. |
| `occurred_at` | ISO 8601 (UTC, µs) | When this webhook event was minted (= when scoring finished, on first fire). |
| `delivered_at` | ISO 8601 (UTC, µs) | Stamped **once** at ledger-row creation and held **stable across all retries**. Part of the dedupe story (§8). |
| `data` | object | Event-specific. §4 (scored) / §5 (failed). |

## 4. `session.scored` — the `data` payload

This is the payload that carries the actual scoring result. It is
built by `Workers.ScorePipeline` and handed to `Webhooks.enqueue/3`,
which passes it through unchanged.

Design intent: the payload is a **complete, self-contained scoring
record**. A consumer can store it verbatim and render a full report
with no follow-up call back to VI. It deliberately mirrors the
on-disk shape Pulsifi-demo already persists — `classifications` +
`pipeline_outputs` + `interview_transcript` — so the cutover from
the JS lattice runner to this webhook is a thin adapter, not a
rewrite.

### 4.1 Top-level `data` fields

| Field | Type | Reasoning |
|---|---|---|
| `pipeline_version` | string | Which pipeline build produced these scores. The consumer keys its stored record on this and can detect schema drift ("these scores came from an older pipeline; re-render or re-request"). Mirrors `session_scores.pipeline_version`. See §12.1 — its canonical source in the bundle is an open implementation detail. |
| `scored_at` | ISO 8601 | When the pipeline finished, from `session_scores.computed_at`. Within milliseconds of envelope `occurred_at` on first delivery (the two are stamped by separate `utc_now/0` calls in the same transaction, so they're close but not bit-identical); kept as a separate **domain** timestamp so the score record is self-describing independent of envelope/transport concerns. |
| `classification_provider` | string \| null | The model that produced P1, from `template_classifications.provider` (e.g. `"google/gemini-2.5-flash"`). Provenance for audit. v1 persists the model for P1 only; per-stage model provenance for P2–P5 is not recorded (§12.4). |
| `classifications` | array | **P1 output.** Per-question classification, computed once per `template_version_id` and shared across every candidate on that template (the v2 fairness fix: P1 reads only the questions, never a candidate's answers). §4.2. |
| `pipeline_outputs` | object | **P2–P5 output**, keyed by semantic stage (`"p2"`, `"p3"`, `"p4"`, `"p5"`). The per-question evidence and scores plus the session-level aggregate. §4.3. |
| `interview_transcript` | array | The exact Q+A the scores were computed from. Byte-for-byte the shape of `GET /api/sessions/:id/scoring_export` (`ExternalIntegration.ScoringExport`). Pins what the scores describe and lets the consumer render the report without a second fetch. §4.4. |

### 4.2 `classifications` (P1)

One entry per interview question. Real field names, taken from the
P1 stage output:

| Field | Type | Meaning |
|---|---|---|
| `question_number` | int | 1-based position, matches `interview_transcript[].question_number`. |
| `question_text` | string | The prompt, echoed for self-containment. |
| `question_type` | string | e.g. `"behavioral"`, `"situational"`, `"technical"`. |
| `question_type_rationale` | string | Why P1 assigned that type. |
| `target_constructs` | array<string> | The competencies the question is designed to probe (e.g. `["Adaptability", "Resilience", "Learning Agility"]`). |
| `target_constructs_rationale` | string | Why each construct applies. |

### 4.3 `pipeline_outputs` (P2–P5)

Keyed by semantic stage. The keys are the **logical** P-numbers, not
the bundle's directory order (the bundle ships stages in the order
P1, P5, P2, P4, P3 — a build-tool artifact; the contract normalizes
to logical order so consumers never see it). §12.3.

Note the **grain** of each stage — two are per-question (an array,
one entry per interview question) and two are per-session (a single
object):

```
pipeline_outputs
├── "p2"  evidence extraction  (per-session) → { question_evidences: [ {question_number, …}, … ] }
├── "p3"  layer-1 scoring      (per-question) → [ {question_number, clarity_coherence, relevance_completeness, support_quality}, … ]
├── "p4"  layer-2 scoring      (per-question) → [ {question_number, layer2_scores: {action_effectiveness, behavioral_evidence, outcome_effectiveness}}, … ]
└── "p5"  aggregate            (per-session) → { overall_insights: [ … ], question_level_evaluation: [ {question_number, overall_scoring_rationale, score_insights}, … ] }
```

- `p3` and `p4` are **arrays, one element per question**, in
  question order. The lattice runner emits these stages one row per
  question.
- `p2` and `p5` are **single objects**; the per-question detail lives
  in the arrays *inside* them (`question_evidences`,
  `question_level_evaluation`), each entry self-labeled with
  `question_number`.

Each leaf score is a `{ "score": int, "justification": string }`
pair. `score` is the 1–5 rubric value; `justification` is the
model's written reasoning.

**Every per-question entry carries `question_number`** so a consumer
can join it to `interview_transcript` and `classifications`.
Important implementation note: the raw P3/P4 stage *output* does
**not** include `question_number` — it lives in each stage's
*input*. The runner must attach it to each emitted entry; without it
the consumer cannot tell which question a `[3, 4, 3]` score triple
belongs to. (P2 and P5 already carry `question_number` in their
output.) Tracked in §12.6.

**Wire-shape decision (read this):** internally the lattice runner
passes each stage's output to the next as a **JSON-encoded string**,
not a nested object — a documented DuckDB/nested-Arrow quirk
(`serializeRowsForNextStage` in the JS runner; mirrored in the
Elixir runner). On the wire we **parse those leaf strings back into
real JSON** before emitting, so the consumer receives clean nested
JSON and never has to `JSON.parse` a field that's already inside a
JSON body. The double-encoded internal form does **not** leak into
the payload. (Alternative considered: pass the strings through
verbatim to match the runner's internal form exactly. Rejected —
double-encoding is a wire smell and forces every consumer to
re-parse. VI owns this boundary, so VI normalizes once. Flagged in
§12.2 because it means the emitted shape differs from the raw
stage-output files in `priv/pipelines/`.)

Internal-only fields that are present in the raw stage output but
**deliberately excluded** from the payload:

- `metrics` — per-stage pipeline-QA scores (e.g.
  `p1_checkclassificationfromquestiononly`). These verify the
  *pipeline* behaved, not the *candidate*. Internal observability,
  not consumer-facing.
- `input` — each stage's input row. The transcript is carried once
  as `interview_transcript`; repeating it per stage is redundant
  bloat.

### 4.4 `interview_transcript`

Mirrors `ExternalIntegration.ScoringExport.transcript_entry/1`
exactly — same fields, same types — so a consumer that already
reads the scoring-export endpoint reads this with the same code.

| Field | Type | Meaning |
|---|---|---|
| `question_number` | int | 1-based position. |
| `question_text` | string | The prompt. |
| `answer_text` | string \| null | Whisper transcript; `null` if the candidate skipped. |
| `response_id` | string (UUID) \| null | The canonical answer row; `null` if skipped. |
| `duration_ms` | int \| null | Answer length in ms. |
| `focus_lost_count` | int | How many times the candidate left the tab while recording (`0` when never). |
| `focus_lost_total_ms` | int | Total ms spent off-tab while recording. |

## 5. `session.scoring_failed` — the `data` payload

Emitted **once**, only on **terminal** failure — i.e. the worker
exhausted its retries (rate limits, repeated transport/decode
errors) or hit a non-retryable error. This event is what stops the
consumer waiting forever for a `session.scored` that is never
coming. A consumer should treat it as "scoring is not available for
this session; show 'temporarily unavailable', do not block the
recruiter."

Transient retries do **not** emit this event — they are invisible to
the consumer (Oban retries internally). Only the final give-up does.

| Field | Type | Reasoning |
|---|---|---|
| `pipeline_version` | string | Same as scored — which build was attempting the score. |
| `failed_at` | ISO 8601 | When the worker gave up, from `session_scores.computed_at` (the row is written with `status: "failed"`). |
| `stage` | string \| null | Which stage failed (`"p1"`…`"p5"`), or `null` if the failure was before any stage ran (e.g. export build error). Lets the consumer/ops tell "the LLM choked on P3" from "we never got off the ground." |
| `reason` | string | A stable machine code, mirroring `session_scores.error_reason`: `"rate_limited"`, `"server_error"`, `"decode_error"`, `"transport"`, `"unknown"`. Matches the `reason` convention used by the existing `session.failed` event. |
| `message` | string | Human-readable detail for logs/dashboards. Not for branching on — branch on `reason`. |
| `attempts` | int | How many tries before giving up (the worker's `max_attempts`, `6`). Distinguishes "retried hard then exhausted" from a `1`-attempt non-retryable error. |

Note: `error_reason` in `session_scores` is a free-ish string column;
this contract pins the **allowed values** above. New codes may be
added (append-only); consumers should treat an unrecognized `reason`
as `"unknown"`.

## 6. Security — the HMAC signature

(HMAC = a keyed hash. Concretely: run SHA-256 over the request body
mixed with a shared secret only you and VI know. The result proves
two things at once — the body wasn't altered in transit, and it came
from someone holding the secret. Same idea as signing an API request;
nothing scoring-specific here.)

- VI computes `signature = HMAC-SHA256(webhook_secret, raw_body)`,
  hex-encoded lowercase, and sends it as
  `X-Interview-Signature: sha256=<hex>`.
- The signature is over the **raw bytes** of the request body —
  verify before parsing JSON, and verify against the bytes you
  received, not a re-serialized copy (re-encoding can reorder keys
  or change whitespace and break the match).
- `webhook_secret` is per-tenant (`tenants.webhook_secret`).

Verification (Node.js — identical to `docs/integration.md` §8, since
it's the same signing path):

```js
const crypto = require("node:crypto");

const expected =
  "sha256=" +
  crypto.createHmac("sha256", process.env.WEBHOOK_SECRET)
        .update(rawBody)            // the raw bytes, not JSON.parse(...)
        .digest("hex");

const got = req.headers["x-interview-signature"] || "";
const ok =
  expected.length === got.length &&
  crypto.timingSafeEqual(Buffer.from(expected), Buffer.from(got));

if (!ok) return res.status(401).end();   // reject before doing anything
```

Use a constant-time compare (`timingSafeEqual`), not `===` — a
plain string compare leaks timing information an attacker can use to
forge a signature byte by byte.

## 7. Replay protection (timestamp) — and its honest limits

A correctly-signed POST is, by construction, replayable: an attacker
who captures one valid delivery can re-send those exact bytes and the
HMAC will verify, because it *is* a genuine signed message. This is
true of every HMAC webhook scheme, ours included. So "replay
protection" here is layered, not a single silver bullet:

1. **TLS** is the first and most important layer — it stops the body
   being captured in the first place. Production receivers must be
   HTTPS. Without this, nothing below matters.
2. **Signed timestamps.** `occurred_at` and `delivered_at` live
   inside the signed body, so they can't be altered without breaking
   the signature. A receiver **should** reject a delivery whose
   `occurred_at` is implausibly far from "now" on **first** sight —
   a tolerance window (e.g. ±15 minutes) blunts a stale capture being
   replayed much later.
3. **Idempotent processing (§8)** is what actually neutralizes a
   replay in practice: a replayed delivery carries a
   `X-Interview-Delivery-Id` you've already processed, so your
   handler treats it as a no-op. The attacker gains nothing.

**The tension you must respect.** Do **not** gate on `delivered_at`
with a tight freshness window. Legitimate retries of a real delivery
can arrive up to ~24 hours after the original (§9) and they
deliberately carry the **same** `delivered_at` and the **same**
delivery-id. A naive "reject if timestamp older than N minutes"
check would throw away valid late retries. The freshness window in
(2) is therefore a **first-sight** heuristic on `occurred_at`, and
the durable defense is (3) idempotency keyed on the delivery-id — a
late retry is a known id, so it's a safe no-op regardless of age.

This is the single weakest part of any HMAC webhook contract; it is
documented honestly rather than papered over. If a future threat
model demands true cryptographic anti-replay (a per-delivery nonce
that changes on every attempt), note that it **conflicts** with the
current stable-id-across-retries idempotency design and would be a
deliberate breaking change, not a v1 tweak (§12.5).

## 8. Idempotency — dedupe on the delivery id

You **will** receive the same event more than once. Retries (§9),
at-least-once delivery, and replays (§7) all mean: build your
receiver to be idempotent or you will double-count scores.

The contract gives you a stable key:

- `X-Interview-Delivery-Id` is **stable per `(session_id,
  event_type)`** and identical on every retry of the same event.
- Persist processed delivery-ids. On receipt: if you've seen this id,
  ack `2xx` and stop. Otherwise process, store the id, ack `2xx`.
- `delivered_at` is the secondary stable signal — same value on every
  retry — useful as a sanity cross-check.

Ack semantics that keep retries sane:

- Return **`2xx` quickly** once you've durably accepted the delivery
  (even if downstream processing is async). VI marks the row
  `delivered` and stops retrying on any `2xx`.
- Return `5xx` / `408` / `429` only if you want VI to retry.
- Any other `4xx` is treated by VI as a **permanent** failure: the
  delivery is dropped and not retried (§9). Don't return `400` for a
  transient hiccup — you'll lose the event.

**Forward hazard (v1-safe, but know it):** the delivery-id is stable
per `(session_id, event_type)`. A given session is scored exactly
once in v1 (no re-score endpoint — explicitly out of scope in the
plan), so one `session.scored` per session, one stable id, no
collision. If a future re-score against a newer `pipeline_version`
ever ships, it would reuse the same `(session_id, "session.scored")`
delivery row and id — your idempotent receiver would treat the new
scores as a duplicate and **drop them**. The fix, when re-scoring
lands, is to fold `pipeline_version` into the delivery identity. Out
of scope today, flagged so it isn't a surprise later (§12.5).

## 9. Retry semantics

Unchanged from the existing events — same `WebhookDelivery` worker,
so the schedule is shared:

- **Retryable:** HTTP `408`, `429`, any `5xx`, and transport errors
  (DNS, connection, timeout).
- **Permanent (no retry, drop + alert):** any other `4xx`, and
  URL-policy rejections (SSRF guard, bad scheme, private IP).
- **Schedule:** Oban backoff `attempt^4 + 15 + jitter`, up to
  `max_attempts: 14` — roughly **24 hours** of coverage before the
  delivery is abandoned.
- **Circuit breaker:** if a tenant's last N deliveries all permafail
  (default 20, configurable), VI nulls that tenant's `webhook_url` to
  stop hammering a dead endpoint. The recruiter re-sets it from
  settings. So a receiver that's been returning hard errors can stop
  receiving entirely — return `2xx` on anything you've accepted.

Note the asymmetry between the two layers' attempt counts, by design:

- The **scoring worker** (`max_attempts: 6`) retries the *pipeline
  computation* (LLM calls). Exhausting these emits
  `session.scoring_failed`.
- The **delivery worker** (`max_attempts: 14`) retries the *HTTP POST*
  of whichever event was produced. Exhausting these just stops
  delivering; it does not emit anything new.

A `session.scoring_failed` that itself can't be delivered will retry
for ~24h and then be abandoned like any other undeliverable event.

## 10. Full example payloads

### 10.1 `session.scored`

Two-question interview, real shapes drawn from the v2 smoke-test
bundle (truncated transcript text for readability):

```json
{
  "v": 1,
  "type": "session.scored",
  "tenant_id": "b1c3a2d4-5e6f-4708-9a1b-2c3d4e5f6071",
  "session_id": "9af2e1c0-77b3-4d21-8e5a-1f0c9b8a7d63",
  "external_id": "willo-app-12345",
  "occurred_at": "2026-05-25T04:31:07.412233Z",
  "delivered_at": "2026-05-25T04:31:07.412233Z",
  "data": {
    "pipeline_version": "smoke_test_Pipeline_2_2026-05-25-0423",
    "scored_at": "2026-05-25T04:31:07.412233Z",
    "classification_provider": "google/gemini-2.5-flash",
    "classifications": [
      {
        "question_number": 1,
        "question_text": "Describe a time when you faced a challenging situation… How did you approach it, and what did you learn…?",
        "question_type": "behavioral",
        "question_type_rationale": "Asks the candidate to recount a specific past experience and the actions taken to handle a challenge.",
        "target_constructs": ["Adaptability", "Resilience", "Learning Agility"],
        "target_constructs_rationale": "Adaptability: how the candidate adjusts to changing or unclear tasks. Resilience: maintaining performance under deadline. Learning Agility: extracting lessons to improve future performance."
      },
      {
        "question_number": 2,
        "question_text": "Describe a time you worked with a stakeholder who had different expectations… How did you build trust and align goals under time pressure?",
        "question_type": "behavioral",
        "question_type_rationale": "Asks for a concrete past instance of stakeholder management.",
        "target_constructs": ["Stakeholder Management", "Communication", "Influence"],
        "target_constructs_rationale": "Probes how the candidate aligns differing expectations and moves work forward under pressure."
      }
    ],
    "pipeline_outputs": {
      "p2": {
        "question_evidences": [
          {
            "question_number": 1,
            "question_text": "Describe a time when you faced a challenging situation…",
            "evidence": {
              "actions": ["took the initiative to use VBM macros to accelerate the process"],
              "outcomes": ["completed all tasks on time", "the macro was later adopted by the pricing team"],
              "technical_knowledge": ["Excel", "VBM macros"],
              "self_claims": ["proud of my ability to adapt and work effectively"],
              "decision_logic": [],
              "examples": ["three complex Excel tasks within three days at Everdy Insurance"],
              "motivations": ["to really contribute to the company"],
              "reasoning": ["it would be impossible to finish manually on time"],
              "tradeoffs": []
            },
            "ambiguities": ["'VBM macros' may be a typo for 'VBA macros' or an internal term."],
            "evidence_gaps": ["The specific complexity of the three Excel tasks is not described."]
          }
        ]
      },
      "p3": [
        {
          "question_number": 1,
          "clarity_coherence": {
            "score": 4,
            "justification": "Logical progression from challenge to action to outcome; easy to follow."
          },
          "relevance_completeness": {
            "score": 3,
            "justification": "Addresses the deadline challenge but does not explain what was learned for the MT STAR role."
          },
          "support_quality": {
            "score": 3,
            "justification": "Concrete example (VBM macros at Everdy Insurance) but lacks depth on task complexity."
          }
        }
      ],
      "p4": [
        {
          "question_number": 1,
          "layer2_scores": {
            "action_effectiveness": {
              "score": 4,
              "justification": "Identified a bottleneck and implemented a technical solution that met the deadline; adoption by the pricing team evidences effectiveness."
            },
            "behavioral_evidence": {
              "score": 3,
              "justification": "Clearly describes using macros to meet a three-day deadline, but light on the specifics of the tasks."
            },
            "outcome_effectiveness": {
              "score": 4,
              "justification": "Met the deadline and created lasting value, though impact is not quantified."
            }
          }
        }
      ],
      "p5": {
        "overall_insights": [
          "Consistently describes technical process improvements, aligning with MT STAR's emphasis on driving impact through projects.",
          "Responses focus on individual technical tasks rather than collaborative leadership or cross-functional stakeholder management.",
          "Provides internship evidence meeting the JD's experience requirement, though depth on stakeholder-conflict management is unvalidated."
        ],
        "question_level_evaluation": [
          {
            "question_number": 1,
            "overall_scoring_rationale": "Clear example of technical problem-solving under deadline resulting in an adopted tool; lacks reflection on the learning process.",
            "score_insights": [
              "Use of VBM macros to resolve a bottleneck indicates a proactive approach.",
              "Tangible, ongoing contribution to the pricing team.",
              "Lacks explicit evidence of learning agility — no specific lessons detailed."
            ]
          },
          {
            "question_number": 2,
            "overall_scoring_rationale": "Describes stakeholder alignment but stays general on the specific trust-building actions taken.",
            "score_insights": [
              "Shows awareness of differing stakeholder expectations.",
              "Light on the concrete steps taken to build trust under time pressure."
            ]
          }
        ]
      }
    },
    "interview_transcript": [
      {
        "question_number": 1,
        "question_text": "Describe a time when you faced a challenging situation…",
        "answer_text": "One time at Everdy Insurance I had to complete three complex Excel tasks within three days, so I used VBM macros to accelerate the process…",
        "response_id": "3f5b9c11-0a2d-4e88-9c44-7b1e2a6d8f90",
        "duration_ms": 84120,
        "focus_lost_count": 0,
        "focus_lost_total_ms": 0
      },
      {
        "question_number": 2,
        "question_text": "Describe a time you worked with a stakeholder…",
        "answer_text": "When a pricing analyst pushed back on my approach, I set up a short call to align on the goal…",
        "response_id": "c20a7e34-9b18-4d2f-a6e7-55f0c9b1d2a3",
        "duration_ms": 76540,
        "focus_lost_count": 1,
        "focus_lost_total_ms": 4200
      }
    ]
  }
}
```

For brevity the per-question collections above (`p3`, `p4`,
`p2.question_evidences`, `p5.question_level_evaluation`) show only
question 1. A real 2-question payload carries **two** entries in
each, one per `question_number`, matching the
`interview_transcript` length.

### 10.2 `session.scoring_failed`

```json
{
  "v": 1,
  "type": "session.scoring_failed",
  "tenant_id": "b1c3a2d4-5e6f-4708-9a1b-2c3d4e5f6071",
  "session_id": "9af2e1c0-77b3-4d21-8e5a-1f0c9b8a7d63",
  "external_id": "willo-app-12345",
  "occurred_at": "2026-05-25T04:36:55.901002Z",
  "delivered_at": "2026-05-25T04:36:55.901002Z",
  "data": {
    "pipeline_version": "smoke_test_Pipeline_2_2026-05-25-0423",
    "failed_at": "2026-05-25T04:36:55.901002Z",
    "stage": "p3",
    "reason": "rate_limited",
    "message": "Provider returned 429 on P3 after 6 attempts over ~8m.",
    "attempts": 6
  }
}
```

## 11. Versioning & compatibility rules

- The payload is **append-only**. New fields may be added under `data`
  (or new stage keys under `pipeline_outputs`) without bumping `v`.
  Fields are **never removed or renamed** without a `v` bump.
- Receivers **must ignore unknown fields** — both unknown top-level
  keys and unknown keys inside any stage output. A pipeline revision
  that adds a new construct or a new score dimension must not break an
  older receiver.
- Receivers should treat an absent `v` as `v = 1`.
- `pipeline_version` is the consumer's signal that the *scoring*
  schema (not the envelope) may have shifted; pin rendering logic to
  the versions you've validated and degrade gracefully on an
  unrecognized one.

## 12. Open questions / implementation must-reconcile

These are gaps between the locked plan, this contract, and what the
actual v2 bundle contains. They are implementation details for the
upcoming commits (#2 bundle copy, #3 schemas, #4 context), surfaced
here so the contract isn't quietly contradicted by the code.

1. **`pipeline_version` has no source field in the bundle.** The plan
   assumes a `pipeline_version` key in `topology.json`. The actual
   bundle (`pipeline.json`) has **`assembly_id`** (a UUID build id)
   and **`bundle_format_version`**, not `pipeline_version`. The loader
   must derive `pipeline_version` from something stable — candidates:
   the bundle directory name (`smoke_test_Pipeline_2_2026-05-25-0423`,
   human-readable, used in the examples here) or `assembly_id`
   (opaque but guaranteed unique). Decide in commit #3/#4 and keep it
   consistent with the cache key `(template_version_id,
   pipeline_version)`.
2. **Leaf JSON-string parsing.** §4.3: the emitted payload parses the
   stage-output leaf strings into real JSON, which means the wire
   shape differs from the raw `output.json` files shipped in
   `priv/pipelines/`. The runner must do this normalization on the
   way out. Confirm Pulsifi-demo's stored shape is the parsed form
   (it should be — its frontend reads `q.p3Entry.score` as a number)
   so the "thin adapter" claim holds.
3. **Stage order normalization.** The bundle ships stages in build
   order (P1, P5, P2, P4, P3); this contract emits them keyed by
   logical stage (`p1`…`p5`). The runner already keys by stage id, so
   this is a presentation mapping, but the mapping table
   (`stage_id → "pN"`) must be explicit in the topology loader, not
   inferred from directory order.
4. **Per-stage model provenance.** Only P1's model is persisted
   (`template_classifications.provider`), surfaced as
   `classification_provider`. The bundle shows P2–P5 may use a
   different model (`gemini-3.1-flash-lite` vs `gemini-2.5-flash`). If
   the consumer needs full per-stage provenance, add a `providers`
   map to `data` in a later (append-only) revision.
5. **Re-score delivery-id collision.** §8 forward hazard: a future
   re-score would reuse the `(session_id, "session.scored")` delivery
   id and be dropped as a duplicate by idempotent receivers. Folding
   `pipeline_version` into delivery identity is the fix — tracked
   against the deferred `/api/sessions/:id/rescore` work, not v1.
6. **`question_number` attachment on P3/P4.** §4.3: the per-question
   scoring stages emit one row per question but their *output* omits
   `question_number` (it's only in the stage *input*). The runner
   **must** attach `question_number` to each emitted `p3`/`p4` entry,
   or the array is unjoinable to the transcript. This is a hard
   requirement on the runner (commit #4), not a nice-to-have — verify
   it in the runner's tests, not just by inspection.
7. **Payload size vs. the deliveries ledger.** Unlike the four
   existing events (tiny `data` — a couple of counts and timestamps),
   `session.scored` carries evidence + four stages + the full
   transcript. A 10-question interview can run to tens of KB. That
   full map is stored in `webhook_deliveries.payload` (jsonb) and
   re-encoded from the row on **every** retry (up to 14). Watch for:
   (a) ledger row bloat — the deliveries table was sized for small
   payloads; (b) receiver/proxy body-size caps. If this bites, the
   escape hatch is to carry a `scores_url` pointer instead of inline
   scores — but that breaks the "self-contained, thin-adapter,
   Pulsifi-demo parity" goal, so it's a deliberate tradeoff to make
   with data, not pre-emptively. Flagged so the size profile is
   measured during the commit #7 smoke test, not discovered in prod.
```
