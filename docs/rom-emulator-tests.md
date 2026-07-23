# ROM / Emulator Test Suite — plan

**Status:** proposal / design. Not yet built.
**Updated:** 2026-07-21.

## Why this exists

The emulator's original job is to **debug the decomp** — and the LLM-play harness
sits on top of it. Both need a way to prove, repeatably and without a human in
the loop, that:

1. **The emulator/decomp produces correct game behavior** — a battle really ends,
   the knock really fires, a door really warps you inside.
2. **Our Lua/tool layer parses memory correctly** — `inBattle()` flips, dialogue
   decodes, milestone triggers fire on the right frame.

One suite covers both. Each test starts from a **fixed save state**, runs a known
set of actions, and asserts the resulting state. Fixtures are captured **once**
and reused forever — this replaces the "please F12 a state for me" loop that
doesn't scale past a beat or two.

Longer term this is also (a) the **regression corpus** for the whole game — every
beat we solve gets locked in — and (b) the **autonomous progression engine** (see
[Chaining](#chaining--the-autonomous-engine)).

## The core shape

```
fixture (save state)  →  actions (fixed inputs OR a deterministic policy)  →  assert end state
```

- Runs **headless** (fast, CI, PASS/FAIL table) or **windowed** (watch it happen,
  build trust, demo).
- Assertions read both raw game state and our tool functions (see below).

## Determinism is the foundation

The SNES has **no hardware RNG** — no entropy source anywhere. EarthBound's
"randomness" is a software PRNG seeded from a value in **WRAM**, which is fully
captured in the save state. So:

> A fixed fixture + fixed inputs (or a deterministic policy) produces a
> **byte-identical** outcome every run — damage numbers, crits, drops, all of it.

Therefore we assert **exact end states**, not weakened "invariants." And it flips
into a stronger guarantee:

> **Any nondeterminism is a bug to catch.** If the same fixture + inputs ever
> yield two different results, something is leaking entropy — an uninitialized-RAM
> read, a wall-clock dependency, a policy pulling randomness from outside the
> sandbox. The suite polices the decomp's determinism, not just its beats.

Constraints (on us, not the game): policies must be deterministic (no wall-clock,
no real randomness in the Lua); the emulator must not read uninitialized state.

- **TODO (verify, don't assume):** RE the exact RNG seed address + advance routine
  (per-call only, or also per-frame idle?) and document it in `memory-map.md`, so
  tests can log/seed it and RNG behavior is known cold.

## Dual-layer assertions

Every test can assert against two layers, and asserting **both** localizes a
failure to the layer that broke:

| Layer | Example | Catches |
|-------|---------|---------|
| **raw** (game/emulator state) | `mode==0 → !=0`, enemy HP hits 0, flag `$XXXX` set | decomp / emulator bugs |
| **tool** (our harness parsers) | `inBattle()==false`, `screen.battleText()~="won"`, milestone% updates | Lua/tool-layer bugs |

If "battle ended" isn't detected: raw says the game *did* end but `inBattle()`
disagrees → parser bug; raw says it *didn't* end → decomp bug.

## Assertion types

State isn't the only thing worth checking — the user's own examples include a
knock **sound** and **animation**:

| Type | Mechanism | Use for |
|------|-----------|---------|
| **state** | WRAM / register reads | flags, HP, positions, mode |
| **tool** | our Lua/Nim parser functions | the exact code the LLM depends on |
| **text** | `getDialogueText` / `getBattleText` decode | text boxes, menus, battle lines |
| **visual** | rendered-frame hash vs a committed golden PNG | animations (knock sprite, battle FX) |
| **audio** | the SFX/music command issued to the APU (CPU→APU ports / sound-engine RAM), and/or a hash of DSP-rendered audio over a window | knock sound, battle music, menu blips |

Visual + audio reuse existing infra (frame rendering + golden PNGs; the DSP/SPC
audio path). "Assert the SFX command was issued" is cheaper and more robust than
hashing rendered audio; support both.

## Test format (proposed: data-driven)

A table of specs beats hand-written procs for adding beats fast:

```
{
  name:    "battle_win",
  fixture: "battle/battle_menu_healthy.state",
  actions: policy("winBattle"),        # or inputs("A A A ... ") for fixed sequences
  timeout: 3000,
  assert: [
    raw   "left battle: BG mode 0 -> !=0",
    tool  "inBattle() == false",
    text  "battleText contains 'won' or EXP",
  ],
}
```

Open decision: pure data table vs Nim procs like `tests/test_emulator.nim`. Lean
table (scales to hundreds of beats); drop to a proc for the rare test that needs
custom logic.

## Run modes + make targets

- `make test-beats` — headless, runs all, prints a PASS/FAIL table, exits nonzero
  on any failure (CI-friendly).
- `make test-beats-watch` — windowed, runs each in sequence with an on-screen
  caption + PASS/FAIL verdict overlay; slow enough to eyeball; `--pause-on-fail`.
- Filters: run one test or a named group (`ARGS="--only battle_win"` /
  `"--group nav"`).

## Fixtures

- **Provenance (capture-once, ~zero ongoing human effort):**
  1. **Extract from the archive** — `decompbound_secret/` has 471 F12 snaps;
     `probe_scan_screenstates.nim` already pulled `battle_menu_healthy.state` out
     of one. Most fixtures we need are probably already sitting there.
  2. **Auto-save from a passing test** — a beat's verified end-state becomes the
     next beat's fixture (see Chaining).
  3. Rare fresh capture, only for a beat neither of the above covers.
- **Storage:** save states are game-data. Keep fixtures in
  `decompbound_secret/fixtures/` (or gitignored), **not** the public repo. Tests
  **skip-if-missing** so the public repo stays clean and CI degrades gracefully
  instead of hard-failing on absent fixtures.
- **Naming:** `<area_or_system>/<beat>.state`, e.g. `battle/first_battle.state`,
  `prologue/pokey_talk.state`, `prologue/pokey_knock.state`.

## Chaining → the autonomous engine

Each test's verified end-state can seed the next test's fixture:

```
bedroom → [nav_crater] → [talk_pokey] → [head_home] → [sleep_knock] → ... → [sunrise]
```

Running the chain **is** playing the prologue, validated at every link — no human,
no TAS. It also turns the LLM's job into something crisp and delegable:

> **"Write the Lua policy that makes the next beat-test pass."**
> The test is the pass/fail reward signal; a passing beat auto-saves its
> end-state as the next fixture. That's the loop that scales to a 30-hour game.

## Failure output

On failure, dump: expected vs actual for each assertion, **which layer** (raw vs
tool) diverged, a rendered PNG of the final frame, and a WRAM diff vs the fixture.
Debugging a decomp/emulator issue should start with a picture and a diff.

## Seed test list (initial)

Concrete beats to stand up first — several already exist as ad-hoc probes and just
need promoting:

| Test | Fixture | Validates (raw + tool + …) |
|------|---------|----------------------------|
| `dialogue_pokey` | pokey adjacency | **text boxes work**: open window, `getDialogueText` decodes Pokey's line, `advanceDialogue` closes it |
| `pokey_knock` | pre-knock bedroom | knock event fires: knock flag set (**RE needed**), **knock SFX** issued to APU (audio), door-knock **animation** frames match goldens (visual) |
| `first_battle` | first-battle entry / a battle menu | **battle works**: menu options parse, attack executes, enemy defeated, victory + return to overworld, `inBattle()` transitions |
| `battle_win` | `battle/battle_menu_healthy.state` | (exists as `probe_battle_win`) exact win, mode leaves 0 |
| `nav_crater` | outside Onett | `probe_pokey` promoted: reaches Pokey (pokey milestone) |
| `head_home_knock` | post-Pokey crater | `probe_knock` promoted: reaches bed (knock milestone) |
| `menu_open_close` | overworld | `escapeMenu` opens/closes the status menu; no stray input leaks |
| `entity_names` | multi-NPC scene | `$2CD6`/`$29CA` → correct names (Mom/Pokey/Ness) |
| `save_load_roundtrip` | any | serialize→deserialize is byte-identical (determinism guard) |
| `sunrise` | end-of-prologue | the prologue MVP endpoint once the chain reaches it |

## Relationship to existing infrastructure

- **Promotes** the ad-hoc referees (`probe_pokey_policy`, `probe_knock`,
  `probe_battle_win`) into one framework instead of N bespoke mains.
- **Complements** `tests/test_emulator.nim` (unit-level boot), `testrom.nim`
  (SNES test-cart accuracy), and the rendering goldens — this is the
  **beat/behavior** level between them.
- Largely retires `docs/human-captures-needed.md`: captures become one-time
  fixtures sourced from the archive, not per-beat asks.

## Rollout

1. **Framework + 3 seed tests** — the runner (headless + windowed), the spec
   format, and `battle_win` / `nav_crater` / `dialogue_pokey` promoted from
   existing probes. Proves the shape.
2. **Prologue chain to sunrise** — fill the beat chain; auto-save fixtures between
   links; RE the knock flag + RNG seed along the way.
3. **Extend assertion types** — visual goldens + audio (knock sound, battle
   music), wired into `pokey_knock`.
4. **The LLM loop** — "write the policy that passes the next beat," delegated to
   models, gated by the tests.

## Open decisions

- Spec format: data table (recommended) vs Nim procs.
- Fixture location: `decompbound_secret/fixtures/` vs gitignored in-repo dir.
- Audio assertion: assert the APU SFX command (cheap, robust) and/or hash DSP
  output (end-to-end). Start with the command.
- Windowed UX: auto-advance with verdict overlay + `--pause-on-fail`.
