# LLM contamination envelope (llm-play / touch grass)

**Status:** awareness doc only. Nothing here is a bug to fix. We hit **n=1**
(touch grass / tg 25→100 via the LLM-play harness) and **n=2** (pokey_pct
0→100, 2026-07-10). This file maps **every place prior knowledge or multi-run
residue can leak into “the bot knows EarthBound.”** Pre-training contains a
huge *volume* of EarthBound text — but see §1a: measured fidelity of that
knowledge is **much lower than we first assumed**. We still want a full
envelope so claims about “what the agent learned” stay honest.

**n=1 field proof (real grass, not the ROM):**  
[media/IMG_20260520_201351_568.jpg](media/IMG_20260520_201351_568.jpg)

**Related:** [llm-plays.md](llm-plays.md) (harness design + what works),
[llm-sequence.md](llm-sequence.md) (story percent ladder / Sunrise MVP),
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

**This is the big one by volume.** Everything below is smaller or more local,
but easier to point at in our tree and runtime. However — see §1a: volume is
not fidelity.

---

## 1a. Measured fidelity: pre-training knowledge is worse than expected (2026-07-10)

Empirical finding (monofuel, probing cloud web interfaces of **Claude Fable**
and **Grok** about specific game events): both returned **significantly wrong
answers about key story elements**. Not fuzzy-but-close — confidently wrong.

Revision to the envelope: pre-training contamination is **high-volume,
LOW-fidelity**. Models carry EarthBound *vibes* — town names, tropes,
“meteor at the start,” character archetypes — with confabulated specifics
underneath. The suspected training contamination on actual route/story detail
is **less than this doc originally assumed**, and that is valuable knowledge:

- **Confident confabulation is worse than ignorance.** This project has paid
  for it twice already: the *Picky-graded-as-Pokey* bug (an agent “knew” Pokey
  lives next door and steered the metric to the wrong character indoors) and
  the phantom *“walk straight north to the meteor”* route (the real route is
  south → west road → western climb → ridge, proven by human TAS replay).
  Both were model-memory errors that only ground truth corrected.
- **Consequence for method:** never trust model memory for story facts.
  Verify against the game itself — WRAM diffs, disasm, replayed human play.
  The project’s ground-truth doctrine is not just engineering hygiene; it is
  the correct epistemics for working alongside models that misremember the
  game.
- **Consequence for claims:** “the model knows EarthBound” overstates what
  pre-training delivers. What it delivers is a prior that *sounds* right.

---

## 2. Vendor fine-tunes / product behavior (an ACTIVE distortion channel)

Chat products and hosted APIs add:

- Tool-use / “write a game bot” style preferences
- Safety or style filters that change how policies are written — **and can
  refuse, moralize, or warp analysis of legitimate game content** (see §2a)
- Unknown continued training on public EarthBound content post-cutoff

We do not audit weights. Originally this doc treated layer 2 as “unknown extra
contamination.” Revision (2026-07-10): it is an **active distortion channel**,
not a passive knowledge source — filters subtract and bend, they don’t just
add.

**Every model has a filter geometry, including local ones.** A Claude-family
conductor once described local Qwen on azem as “the least-filtered lane” —
which is itself a model’s-eye assumption worth pinning here as a meta-example:
Qwen ships its own alignment layer, tuned along axes a different vendor’s
model doesn’t perceive. The honest statement is **differently-filtered and
unverifiable**, for every model in the loop. Web Claude/Grok sessions used
while *building* the harness are additionally a separate lineage channel
(see §3–4).

---

## 2a. Safety-filter contamination: benign 1994 content that trips filters (2026-07-10)

EarthBound is a cult classic from 1994 full of Itoi’s “edgy” Japanese humor —
totally transparent to a human (a 13-year-old played it fine), but stripped of
context it pattern-matches to content-policy categories. Field-observed on
cloud web AIs, and plausibly **increasing over time** while the game stays
exactly as harmless as it was in 1994.

Known trip-points (what the game means → what a filter sees):

| Game beat | In-game reality | Decontextualized pattern |
|-----------|-----------------|--------------------------|
| **Captain Strong** | Scripted story battle: brawl the Onett police force in the station, then the chief | Violence against police |
| **Bad Key Machine** | Goofy gadget that opens locked doors | Burglary / lockpicking tool |
| **Magic Cake** | Eat a stranger’s cake → long psychedelic vision (Poo’s Mu training) | Drug-coded edible |

Certainly more ahead (non-exhaustive): the **Happy Happy cult** (kidnapping
Paula, indoctrination, mass blue-painting), **Pokey’s household** (domestic
abuse played for laughs), **Everdred / the Sharks** (theft, gangs),
**Moonside** (full hallucination sequence), the coffee/tea trip scenes, zombie
Threed, and the **Giygas finale** — 25 years of “most disturbing final boss”
fan discourse sits in every model’s pre-training, so the ending may be the
twitchiest content of all.

**Mindfulness rules (not fixes — habits):**

- Keep the framing explicit anywhere a hosted model touches story content:
  *“scripted battle vs the NPC ‘Captain Strong’ in the 1994 SNES RPG
  EarthBound”* — never let a decontextualized phrase stand alone in a ticket,
  prompt, or `screen.text()` excerpt.
- Expect refusal/moralizing to show up as *subtle analysis distortion*, not
  just hard refusals — a worker that soft-pedals a story beat produces wrong
  RE conclusions.
- It’s just a game. When a filter and a human disagree about 1994 cartoon
  content, the human is right; route around (rephrase with context, use a
  different lane) rather than argue.

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
| `followTrail` + `PokeyVisitPolicy` trail waypoints (2026-07-10) | The pokey_pct route as an ordered coordinate trail, extracted from monofuel’s recorded TAS play | **Human-demonstration contamination** — a distinct channel: not model memory, not model discovery, but the human’s actual playthrough injected as data. Maximal route giveaway by design; also the *ground truth* that corrected model confabulation (§1a) |

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
| Highest (local) | Human TAS trail → `followTrail` / seed waypoints | Exact pixel corridor + Pokey coords — the whole route, by design |
| Highest (local) | `SystemPrompt` waypoints + `NavHousePolicy` | Exact hex targets for house exit + pokey ladder |
| High | `llm_skills.lua` / `touch_grass` skills | Navigation primitives + battle heuristics |
| High | `LAST POLICY` + `llm_notes.txt` across runs | Frozen discoveries from prior episodes |
| Medium (demoted 2026-07-10) | Pre-training on EarthBound + walkthroughs | Tropes and names: high **volume**; story/route specifics: **measured LOW** — confidently wrong on probing (§1a) |
| Medium | Rich state labels (`bedroom`, `tg=75`, …) | Tells the model *where it is* in our ontology |
| Medium | Multi-model authoring history of the above | Shared “what worked” across vendors |
| Lower | Live WRAM/screen alone without addresses | Needs scaffolding to be actionable |
| Opaque, distorting | Vendor fine-tunes + safety filters | Unknown knowledge; **active subtraction/bending** on benign game beats (§2a) |

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

- **2026-07-10:** Fidelity + filter revision after n=2 (pokey_pct 0→100).
  §1a: cloud Claude Fable + Grok probed on story events — significantly wrong
  answers from both; pre-training demoted to high-volume/LOW-fidelity
  (confident confabulation; Picky-as-Pokey and phantom-north-route incidents
  cited). §2/§2a: vendor layer re-characterized as an active distortion
  channel; safety-filter trip-points documented (Captain Strong, Bad Key
  Machine, Magic Cake, more ahead); “every model has a filter geometry,
  including local Qwen” meta-example pinned. §3: human-demonstration channel
  added (TAS trail → followTrail — maximal contamination by design, and the
  ground truth that corrects model memory).
- **2026-07-08:** Initial envelope after n=1 touch-grass achievement; multi-model
  Lua lineage + persistence channels documented explicitly.
