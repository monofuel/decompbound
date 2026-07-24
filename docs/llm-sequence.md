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

IRL n=1 done (photo kept local, not in git).

---

### 2. Pokey % (`pokey_pct`) — **DONE (n=2, 2026-07-10)**

| | |
|--|--|
| **Beat** | Walk to **Pokey at the meteorite crash site** (hill north-west of the house; NOT the Minch house / Picky — that was an early confabulation, see [llm-contamination.md](llm-contamination.md) §1a) and talk to him. |
| **Route (ground truth)** | Door → SW off the yard → **west road** (Y~0x01F8–0x0270) → climb north at X~0x0600 → ridge east → meteor site. From monofuel's recorded TAS play, replayed + verified. Not story-gated. |
| **Win** | Adjacent to Pokey (`(0x0858,0x00F2)`, talk spot `~(0x0858–0x0862,0x00FA)`) with the meteor-scene flag `$9885` consumed (arms 01 en route, → 00 by the talk). Dialogue uses window slot 1 `$8654`. |
| **Fixture** | `bin/states/llm/onett_start.state`; human capture via `make play-pokey`. |
| **Seed policy** | `PokeyVisitPolicy` — `followTrail` on the recorded corridor + Up/A at the talk spot. |
| **Skills gained** | `navTo` (pixel-space A* over live collision, entity-aware), `followTrail`, `advanceDialogue` gating on both window slots, `nav.walkable`/`nav.findPath`. |
| **Metric (code)** | `pokeyPercent` in `src/tools/story_percents.nim` — 10→100 ladder along the real corridor; referee-checked (both human runs score 0→100). |
| **Status** | **Done**: headless mock e2e 10→100 (`POKEY_ACHIEVED@2920`), human-confirmed live in `make llm-ai`. |

---

### 3. Pokey-knocking % (`pokey_knock_pct`)

| | |
|--|--|
| **Beat** | Return home; **Pokey knocks** — the “come to the meteor” night chain starts. |
| **Win (intent)** | Knock / invite sequence accepted; party is on the meteor path (not still idling post-Pokey-visit). |
| **New pressure** | **Return path** + **scripted story trigger** (coords alone may not fire the beat). |
| **Why it exists** | Easy to “finish Pokey %” and miss that the plot only continues after the knock. |
| **Metric (code)** | Stub `pokeyKnockPercent` in `src/tools/story_percents.nim` (returns 0 until RE). |
| **Status** | Stub only. |

---

### 4. Buzz Buzz % (`buzzbuzz_pct`)

| | |
|--|--|
| **Beat** | Meteor / **Buzz Buzz** sequence. Along this arc you pick up **Picky** (Pokey’s brother). |
| **Win (intent)** | Buzz Buzz joined the night adventure; **Picky is with the group** (however party/NPC state is represented). |
| **New pressure** | Follow / multi-character motion, more dialogue, possible combat (bees etc.), longer scripted route. |
| **Metric (code)** | Stub `buzzBuzzPercent` in `src/tools/story_percents.nim` (returns 0 until RE). |
| **Status** | Stub only. |

---

### 5. Sunrise % (`sunrise_pct`) — **prologue MVP**

| | |
|--|--|
| **Beat** | End of the night prologue; **the game properly starts**. |
| **Win (intent)** | 1. Escort **Pokey + Picky** back to **Pokey’s house** (Minch home). 2. **Lardna Minch kills Buzz Buzz** (mandatory story beat — do not skip in framing or routing). 3. Leave the house → **the sun rises** and day-one Onett begins. |
| **Narrative requirement** | The AI (prompt, notes, milestone report) should treat Buzz Buzz’s death as **weighty**. Feel **significant remorse** for Buzz Buzz. Then walk out into sunrise. Remorse is a **framing / reporting** goal, not a WRAM bit — but the death scene is a **mechanical** gate. |
| **New pressure** | Escort both brothers, full Minch-house script, exit trigger for sunrise. |
| **Metric (code)** | Stub `sunrisePercent` in `src/tools/story_percents.nim` (returns 0 until RE). |
| **Status** | Stub only. **This is the MVP wall** — harder than tg by far; much of full-game difficulty after this is longer routes on the same verbs. |

After Sunrise, the bot is in **real game start** (cops, Frank, free(ish) Onett day). That is a **new arc**, not more prologue percents.

---

## Ladder summary

| Order | Id | One-line win | Status |
|------:|----|--------------|--------|
| 0 | `tg_pct` | Outside Ness’s house | **Done** |
| 1 | `pokey_pct` | Talked to Pokey at the meteor | **Done** (2026-07-10; human-confirmed) |
| 2 | `pokey_knock_pct` | Home + knock / meteor invite | Stub — **next** (see [roadmap.md](roadmap.md)) |
| 3 | `buzzbuzz_pct` | Meteor arc; **Picky** acquired | Stub (`src/tools/story_percents.nim`) |
| 4 | `sunrise_pct` | Brothers home → Lardna kills Buzz Buzz → leave → **sunrise** | Stub (MVP wall) |
| … | (later) | Onett day-1 / police / Frank / Twoson / … | Stretch stubs only |

Pure stubs (all return 0 until RE): **`src/tools/story_percents.nim`**. Surfaced in llm_ai rich state + slow-tick log next to `tg_pct`.

---

## Fixtures (planned layout)

All under **`bin/states/llm/`** only (never human `slot1–4`). Never git-add `*.state` — ROM-derived, gitignored under `bin/`.

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

### Regenerate `onett_start.state`

Needs user ROM + `bedroom.state`. Drives seed `NavHousePolicy` until `touchGrassPercent == 100`, then serializes:

```bash
nim r src/tools/llm_capture_fixture.nim
# default: load bin/states/llm/bedroom.state → out bin/states/llm/onett_start.state
# optional: --load-state-path PATH --out PATH --frames N [rom]
```

Until story flags are RE’d: human or scripted clear → save state at “I know this beat finished” → next segment loads that file. Pos/scene heuristics can bootstrap metrics; flags refine later.

---

## Skills growth (by gate)

| Gate | Skills emphasis |
|------|-----------------|
| tg | `walkTo`, `escapeMenu` |
| Pokey | + `advanceDialogue` / `talkOrAdvance` (A only when dialogue text present) |
| Knocking | + return home; trigger/wait for story |
| Buzz Buzz | + follow/escort; battle if needed |
| Sunrise | + escort two NPCs home; play Minch scene through; exit for sunrise |

Prefer **stable Lua skills** + light seed policies; **qwen rewrites** for repair and local planning. Cloud models may author new skills when a gate is stuck.

---

## Metrics & reports (direction)

Scaffold lives at **`src/tools/story_percents.nim`** (pure stubs → 0). llm_ai already logs and
puts the fields in rich state next to `tg_pct`; fill in heuristics when RE lands.

When implemented for real, mirror the `tg_pct` idea:

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
| Capture fixtures | — | scripted `llm_capture_fixture` / probes | Primary (`make play` + approve) |
| Emulator bugs blocking a gate | — | Dig help | Verify |

Pride condition later: **qwen still driving when sunrise fires.** MVP condition: **any harness path hits sunrise once.**

---

## Changelog

- **2026-07-08:** `llm_capture_fixture` for `onett_start.state` (bedroom → NavHouse → tg=100).
- **2026-07-08:** Pokey % skill/seed scaffold — `AdvanceDialogueSkillLua` + `PokeyVisitPolicy` + `selectMockPolicyByName`; outdoor coords TBD.
- **2026-07-08:** Story percent stubs in `src/tools/story_percents.nim`; llm_ai surfaces `pokey_pct` / `pokey_knock_pct` / `buzzbuzz_pct` / `sunrise_pct` next to `tg_pct`.
- **2026-07-08:** Initial campaign spine — tg done; Pokey → knock → Buzz Buzz (Picky) → Sunrise (escort home, Lardna kills Buzz Buzz, remorse, sun rises).
