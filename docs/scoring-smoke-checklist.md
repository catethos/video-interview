# Scoring end-to-end smoke checklist (commit #7)

> Goal: the first time the **real** lattice runtime actually runs. Everything
> up to here is unit-tested against a stub (`PipelineRunnerStub`); this is the
> only step that exercises `Interview.Scoring.PipelineRunner.Lattice` — real
> LLM calls, real DuckDB, real NIF. We're confirming the live pipeline
> produces a `session.scored` payload that matches
> `docs/scoring-webhook-contract.md` §4.

Two paths. Do **Path B first** — it isolates the new scoring code (no video,
no Whisper), so a failure points squarely at the pipeline. Then Path A for
full confidence.

## 0. Prerequisites

- Postgres up; `mix deps.get` done; migrations applied (`mix ecto.migrate`).
- **`OPENROUTER_API_KEY`** exported in the shell *before* starting iex — every
  P1–P5 stage's `.lat` calls OpenRouter (`api_key_env: "OPENROUTER_API_KEY"`).
  Without it the runner returns an auth error and the worker discards.
  (`OPENAI_API_KEY` is only needed for Path A's Whisper transcription, and for
  the pipeline's QA metrics — which `RunBatch` does **not** run.)
- The lattice NIF downloaded on first compile (it did, on this Mac:
  `aarch64-apple-darwin`). If you're on a different machine, `mix compile` will
  fetch the matching prebuilt binary.
- Seeds: `mix run priv/repo/seeds.exs` (creates the `dev` tenant + a published
  template/version + one question).

```bash
export OPENROUTER_API_KEY=sk-or-...
mix ecto.migrate
mix run priv/repo/seeds.exs
```

---

## Path B — scoring-isolated smoke (recommended first)

Seeds a finalized session with **canned transcripts** (skips video + Whisper),
then runs scoring directly and inspects the payload.

Start a console with the app running:

```bash
iex -S mix
```

Paste this block (adjust the candidate transcript text if you like):

```elixir
import Ecto.Query
alias Interview.Repo
alias Interview.Capture.{Session, Response, SessionQuestion}
alias Interview.Templates.{Template, Version, Question}
alias Interview.Tenants.Tenant

tenant  = Repo.get_by!(Tenant, slug: "dev")
version = Repo.get_by!(Version, template_id: Repo.get_by!(Template, tenant_id: tenant.id, name: "Dev Template").id, version_number: 1)
questions = Repo.all(from q in Question, where: q.template_version_id == ^version.id, order_by: q.position)

# A finalized session carrying the consumer-supplied job context.
{:ok, session} =
  %Session{}
  |> Session.changeset(%{
    tenant_id: tenant.id,
    template_version_id: version.id,
    candidate_email: "smoke@example.com",
    external_id: "smoke-app-1",
    state: "ready",
    job_role: "Management Trainee - Data",
    job_description: "Drives data projects across functions under deadline.",
    completed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  })
  |> Repo.insert()

now = DateTime.utc_now()

for q <- questions do
  {:ok, r} =
    %Response{
      session_id: session.id,
      template_question_id: q.id,
      attempt_number: 1,
      state: "ready",
      storage_key: "smoke/#{q.id}.mp4",
      duration_ms: 60_000,
      transcript_text:
        "At Everdy Insurance I had three complex Excel tasks due in three days, " <>
          "so I built VBM macros to automate them and finished on time; the pricing " <>
          "team later adopted the tool.",
      transcript_provider: "smoke",
      transcript_ready_at: now
    }
    |> Repo.insert()

  {:ok, _} =
    %SessionQuestion{
      session_id: session.id,
      template_question_id: q.id,
      position: q.position,
      selected_response_id: r.id
    }
    |> Repo.insert()
end

# Gate check — must be true, else scoring won't fire.
true = Interview.Scoring.eligible_for_scoring?(session.id)

# THE REAL RUN. This makes live LLM calls (~10–60s).
{:ok, data} = Interview.Scoring.score_session(session.id)
IO.inspect(data, label: "session.scored data", limit: :infinity, printable_limit: :infinity)
```

### What to verify in `data` (against contract §4)

- [ ] `data["pipeline_version"] == "smoke_test_Pipeline_2_2026-05-25"`.
- [ ] `data["scored_at"]` is an ISO-8601 string.
- [ ] `data["classifications"]` is a **list**, one entry per question, each with
      `question_number`, `question_type`, `target_constructs` (a list), and the
      rationale fields. **Decoded JSON** — not a string.
- [ ] `data["pipeline_outputs"]["p2"]["question_evidences"]` is a list.
- [ ] `data["pipeline_outputs"]["p3"]` is an **array, one per question**, each
      carrying `question_number` + `clarity_coherence` / `relevance_completeness`
      / `support_quality`, each a `%{"score" => int, "justification" => str}`.
- [ ] `data["pipeline_outputs"]["p4"]` is an array per question, each with
      `question_number` + `layer2_scores`.
- [ ] `data["pipeline_outputs"]["p5"]` has `overall_insights` (list) +
      `question_level_evaluation` (list).
- [ ] `data["interview_transcript"]` mirrors the export (question_number,
      question_text, answer_text, response_id, duration_ms, focus_lost_*).
- [ ] `template_classifications` now has exactly **one** row for this version:
      `Repo.aggregate(from(c in Interview.Scoring.TemplateClassification, where: c.template_version_id == ^version.id), :count)`.

### First-run risk watch (this is new ground)

These are the assumptions only the live run can confirm:

- [ ] **`PipelineRunner.Lattice` return shapes.** The code assumes
      `Lattice.new/1 → {:ok, rt}`, `eval/2 → {:ok, _}`, `call/3 → {:ok, rows}`.
      If any returns a bare value or a different tuple, the runner's `with`
      chain will surface it — fix the adapter to match.
- [ ] **p3/p4 carry `question_number` live.** We verified this from the bundle's
      `ProcessData` SELECT; confirm the live `RunBatch` rows really include it
      (if `question_number` is `nil` in the p3/p4 entries, the runner must
      attach it by position — contract §12.6).
- [ ] **`decode_maybe/1` is doing the right thing.** If the score fields come
      back as already-decoded maps (not JSON strings), `decode_maybe` passes
      them through untouched — fine. Just confirm no field is a double-encoded
      string in the final payload.

### Then exercise the worker + webhook

Point the tenant at a real receiver so you see the actual POST + signature
(use a throwaway https://webhook.site bin), then enqueue the worker:

```elixir
{:ok, tenant} =
  Repo.get_by!(Tenant, slug: "dev")
  |> Tenant.changeset(%{webhook_url: "https://webhook.site/<your-bin-id>", webhook_secret: "smoke-secret"})
  |> Repo.update()

{:ok, _job} = %{session_id: session.id} |> Interview.Workers.ScorePipeline.new() |> Oban.insert()
Process.sleep(60_000)  # let the run + delivery finish

Repo.get_by(Interview.Scoring.SessionScore, session_id: session.id)             # status "ready"
Repo.get_by(Interview.Webhooks.Delivery, session_id: session.id, event_type: "session.scored")  # state "delivered"
```

- [ ] `session_scores` row: `status == "ready"`.
- [ ] `webhook_deliveries` row for `session.scored`: `state == "delivered"`,
      `last_status == 200`.
- [ ] At webhook.site: the **envelope** (`v`, `type: "session.scored"`,
      `tenant_id`, `session_id`, `external_id`, `occurred_at`, `delivered_at`)
      and the five headers (`X-Interview-Event`, `X-Interview-Delivery-Id`,
      `X-Interview-Signature: sha256=…`, …).
- [ ] **Verify the signature** holds (contract §6):
      `"sha256=" <> (:crypto.mac(:hmac, :sha256, "smoke-secret", raw_body) |> Base.encode16(case: :lower))`
      equals the `X-Interview-Signature` header.

### Cost-guard + cache checks

- [ ] **No double-run:** enqueue the same session again → the worker returns
      `:ok` immediately (already-scored short-circuit), no new LLM calls, no
      second `session.scored` delivery row.
- [ ] **P1 cache reuse:** seed a *second* session on the **same version** (new
      candidate, different transcript) and score it. It must reuse the one
      cached classification — `template_classifications` stays at **1 row**, and
      P1 makes **no** new LLM call (watch latency / OpenRouter usage). This is
      the fairness + cost win.

## Path A — full end-to-end (after Path B passes)

Confirms the real candidate → Whisper → scoring chain.

1. Both keys exported: `OPENROUTER_API_KEY` **and** `OPENAI_API_KEY` (Whisper).
2. `mix phx.server`; the talent-app / harness creates a session via
   `POST /api/sessions` **including `job_role` + `job_description`** (the new
   passthrough fields).
3. Record an answer per question through the capture UI; submit.
4. Finalizers land → `session.ready` fires → `ScorePipeline` enqueues. It will
   **snooze (≈30s loops)** until Whisper finishes each transcript — expected.
5. Once transcripts are in, the worker runs the pipeline and delivers
   `session.scored`. Verify the same checklist as Path B.

## Failure-path smoke (optional but worth it)

Force a stage error and confirm the failure event:

1. Start iex with a **bad** `OPENROUTER_API_KEY` (so P1/stages return an auth
   error), seed a session as in Path B.
2. Run the worker on its final attempt:
   `perform`-style — easiest via `Oban`: enqueue and let it retry to
   exhaustion, **or** in iex call the worker with a maxed attempt. Expect:
   - [ ] `session_scores` row `status == "failed"`, `error_reason` set.
   - [ ] a `session.scoring_failed` delivery whose `data` has
         `pipeline_version`, `stage`, `reason`, `message`, `attempts` (§5).
   - [ ] for `missing_api_key` / `unauthorized` specifically: the job is
         **discarded** (operator-config fault) and **no** failure webhook fires
         — fix the key, not the consumer.

## Teardown

Smoke rows are dev-only. Drop them when done:

```elixir
Repo.delete_all(from s in Interview.Capture.Session, where: s.candidate_email == "smoke@example.com")
# cascades clean up responses, session_questions, session_scores, deliveries.
# Reset the dev tenant's webhook_url if you don't want it pointing at webhook.site.
```

## Sign-off

- [ ] Path B payload matches the contract field-by-field.
- [ ] Worker writes the receipt + delivers `session.scored` (signature valid).
- [ ] P1 cache reused across two candidates on one version (1 row, no 2nd call).
- [ ] (optional) Failure path delivers `session.scoring_failed`.

Once these pass, the VI side is production-real and commit #8 (Pulsifi-demo
consumer + JS retirement) can proceed against a live `session.scored`.
