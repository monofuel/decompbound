# EarthBound PRNG — the reference

The single home for RNG knowledge: routine, seed, oracle, advancement
schedule, and manipulation mechanics. Drop-roll specifics and the Sword of
Kings campaign live in [sword-of-kings.md](sword-of-kings.md); this doc is
the general mechanism. Started 2026-07-27 after live F8-HUD play produced
major advancement discoveries.

## The generator (✅ adopted + gold-gated)

| | |
|--|--|
| Routine | `$C08E9A` (56 bytes, JSL-only, 59 call sites) |
| Seed | 32-bit LE at WRAM `$0024` (lo) / `$0026` (hi) |
| Cold init | `$5678_1234` written at `$C08121` |
| Algorithm | 8×8 HW mul (`$4202/$4216`) of hi.lo×lo.lo, `+$6D` fold, double-ROR mix |
| Adopted asm | `snes_src/rng.nim` (byte-exact, tests/test_rng.nim) |
| **Pure oracle** | `src/decompbound/rng_oracle.nim` `advanceSeed(seed) -> (value, seed')` — verified vs every live call over hundreds of frames, zero mismatches (tests/test_rng_oracle.nim) |
| Live HUD | **F8** in play: seed hex + advance counter (seed-delta + oracle walk) |

Key property: advancement is **event-driven** — zero advances on overworld
idle. Every advance is caused by something.

## Advancement schedule

Two evidence classes, which DISAGREE in places — menu RNG consumption is
**context-dependent** (menu type, window contents, party, place). Do not
average them; reconcile per-context.

### Probe-measured (probe_rng_advances.nim, specific states, 2026-07-27)

Context: overworld command menu states (poo_deep_south etc.), generic +
Starman Super battle states.

| Action | Advances | Caller |
|--------|----------|--------|
| Overworld idle 60/180f | 0 | — |
| Walk (direction/context-dep) | 0-1 /60f | `$C02823` |
| Command menu open (A) | 2 | `$C12DDB` |
| Command menu dwell 120f | 0 | — |
| Command menu cursor move | 0 | — |
| Menu close (B) | 64 | `$C12DDB` |
| Dialogue on screen | ~50 /60f | `$C12DDB` |
| Battle command menu dwell | 0 | — |
| Battle cursor 60f | 5 | `$C12DDB` |
| Battle attack window 180f | ~101-131 | mixed |

### Live-observed (monofuel, F8 HUD, Stonehenge Base session 2026-07-27)

| Action | Advances | Note |
|--------|----------|------|
| **Stat menu opened with B: EVERY FRAME, constantly** | ~60/s sustained | **THE discovery — see "spinner" below** |
| Menu open/close with A | **+1 per button press** (min 2 for a toggle) | differs from probe's open=2/close=64 context |
| Menu navigation | **+1 per input** | differs from probe's cursor=0 (different menu/context) |
| Any menu open | **≥1 per second** | suspected `>` cursor blink animation |

### Reconciliation status (🟡 open)

The probe's command-menu states showed dwell=0 over 120f; live play shows
≥1/s with a menu open and per-frame churn in the B-stat menu. Both are
real measurements — different menus and contexts consume differently
(probable factors: which window is open, text/cursor animation state,
party size). TODO: headless re-measure using tonight's Stonehenge F12s,
per menu type: caller PCs for (a) the stat-menu per-frame source, (b) the
1/s blink source, (c) per-navigation +1 — then split this table by menu
type with caller evidence.

## The manipulation interface (the big one)

The live discoveries combine into a complete human seed-dialing console:

- **Coarse spin:** open the stat menu with B → the seed free-runs at
  ~60 advances/second. Hold to fast-forward through seed space; close to
  stop. Effectively a re-roll/randomize lever when you're in a bad seed
  neighborhood.
- **Fine step:** menu navigation = exactly +1 per input; A-toggle = +1
  per press. Step to an exact target seed.
- **Read-out:** F8 HUD shows the live seed hex + advance counter.
- **Park:** overworld idle = 0 — the seed holds still while you think
  (menus closed).

With a target seed from the recipe tooling ("get the seed to X, then
execute the fixed kill script"), the human procedure is: spin close with
the B-stat menu, fine-step with navigation, confirm on the HUD, go.

Caveat for recipes: the ≥1/s menu-open tick means fine-stepping should
be done briskly or with menus closed between steps; the exact source and
rate need the reconciliation pass above before recipes rely on dwelling
with a menu open.

## Drop rolls (summary — details in sword-of-kings.md)

- Enemy table `$D59589`, stride `0x5E`; drop freq enum `+0x57` (0=1/128,
  1..6 = 1/64..1/2 via masks `$7F..$01`, ≥7 = always), drop item `+0x58`.
- Roll = `JSL $C08E9A` + `AND #mask`, success only on 0. Sites `$C24DDC`
  and `$C264B1`, both on the battle VICTORY/reward path (strongly
  supported; complete `STA $AA10` enumeration). No battle-init roll; no
  carry flag; Jeff's Spy is intel-only (no roll, no drop-field read).
- Battle command menu is dwell-safe (0 advances) — the recipe anchor is
  the final command menu before the killing blow.

## Tooling index

| Tool | What |
|------|------|
| `src/decompbound/rng_oracle.nim` | pure `advanceSeed` |
| `src/probes/probe_rng_advances.nim` | action→advances measurement |
| `src/probes/probe_drop_table.nim` | enemy drop table dump |
| `src/probes/probe_spy_roll.nim` | Spy semantics referee |
| F8 HUD (play) | live seed/advances/EXP/formation |
| tests/test_rng.nim, test_rng_oracle.nim | gold gates |
