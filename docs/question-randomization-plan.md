# Question randomization — design

> Goal: let a recruiter opt a template version into **randomized question
> order**. When on, each candidate sees the questions in their own random
> sequence in the capture iframe (candidate X: `[A, C, B]`, candidate Y:
> `[C, B, A]`), while the **canonical template order** (`A, B, C`) is what
> drives scoring and what the recruiter sees in the report. The per-candidate
> order is recorded and surfaced in the recruiter debug panel for
> transparency.

## Why this is small

The recruiter report (`Playback.load_question_cards/2`) and the scoring
export (`ExternalIntegration.ScoringExport`) **already order strictly by
`template_question.position`** — nothing downstream depends on the order a
candidate happened to see. So "doesn't affect scoring" and "report shows the
default order" come for free. The only thing that must change is **the order
the candidate is shown**, plus recording that order. Canonical order stays the
single source of truth everywhere it matters.

## Scope (v1)

In scope:
- `randomize_questions` flag on the template **version** (frozen, recruiter
  checkbox).
- A per-session, frozen `display_order` on `session_questions`, shuffled once
  at session creation when the flag is on.
- Candidate capture flow driven by `display_order`.
- Recruiter debug panel shows each candidate's shown order.

Explicitly out of scope:
- Pinning specific questions to fixed slots (e.g. "always ask Q1 first").
  Design leaves room (shuffle a subset), but no UI for it in v1.
- Randomizing answer options / anything within a question.
- Re-randomizing an in-flight session.
- Group/section-aware shuffling.

## Data model

**`interview_template_versions.randomize_questions`** — `boolean`, NOT NULL,
default `false`. Frozen with the version, exactly like `retake_policy`. Add
to `Interview.Templates.Version` schema + changeset cast.

**`session_questions.display_order`** — `integer`. The candidate's
1-based position for that question in *this* session. `position` (already
present, = `template_question.position`) stays the canonical order and is
untouched. Add to `Interview.Capture.SessionQuestion` schema + changeset.

```elixir
# migration 1
alter table(:interview_template_versions) do
  add :randomize_questions, :boolean, null: false, default: false
end

# migration 2
alter table(:session_questions) do
  add :display_order, :integer
end
```

`display_order` is nullable in the column (back-compat for any existing rows)
but always populated for new sessions; readers fall back to `position` when
it's nil.

## The shuffle — once, at session creation

`Capture.ensure_session_questions/1` already inserts one `session_questions`
row per template question, with `position: q.position`. It is idempotent
(inserts only if the session has none yet), so this is the single, well-defined
moment to fix the order.

Change: load the session's template version; if `randomize_questions` is true,
`Enum.shuffle/1` the questions and assign `display_order = 1..N` in the
shuffled order; otherwise `display_order = position`. Because the rows are
written once and never reshuffled, the order is **frozen** — refresh, resume,
and `:fenced` recovery all show the same sequence.

```elixir
ordered =
  if version.randomize_questions, do: Enum.shuffle(questions), else: questions

rows =
  ordered
  |> Enum.with_index(1)
  |> Enum.map(fn {q, display_order} ->
    %{session_id: ..., template_question_id: q.id, position: q.position,
      display_order: display_order, ...}
  end)
```

(A future pinned/practice question keeps its fixed slot — shuffle only the
rest. Not built in v1.)

## Candidate capture flow — driven by `display_order`

This is smaller than it first looks. `capture_live.ex` navigates by
`current_question = Enum.at(questions, current_index)` and advances with
`current_index + 1` — pure index into the assigned `questions` list. The
capture fence sends `questionIndex: q.position` and resolves it with
`fetch_question_by_position/2`, but `q.position` is **intrinsic to the
question**, not its slot — so it keeps resolving correctly no matter the
display order.

So the core change is one line: build the `questions` list in **display
order** instead of template order.

- New context fn `Capture.list_questions_in_display_order/1` — joins
  `session_questions` (ordered by `coalesce(display_order, position)`) to
  `template_question`, returning the template `%Question{}`s in the
  candidate's order. `capture_live` mount uses this instead of
  `list_questions/1`. `ensure_session_questions/1` already runs immediately
  before, so the order exists.
- Each captured answer is still tied to its `template_question`
  (`response.template_question_id`), so the question's identity — and
  therefore scoring, report, retake tracking, and the fence — is independent
  of which slot it was shown in.

**Candidate-facing numbering.** The recording screen already shows
`Question {current_index + 1} of {total}` — a *display* index — so it's
correct under randomization with no change. The **review screen** is the one
exception: it numbers the list by `q.position` (the template number), which
would read out of order (`Q03, Q01, Q02`) and leak the template order. Fix:
number it by the display ordinal (`Enum.with_index/2`) to match the recording
screen. Net: candidates always see a clean sequential `1..M` in the order they
were shown; no template numbers leak.

When the flag is off, `display_order` is assigned in template order, so the
sequence is identical to today: **zero behavioural change in the default
case.**

## Recruiter UI

A single checkbox in the template-version editor
(`recruiter_template_live.ex`): *"Randomize question order for each
candidate."* Bound to `version.randomize_questions` on the draft; frozen at
publish like every other version setting.

## Scoring + recruiter report — unchanged

- `ScoringExport` builds `interview_transcript` ordered by
  `template_question.position` → the pipeline (and the `session.scored`
  webhook) always sees canonical `A, B, C`. No scoring code touched.
- `Playback.load_question_cards/2` orders by `template_question.position` →
  the recruiter report shows `A, B, C` for every candidate.

## Debug panel — show the shown order (#8)

The recruiter session detail (`recruiter_session_live.ex`) has a debug
expander. Add a line listing each candidate's actual shown order, e.g.
`Shown order: C, A, B`, derived from `session_questions.display_order`. The
main report stays canonical; this is transparency/audit only.

## Edge cases

| Case | Behaviour |
|---|---|
| Flag off (default) | `display_order = position`; identical to today |
| Refresh / resume / `:fenced` recovery | recorded order → same sequence |
| Retakes | per-response; the question's slot is fixed |
| Published version | flag is per-version & frozen; existing sessions keep their recorded order, new ones shuffle |
| 1 question | shuffle is a no-op |
| Legacy session_questions rows (null display_order) | readers `coalesce(display_order, position)` |

## File-by-file

New:
- `priv/repo/migrations/<ts>_add_randomize_questions_to_versions.exs`
- `priv/repo/migrations/<ts+1>_add_display_order_to_session_questions.exs`

Changed:
- `lib/interview/templates/version.ex` — field + cast.
- `lib/interview/capture/session_question.ex` — field + cast.
- `lib/interview/capture.ex` — `ensure_session_questions/1` (shuffle) +
  `list_questions_in_display_order/1`.
- `lib/interview_web/live/capture_live.ex` — build the `questions` list from
  `list_questions_in_display_order/1`; number the review screen by display
  ordinal (`Enum.with_index/2`) instead of `q.position`.
- `lib/interview_web/live/recruiter_template_live.ex` — the checkbox.
- `lib/interview_web/live/recruiter_session_live.ex` — "Shown order" line in
  the debug panel.

## Tests

- `Version.changeset` casts `randomize_questions`.
- `SessionQuestion.changeset` casts `display_order`.
- `ensure_session_questions`: flag off → every `display_order == position`;
  flag on → `display_order` is a permutation of `1..N`; second call does **not**
  reshuffle (idempotent).
- `list_questions_in_display_order` returns questions in `display_order`.
- `capture_live` serves questions in the session's `display_order`; the review
  screen numbers by display ordinal (not `q.position`).
- **Isolation:** for a randomized session, `ScoringExport.build/2` and
  `Playback.get_session/2` still return canonical (`template_question.position`)
  order — the keystone test that proves scoring/report are unaffected.

Randomness in tests: assert the result is a valid permutation (and, for the
"different candidates may differ" property, assert validity rather than a
specific shuffle to avoid flakiness).

## Rollout

Single feature branch. Commit boundaries:
1. Migrations + schema fields (`randomize_questions`, `display_order`).
2. `ensure_session_questions` shuffle + `list_questions_in_display_order` +
   context tests.
3. Capture flow wired to display order + tests.
4. Recruiter checkbox.
5. Debug-panel shown-order line.
6. Isolation test (scoring/report stay canonical) + manual cross-browser pass.

Each commit passes `mix test`, `mix format`, `mix precommit` clean.
