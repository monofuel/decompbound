# LLM contamination envelope (llm-play / touch grass)

**Status:** awareness doc only. Nothing here is a bug to fix. We hit **n=1**
(touch grass / tg 25→100 via the LLM-play harness). This file maps **every
place prior knowledge or multi-run residue can leak into “the bot knows
EarthBound.”** Pre-training already contains a *monumental* amount of EarthBound
text; that alone swamps most of the list. We still want a full envelope so
claims about “what the agent learned” stay honest.

**n=1 field proof (real grass, not the ROM):**  
[media/IMG_20260520_201351_568.jpg](media/IMG_20260520_201351_568.jpg)

**Related:** [llm-plays.md](llm-plays.md) (harness design + what works),
[goal.md](goal.md) / project milestones.

---

## Stance

| Principle | Meaning |
|-----------|---------|
| Contamination is expected | Expert models + a famous RPG + a waypoint-rich prompt is not a blank slate. |
| Document ≠ purify | No plan to scrub models, retrain, or forbid seed Lua. |
| Pre-training dominates | Walkthroughs, maps, dialogue, fan wikis, speedrun notes, ROM-hack docs, SNES tech, BizHawk Lua culture — all sat in corpora for years. |
| Lineage matters for *local* claims | When we say “qwen wrote the door route,” check what was already in the system prompt, seed policy, skills file, and last-run notes. |
| Fine | Using contaminated agents for fun and milestones is the point of this track. |

---

## Layers (outside → inside)

Think of nested envelopes. Outer layers are largest and least controllable.

```
┌─────────────────────────────────────────────────────────────┐
│ 1. Pre-training / base model (EarthBound + Lua + SNES)     │
│  ┌───────────────────────────────────────────────────────┐  │
│  │ 2. Vendor fine-tunes / product RLHF (unknown)         │  │
│  │  ┌─────────────────────────────────────────────────┐  │  │
│  │  │ 3. This repo (docs, seeds, skills source, prompts)│  │  │
│  │  │  ┌───────────────────────────────────────────┐  │  │  │
│  │  │  │ 4. Cross-run local state (notes, skills,   │  │  │  │
│  │  │  │    last policy, rollback/saves)            │  │  │  │
│  │  │  │  ┌─────────────────────────────────────┐  │  │  │  │
│  │  │  │  │ 5. Per-request prompt (system +     │  │  │  │  │
│  │  │  │  │    rich state + prior Lua)          │  │  │  │  │
│  │  │  │  │  ┌───────────────────────────────┐  │  │  │  │  │
│  │  │  │  │  │ 6. Live game observation       │  │  │  │  │  │
│  │  │  │  │  │    (WRAM, screen text, tg%)    │  │  │  │  │  │
│  │  │  │  │  └───────────────────────────────┘  │  │  │  │  │
│  │  │  │  └─────────────────────────────────────┘  │  │  │  │
│  │  │  └───────────────────────────────────────────┘  │  │  │
│  │  └─────────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

---

## 1. Pre-training / base model knowledge

**Models in the loop (as of n=1):** Qwen (live policy writer, e.g.
`qwen3.6-27b` via local azem), plus **Claude** and **Grok** in the broader
authoring/orchestration history (harness design, seed policies, dig tools,
docs, waypoint discovery). All three “know” EarthBound in the colloquial sense:
pre-training almost certainly saw massive amounts of:

- Plot, characters, towns (Onett, Twoson, …), item/enemy names
- Walkthrough text, FAQ dumps, guide sites, forum routes
- Map and location discussion (Ness’s house → outside is textbook early game)
- SNES / 65816 / APU / PPU discourse that makes the *emulator* side legible
- Emulator scripting culture (BizHawk/mGBA Lua, memory watch, joypad APIs)
- Decomp / reverse-engineering adjacent chat (less game-specific, still useful)

**Implication:** Even with an empty system prompt and no seed Lua, a strong
model can invent plausible “go downstairs and leave the house” policies and
guess button conventions. Coordinate-level accuracy is *not* guaranteed from
pre-training alone, but high-level structure often is.

**This is the big one.** Everything below is smaller or more local, but easier
to point at in our tree and runtime.

---

## 2. Vendor fine-tunes / product behavior (opaque)

Chat products and hosted APIs may add:

- Tool-use / “write a game bot” style preferences
- Safety or style filters that change how policies are written
- Unknown continued training on public EarthBound content post-cutoff

We do not audit weights. Treat as **unknown extra contamination** on top of
base pre-training. Local Qwen on azem is “just” weights + our prompts; web
Claude/Grok sessions used while *building* the harness are a separate
lineage channel (see §3–4).

---

## 3. In-repo human + multi-model authoring (committed)

These ship in git and shape every run, including `--mock`:

| Artifact | Role | Contamination character |
|----------|------|-------------------------|
| `src/tools/llm_ai.nim` `SystemPrompt` | Explicit EarthBound goal, **hardcoded waypoints**, memory addresses, skill names, “no A while walking” | Direct route injection into every real LLM call |
| `src/tools/llm_mock_policies.nim` (`NavHousePolicy`, `ExploreOnettPolicy`, …) | Seed / mock Lua; multi-author mixture (Qwen/Claude/Grok + human iteration) | Full working route as code; becomes `LAST POLICY` after boot |
| `src/tools/touch_grass.nim` skill strings | `walkTo` / `escapeMenu` / `winBattle` / intro helpers | Re-discovered or RE-derived addresses + nav heuristics, not pure model freestyle |
| `touchGrassPercent` / room labels | Milestone metric baked from captured positions | Encodes “what outside looks like” for the *evaluator*, and labels in the slow-clock summary |
| `docs/llm-plays.md`, `docs/human-verify.md`, goal docs | Design narrative, verified coords, gotchas | If models are later trained on this repo or chat that quotes it, **second-order** contamination |
| Dig/probe tools, issues notes | Door fade, APU, logo, etc. | Not usually in the play prompt; still EarthBound-specific engineering text in-tree |

**Mixture of authors:** Current Lua and waypoint strings are **not** “pure
Qwen discovery.” They were iterated with Claude/Grok sessions, human
steering, mock-policy solidification, and then fed back as seeds and system
prompt text. Treat the committed Lua as **lineage-contaminated by construction**.

---

## 4. Cross-run local state (gitignored, durable on disk)

These survive process exit and **accumulate** across `make llm-ai` sessions:

| Path | What it carries |
|------|-----------------|
| `bin/states/llm_notes.txt` | `-- NOTE:` lines the model (or seed comments) emitted; re-injected into the next prompt as “persistent brain” |
| `bin/states/llm_skills.lua` | Skill library loaded into Lua *before* the policy; can grow over runs |
| Live policy string in process | Becomes `LAST POLICY` on the next slow tick; hot-swap keeps winning fragments |
| `bin/states/llm/*.state`, rollback | Positions and world progress; not text knowledge, but steers which observations appear |
| `bin/states/llm_ai.srm` | Battery progress for LLM-only play |

**Build-up between runs is intentional** (notes + skills + last policy) and is
exactly a **local contamination / memory** channel: later Qwen calls see
earlier Qwen (and seed) conclusions. That is not the same as pre-training, but
it *is* leakage from past episodes into the present decision.

---

## 5. Per-request prompt assembly (`llm_ai.nim`)

Every real provider call roughly includes:

1. **System prompt** — goal, waypoints, API, skills contract (§3)
2. **Rich state summary** — frame, pos, tg%, room label, battle flags, recent
   history of progress / stuck / joy
3. **Persistent notes** (trimmed for ctx) — §4
4. **Last policy Lua** (trimmed) — seed or previous model output
5. User instruction: return only `function update() … end`

So even “incremental improve” is **conditioned on** a route that already works
or almost works. Measuring pure exploration would require ablating 1 and 4
(and usually 3).

Context trim (`trimForLlm`) reduces tokens; it does **not** remove the
contamination categories — it only drops older middle of notes/policy.

---

## 6. Live game observation (the “legitimate” channel)

These are what a player-like agent is *supposed* to use:

- WRAM reads (`mem.read`, player X/Y, battle flag, …)
- `screen.text()` (dialogue, menus, battle UI strings — **game text**, copyrighted
  content at runtime, not committed)
- Frame count, stuck detection, joy feedback
- Optional PNGs if enabled (not the main n=1 path)

**Caveat:** Observation is clean *as a channel*, but the **interpretation
scaffolding** (which addresses mean player pos, what tg% means, that “Bash”
means battle) is still harness/pre-training contaminated. The agent does not
discover the SNES joypad map or the party-leader entity slot from photons
alone.

---

## 7. Orchestration / human-in-the-loop (meta)

Outside the closed `llm_ai` loop:

- Conductor agents (Claude/Grok) choosing seeds, editing `NavHousePolicy`,
  writing probes, updating docs
- Human verifying in `make play` / `make llm-ai` and feeding back “black door,”
  “wrong Belch save,” etc.
- Mock mode (`--mock`) proving tg=100 **without any live model call** — success
  can be 100% seed contamination by design

n=1 “LLM goals achieved” means the **system** (harness + seeds + optional live
model + persistence) can leave the house. It does **not** mean a cold model
with zero prompt engineered a route from blank Lua.

---

## 8. Future / second-order (if anyone scrapes us)

If this repository or chat logs become training data later:

- Committed waypoints and skill Lua become **explicit** EarthBound bot recipes
- Contamination docs (this file) ironically become meta-training signal
- Runtime notes files are usually gitignored — less likely to ship, still on
  developer machines

Not actionable now; listed so the envelope is complete.

---

## What we are *not* claiming

- That Qwen “solved EarthBound” from visual pixels alone
- That seed Lua is model-pure or human-pure (it is mixed)
- That pre-training is small relative to our notes file (it is not)
- That contamination invalidates n=1 as a harness milestone (it does not)

## What n=1 *does* claim

- The two-clock sandbox works end-to-end
- Metrics (`tg_pct`), skills, notes, load-state isolation, and async watch are
  real engineering
- A policy (seed and/or model-revised) can drive joypad input from bedroom
  fixture to outdoor Onett band under our emulator
- We can see and name the knowledge sources that made that easy

---

## Quick reference: sources ranked by “how much EarthBound route they give away”

| Rank | Source | Route specificity |
|------|--------|-------------------|
| Highest | Pre-training on EarthBound + walkthroughs | High-level path, names, tropes |
| Highest (local) | `SystemPrompt` waypoints + `NavHousePolicy` | Exact hex targets for house exit |
| High | `llm_skills.lua` / `touch_grass` skills | Navigation primitives + battle heuristics |
| High | `LAST POLICY` + `llm_notes.txt` across runs | Frozen discoveries from prior episodes |
| Medium | Rich state labels (`bedroom`, `tg=75`, …) | Tells the model *where it is* in our ontology |
| Medium | Multi-model authoring history of the above | Shared “what worked” across vendors |
| Lower | Live WRAM/screen alone without addresses | Needs scaffolding to be actionable |
| Opaque | Vendor fine-tunes | Unknown |

---

## If we ever measure “learning” carefully (optional future)

Not a task list — only what an experiment would have to control:

1. Freeze or empty notes/skills; disable last-policy echo
2. Strip waypoints from system prompt (API-only contract)
3. Start from blank `function update() end` or random buttons
4. Compare models / temperature / no-seed ablations
5. Report pre-training as an uncontrolled confounder anyway

Until then: **be aware, enjoy the grass, do not pretend the slate was blank.**

---

## Changelog

- **2026-07-08:** Initial envelope after n=1 touch-grass achievement; multi-model
  Lua lineage + persistence channels documented explicitly.
