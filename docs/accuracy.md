# Goal: accuracy via test ROMs (not a second emulator)

**Status:** NOT STARTED (design). The chosen strategy for raising emulator
fidelity beyond eyeballing `make play`.

The playtest backlog in `docs/issues.md` is really an accuracy backlog. The
question is how to verify fixes against *hardware truth* without babysitting a
second emulator.

## The decision: test ROMs, not multi-emulator diffing

We considered differential testing against an accurate reference emulator
(bsnes-accuracy, Mesen-S) — run both on the same input, diff RAM/pixels, chase
the first divergence. It's powerful, but rejected for now because:

- **It's complex** — wiring up a second emulator, deterministic dual replay, and
  trace/RAM export is a lot of moving parts.
- **It just moves the trust problem** — you'd be certifying against *another
  emulator's* accuracy, not hardware.

**Test ROMs are self-contained hardware truth.** A good accuracy test ROM
encodes a known-correct hardware result and reports PASS/FAIL itself — no second
emulator, no pixel arbitration. It's an oracle whose correctness was validated
against real silicon by its authors, and it runs *on us*. If we fail a test, the
ROM tells us exactly which hardware behavior we got wrong.

We already do this and it works: the CPU core passes **5,120,000 65816 test
vectors** (tomharte/ProcessorTests) — that's this exact approach, hardware-
derived, applied to the CPU. This goal extends the same philosophy outward to
the **PPU, APU, DMA/HDMA, and timing** — the subsystems behind our open issues.

## The inspiration: AccuracyCoin (and the SNES reality)

[AccuracyCoin](https://github.com/100thCoin/AccuracyCoin) is the model for what
we want: a single cartridge with **141 accuracy tests**, an on-screen PASS/FAIL
scoreboard, a menu, error codes, MIT-licensed with assembly source. It is the
gold standard for "boot one ROM, read a legible accuracy report."

**Caveat that shapes this goal:** AccuracyCoin is an **NES** suite (6502 / 2C02).
Our emulator is SNES/65816, so it can't boot that ROM. The SNES scene has no
single equivalent mega-cart — it's a *collection* of focused test ROMs. So part
of this goal is surveying and assembling that collection.

### Surveyed SNES test ROMs (scoped to a plain HiROM game)

Ranked by usefulness *to us*. Scoping matters: EarthBound is plain HiROM with
**no enhancement chips**, so the popular Cx4 (Mega Man X2/X3) and SPC7110 test
ROMs are **out of scope** — we don't emulate coprocessors (`docs/goal.md`
non-goal), so those tests can't pass and shouldn't.

**Tier 0 — already integrated**
- **tomharte/ProcessorTests (65816)** — the 5.12M CPU vectors we already pass.
  The baseline; keep it green.

**Tier 1 — flagship pass/fail (start here)**
- **Blargg's SNES tests** (~9 tests: CPU behavior, ADC/SBC arithmetic edge
  cases, OAM/sprite accuracy). The classic suite; higan/bsnes/lsnes pass all of
  them, so it's a clean bar. Reports pass/fail (blargg's result-byte + on-screen
  text convention — readable headless). Best quick accuracy check. → CPU, and
  sprite handling (#9).

**Tier 2 — PPU / video (our biggest issue cluster)**
- **240p Test Suite (SNES)** by Artemio — well-maintained open-source homebrew
  (itch.io); video output, color, scanlines, timing/lag patterns. Directly
  exercises the rendering behaviors behind #2 / #10 / #11 / #12. Mostly visual.
- **gradient-test** (NovaSquirrel) — **CGWSEL** register accuracy. Points
  straight at #12 (color-math / CGWSEL/CGADSUB stuck-bright). Visual diff.
- **PPU bus activity** (lidnariq) — BG modes 0–6 on one screen; validates our
  mode 0/1/3 rendering. Visual.
- **Elasticity** (rainwarrior) — Mode 3 enhanced color; mild relevance (EB uses
  Mode 3). Visual.

**Tier 3 — input & CPU edge**
- **ctrltest** (rainwarrior) — controller input validation. → the #8 input
  issues (B/X, diagonals, dropped taps).
- **CPU multiplier test** (`$4203`/`$4204` behavior, "twice too fast") — would
  guard the hardware multiply/divide unit, the keystone fix from #5, against
  hardware.

**Tier 4 — broad, lower priority (with a caveat)**
- **Official Nintendo SNES Test Programs** (Aging Test, SNES Test Program,
  Controller Test) — broad hardware validation, but these are Nintendo-internal
  ROMs: **provenance/copyright is murky** (see `docs/copyright-notes.md`), so
  treat as reference-only, not something we redistribute.

Reference tables worth keeping open: the **TASVideos SNES Accuracy Tests** page
(emulator-vs-test comparison grid) and the **SNESdev wiki Emulator tests** page
(`https://snes.nesdev.org/wiki/Emulator_tests`, the source of the homebrew list
above).

Also runnable, though not pass/fail scoreboards: **PeterLemon/SNES** ships
ready-to-run `.sfc` demos across CPU/PPU/DMA/APU we can boot and compare against
their known reference output.

### The self-hosted twist: author our own

Goal 1 already produced a **working 65816 assembler + ROM builder**
(`docs/goal-1.md`). So decompbound can *write its own* AccuracyCoin-style SNES
test ROMs — small assembly programs that exercise one hardware behavior, compute
a known-correct result, and report PASS/FAIL on screen. Self-hosted accuracy
tests, built with our own toolchain, targeting exactly the behaviors our issues
implicate (window masking, color math, HDMA per-scanline register timing). This
is the most on-brand option and needs no external ROM at all.

## How we'd read results

Two ways, depending on the ROM:

- **On-screen scoreboard** — boot the test ROM in our emulator, let it run to its
  results screen, screenshot it (we already render + screenshot), and read the
  PASS/FAIL grid. Track the score over time as a fidelity metric.
- **Result memory** — many test ROMs write pass/fail codes to a known RAM/SRAM
  address; read those directly (like `sram_info.nim` reads save fields) for a
  headless, automatable pass/fail without OCR'ing pixels.

## Driven by the issue list

This isn't "boil the ocean of accuracy." Each open issue names a subsystem; run
the test ROM that exercises it, and the fix is verified against hardware truth,
not vibes:

- #2 iris / #10 battle band → PPU window masking + per-scanline HDMA (240p
  suite patterns; PPU bus activity for BG-mode/scanline behavior).
- #12 stuck-bright → color math: **gradient-test** (CGWSEL) + CGADSUB/COLDATA.
- #9 sprite order → **Blargg's** OAM/sprite tests.
- #8 input (B/X, diagonals, dropped taps) → **ctrltest**.
- #5 regression → **CPU multiplier test** guards the math unit against hardware.
- #11 top-scanline flicker / #13 boot race → 240p timing/lag patterns.
- #4 audio coherence → APU/SPC700 tests (thin on the ground for SNES — a gap a
  self-authored test could fill).

## Other free oracles worth remembering

- **The game's own anti-tamper checks.** EarthBound is packed with anti-piracy/
  anti-cheat checks that corrupt or freeze if hardware misbehaves (we already hit
  the SRAM one). Getting deep into the game *without* tripping them is the game
  certifying our emulation.
- **Real hardware capture** — the bedrock oracle (real SNES + cart + capture, or
  a flashcart running the test ROMs). A hardware project, not near-term, but it's
  what everything else is ultimately validated against.

## Definition of done

- [ ] A surveyed, documented set of SNES test ROMs that boot on our emulator,
      with each one's pass/fail (or reference output) recorded.
- [ ] A repeatable way to run a test ROM and read its result (scoreboard
      screenshot and/or result-memory read), tracked as a score over time.
- [ ] At least one open `issues.md` bug fixed *and verified* by the relevant
      subsystem test ROM (not just by eye).
- [ ] Bonus: one self-authored AccuracyCoin-style SNES test ROM, built with our
      own Goal-1 assembler, reporting PASS/FAIL on screen.

## Non-goals

- Standing up a second reference emulator (explicitly rejected above).
- Bit-perfect timing beyond what our issues and test ROMs actually demand.
- A real-hardware capture rig (someday, not now).

**Scope:** verification tooling + reverse engineering. Deterministic
input replay (`docs/input-replay.md`) is the natural companion — it makes
booting a test ROM to its results screen reproducible and automatable.
</content>
