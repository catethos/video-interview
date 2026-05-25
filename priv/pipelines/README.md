# Scoring pipeline bundle

The versioned scoring pipeline artifact, shipped with the code so the
`.lat` logic is pinned to the release that runs it.

## Layout

```
priv/pipelines/
├── topology.json                          ← hand-authored DAG (the wiring)
└── smoke_test_Pipeline_2_2026-05-25-0423/ ← the bundle (lattice logic only)
    └── stages/
        ├── 01_VI_P1_Classify_v1/lattice.lat
        ├── 02_VI_P5_Aggregate_v2/lattice.lat
        ├── 03_VI_P2_Extract_Evidence_v1/lattice.lat
        ├── 04_VI_P4_Layer_2_Scoring_v2_per-question/lattice.lat
        └── 05_VI_P3_Layer_1_Scoring_v2_per-question/lattice.lat
```

## What's here, and what was deliberately left out

The bundle exported from the lattice playground also contained
`pipeline.json`, per-stage `output.json` files, and `sample_input/input.csv`.
**Those were not committed**: they embed a real smoke-test candidate's data
(email, identifier, transcript). Only the `.lat` files are kept — they are
pure pipeline logic (prompts + type definitions + env-var *names* such as
`OPENROUTER_API_KEY`; no secrets, no candidate data).

## topology.json — the wiring

The bundle's own `pipeline.json` does not encode how stages feed each other
(its `edges` are empty). `topology.json` is the hand-authored DAG, mirroring
the reference runner in `pulsifi-demo`
(`apps/backend/src/modules/scoring/topology.ts`).

Each stage declares the globals it `binds` and the `output_label` it
produces. A bind is either a bare label (`"input_data"`) or `"from:as"`
(`"p4_results:input_data"` binds the global `p4_results` under the runtime
name `input_data`). Stages are listed in topological order.

Dependency graph:

```
p1 ← input_data                      → p1_results   (classification; cached per template version)
p2 ← input_data                      → p2_results   (evidence extraction)
p3 ← input_data, p2_results          → p3_results   (layer-1 scoring, per question)
p4 ← input_data, p1_results, p2_results → p4_results (layer-2 scoring, per question)
p5 ← p4_results (as input_data), p3_results → p5_results (aggregate)
```

`pipeline_version` is the string the scoring cache keys on and the webhook
emits. Bumping the pipeline = new bundle dir + new `pipeline_version` here.

### Note on stage directory numbers

The directory prefixes (`01`…`05`) are bundle build order, **not** logical
P-order, and they differ between bundles. In this 2026-05-25 bundle,
`04_…` is P4 and `05_…` is P3 — the reverse of the older pulsifi-demo
bundle. `topology.json` maps each stage by its **label**, so the `lat` paths
are correct here; do not assume `04` = P3 from another bundle.
