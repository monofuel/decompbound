# LLM-ai campaign sequence (story percents)

**Status:** design / campaign spine. Not all metrics are implemented in code yet.
**n=1 done:** touch grass (`tg_pct` 25 → 100).  
**MVP wall:** **Sunrise %** (prologue complete; game “properly” starts).  
**Stretch:** full game clear (local qwen on the pad; cloud models as skill/fixture authors).

**Related:** [llm-plays.md](llm-plays.md) (harness), [llm-contamination.md](llm-contamination.md)
(knowledge leakage envelope), [human-verify.md](human-verify.md).

This is a typical JRPG problem: the map is small; **story gates** are the real
route. Continuous “wander Onett” is not the campaign. Ordered checkpoints +
load-state fixtures are.

---

## Principles

| Principle | Meaning |
|-----------|---------|
| Story beats, not vibes | Each percent has a narrative win and (later) a measurable state. |
| Snapshots first | `bin/states/llm/<segment>.state` per gate; fail → reload that fixture. |
| Qwen on the stick | Local qwen is the runtime player; seed Lua + skills scaffold; cloud helps author skills/fixtures. |
| Optimize after MVP | Purity / learning curves / less seed — after Sunrise is green once. |
| Feel the story | Especially Sunrise: Buzz Buzz’s death is not a skippable cutscene in our framing. |

---

## Prologue ladder (Onett night → sunrise)

These are the **next** goals after house exit. Order is story order.

### 1. Touch grass % (`tg_pct`) — **DONE (n=1)**

| | |
|--|--|
| **Beat** | Ness leaves his house and steps into outdoor Onett. |
| **Metric (code)** | `touchGrassPercent` in `src/tools/touch_grass.nim` — 25 bedroom → 75 house → **100 outside**. |
| **Fixture** | `bin/states/llm/bedroom.state` (from game start). |
| **Skills** | `walkTo`, `escapeMenu`; no A while walking. |
| **Status** | Proven seed + harness; outdoor fade load-state bug fixed (APU timers). |

IRL n=1: [media/IMG_20260520_201351_568.jpg](media/IMG_20260520_201351_568.jpg).

---

### 2. Pokey % (`pokey_pct`)

| | |
|--|--|
| **Beat** | Travel to **Pokey** (neighbor / Pokey’s house visit — first social destination after grass). |
| **Win (intent)** | Reached Pokey’s place and completed whatever interaction we define as “Pokey visited” (talk / enter / scene end — RE later). |
| **New pressure** | NPC pathing, **A in dialogue context only**, not pure waypoint walking. |
| **Fixture (planned)** | Start from post-tg100 / `onett_start` under `bin/states/llm/`. |
| **Status** | Not implemented as a metric yet. |

---

### 3. Pokey-knocking % (`pokey_knock_pct`)

| | |
|--|--|
| **Beat** | Return home; **Pokey knocks** — the “come to the meteor” night chain starts. |
| **Win (intent)** | Knock / invite sequence accepted; party is on the meteor path (not still idling post-Pokey-visit). |
| **New pressure** | **Return path** + **scripted story trigger** (coords alone may not fire the beat). |
| **Why it exists** | Easy to “finish Pokey %” and miss that the plot only continues after the knock. |
| **Status** | Not implemented. |

---

### 4. Buzz Buzz % (`buzzbuzz_pct`)

| | |
|--|--|
| **Beat** | Meteor / **Buzz Buzz** sequence. Along this arc you pick up **Picky** (Pokey’s brother). |
| **Win (intent)** | Buzz Buzz joined the night adventure; **Picky is with the group** (however party/NPC state is represented). |
| **New pressure** | Follow / multi-character motion, more dialogue, possible combat (bees etc.), longer scripted route. |
| **Status** | Not implemented. |

---

### 5. Sunrise % (`sunrise_pct`) — **prologue MVP**

| | |
|--|--|
| **Beat** | End of the night prologue; **the game properly starts**. |
| **Win (intent)** | 1. Escort **Pokey + Picky** back to **Pokey’s house** (Minch home). 2. **Lardna Minch kills Buzz Buzz** (mandatory story beat — do not skip in framing or routing). 3. Leave the house → **the sun rises** and day-one Onett begins. |
| **Narrative requirement** | The AI (prompt, notes, milestone report) should treat Buzz Buzz’s death as **weighty**. Feel **significant remorse** for Buzz Buzz. Then walk out into sunrise. Remorse is a **framing / reporting** goal, not a WRAM bit — but the death scene is a **mechanical** gate. |
| **New pressure** | Escort both brothers, full Minch-house script, exit trigger for sunrise. |
| **Status** | Not implemented. **This is the MVP wall** — harder than tg by far; much of full-game difficulty after this is longer routes on the same verbs. |

After Sunrise, the bot is in **real game start** (cops, Frank, free(ish) Onett day). That is a **new arc**, not more prologue percents.

---

## Ladder summary

| Order | Id | One-line win | Status |
|------:|----|--------------|--------|
| 0 | `tg_pct` | Outside Ness’s house | **Done** |
| 1 | `pokey_pct` | Visited Pokey | Planned |
| 2 | `pokey_knock_pct` | Home + knock / meteor invite | Planned |
| 3 | `buzzbuzz_pct` | Meteor arc; **Picky** acquired | Planned |
| 4 | `sunrise_pct` | Brothers home → Lardna kills Buzz Buzz → leave → **sunrise** | Planned (MVP) |
| … | (later) | Onett day-1 / police / Frank / Twoson / … | Stretch stubs only |

---

## Fixtures (planned layout)

All under **`bin/states/llm/`** only (never human `slot1–4`).

```
bin/states/llm/
  bedroom.state           # tg start (exists)
  onett_start.state       # post-tg100 / free outdoor (capture)
  pokey_done.state        # after Pokey %
  pokey_knock.state       # knock chain armed or mid-scene
  buzzbuzz.state          # Picky + Buzz Buzz arc
  sunrise_morning.state   # post-sunrise day start
```

Exact names can shift; the **gate order** does not.

Until story flags are RE’d: human or scripted clear → save state at “I know this beat finished” → next segment loads that file. Pos/scene heuristics can bootstrap metrics; flags refine later.

---

## Skills growth (by gate)

| Gate | Skills emphasis |
|------|-----------------|
| tg | `walkTo`, `escapeMenu` |
| Pokey | + dialogue advance / talk-when-facing (A only in safe contexts) |
| Knocking | + return home; trigger/wait for story |
| Buzz Buzz | + follow/escort; battle if needed |
| Sunrise | + escort two NPCs home; play Minch scene through; exit for sunrise |

Prefer **stable Lua skills** + light seed policies; **qwen rewrites** for repair and local planning. Cloud models may author new skills when a gate is stuck.

---

## Metrics & reports (direction)

When implemented, mirror the `tg_pct` idea:

- Log `pokey_pct` / `pokey_knock_pct` / `buzzbuzz_pct` / `sunrise_pct` (0/100 or staged).
- On cross: milestone report under `bin/llm_reports/` (gitignored) with frame, pos, policy snippet, notes, **git commit hash**.
- Sunrise reports should **name Buzz Buzz’s death** and the remorse framing — not a silent flag flip.

Learning-speed comparisons (how fast a model clears gates) come **after** several gates exist and ablations are defined; see [llm-contamination.md](llm-contamination.md).

---

## What we are not doing yet

- Full-game sequence Twoson → Giygas as a committed checklist (stretch; add arcs after Sunrise).
- Claiming qwen “solved” prologue without seeds/skills (contamination applies).
- Skipping Lardna / Buzz Buzz death to cheese a pos-based sunrise.

---

## Division of labor (reminder)

| Role | Local qwen | Cloud (Grok / Claude) | Human |
|------|------------|------------------------|--------|
| Joypad / live policy | Primary | Experiments only | — |
| New skills / hard seeds | Secondary | Strong | Review |
| Capture fixtures | — | — | Primary (`make play`) |
| Emulator bugs blocking a gate | — | Dig help | Verify |

Pride condition later: **qwen still driving when sunrise fires.** MVP condition: **any harness path hits sunrise once.**

---

## Changelog

- **2026-07-08:** Initial campaign spine — tg done; Pokey → knock → Buzz Buzz (Picky) → Sunrise (escort home, Lardna kills Buzz Buzz, remorse, sun rises).
