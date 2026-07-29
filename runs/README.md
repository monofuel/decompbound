# runs/ — eval scorecards (committed history)

Each `make eval` writes `runs/<utc>-<idea>/scorecard.json` (autoresearch
schema v0). **The history is the product**: discarded runs stay here with
their reason codes; never delete failed points.

**Asset-free rule (enforced by the writer, `src/tools/eval_scorecard.nim`):**
scorecards hold percents, frames, reason codes, and commit hashes only.
String values are token-shaped (no whitespace), which mechanically blocks
dialogue text or any game content. Logs with transcripts are gitignored
(`runs/**/logs/`); anything with game content lives in `decompbound_secret`
and is referenced by opaque path only.

Contract + design: `docs/EVAL.md`, `docs/autoresearch-llm-play.md`.
