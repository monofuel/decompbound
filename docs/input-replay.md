# Goal: input recording & replay (a TAS format)

**Status:** RECORD + REPLAY. Codec is `src/decompbound/replay.nim` (`DBTAS1`,
`cadence emu`, `apu_ticks 533`, in-log `chk`). `play.nim` records one joy1
sample per emulated frame (not per window loop) and writes
`<session>/<ts>.tas` + `<ts>_start.state`. After writing the start state it
deserializes it back so live == file. Headless feed is `src/tools/replay.nim`
via `applyTas`. Windowed: `make play-tas TAS=path.tas` (start state comes
from the header). Verified by `tests/e2e_replay.nim` + `tests/e2e_tas_identity.nim`
(serialize match). Old movies without `cadence emu` are refused unless
`--legacy-stretch N`. Re-record those.

Record every controller input during a session — frame number → joypad byte —
so an entire playthrough can be **replayed exactly**. A human (or the LLM agent,
`docs/llm-plays.md`) plays; we save the input log; anyone can re-run the same
game byte-for-byte. That's a TAS (tool-assisted-speedrun) movie in the classic
emulator sense: deterministic input + known start state = reproducible run.

## Why it's worth doing

- **Reproducible bug reports.** "It glitches here" becomes an input file that
  replays straight to the glitch, every time — no more hunting for the repro.
- **Regression testing.** Replay a known-good playthrough after a change and
  diff RAM checkpoints; if the trajectory diverges, the change broke something.
  This is what turns `docs/accuracy.md` from manual into automated.
- **Automatable test-ROM runs.** Booting a test ROM to its results screen (or
  navigating its menu) becomes a canned input log instead of hand-driving it.
- **Archival.** A full recorded playthrough of EarthBound — the game his cart
  could never keep — as a replayable artifact. (See the dead-cart history; a
  persistent record of a full run is not a small thing.)
- **The agent connection.** The LLM-plays harness already drives `joy1`; if its
  inputs are recorded in this format, every agent run is replayable and
  diffable, and human + AI runs share one format.

## What already helps

`play.nim` already synthesizes one **`joy1`** byte per frame (keyboard + paddy
gamepads, ORed) and sets `snes.joy1`. Recording is "append `(frame, joy1)` when
it changes"; replaying is "feed the logged `joy1` instead of reading input."
Both are small taps on an existing chokepoint.

## The determinism catch (be honest about it)

A replay is only exact if the run is deterministic from a fixed start. Two
things threaten that today:

- **Record tap must be per emulated frame.** `play.nim` can step 0–4 emu
  frames per window loop (pacing + turbo). The recorder used to increment
  once per window loop, so `.tas` timestamps were display iterations.
  Turbo made A land before title was ready; replay stayed on title. Fixed:
  record inside the `for t in 0 ..< ticks` emu loop. **Old movies (including
  `20260816-183136.tas`) are window-loop time and will not replay.** Re-record.
- **Boot-timing non-determinism** (issue #13): the live APU (real SPC700 + IPL)
  handshake + our fixed-cadence NMI make cold boot slightly non-deterministic
  run-to-run. So replays should start from a **pinned state**, not a cold boot —
  either a savestate snapshot bundled with the log, or a recording that begins
  after boot settles. A snapshot at `$00:8141` with NMI off is the RESET
  vector (normal), not a hang.
- **Any wall-clock or nondeterministic input** to the emulator must be excluded
  from the replay path (replay reads the log, nothing else).

Nailing determinism here also *pays back* the accuracy work — a run that can't
replay identically is itself evidence of a timing bug to chase.

## Components

1. **Log format** — **done (codec).** Text `DBTAS1` format: header
   (`rom_hash`, `start_state`) + sparse `(frame, joy1)` deltas. Human-diffable.
   Procs: `serializeReplay` / `parseReplayString` / `parseReplay`,
   `writeReplayHeader` / `appendReplayDelta`. See module header comment in
   `src/decompbound/replay.nim`.
2. **Record mode** in `play.nim` — **done.** Always on (F7 toggles). One
   start-state + sparse joy1 deltas per segment. `chk` every 60 frames.
3. **Replay mode** — **done.** Headless `src/tools/replay.nim`; windowed
   `play --tas` / `make play-tas TAS=…`. Same `applyTas` / `stepReplayFrame`
   stepper (533 APU ticks). TAS joy is applied inside the emu-frame loop so
   catch-up ticks cannot skip inputs.
4. **Pinned start state** — **done.** Recorder writes `_start.state` and
   reloads it. `play --tas` loads the header path if `--load-state-path` is
   omitted. Deserialize wipes leftover APU mix / PPU latches so two loads of
   the same blob are the same machine.
5. **Checkpoint hashes** — **done.** `chk` every 60 frames; replay aborts on
   the first mismatch (`verifyChk`).

## Definition of done

- [x] Log format serialize/parse round-trip (`tests/test_replay.nim`).
- [x] `play` can **record** a session to an input-log file (F7 → `.tas`).
- [x] Replay runs **headless** (`src/tools/replay.nim`).
- [x] Start + TAS **reproduces** serialize + WRAM hash (`tests/e2e_tas_identity.nim`).
- [x] **One stepper:** 533 APU ticks/frame always (play turbo no longer
      shortens the APU). `cadence emu` in the header. Replay refuses
      logs without it unless `--legacy-stretch N`.
- [x] In-log `chk` every 60 frames; replay aborts on first mismatch.
- [ ] llm_ai writes the same format.
- [ ] A recorded human playthrough and a recorded LLM-agent run use the same
      format and both replay cleanly.

## Non-goals

- A full TAS *editing* UI (frame-advance, rerecord, piano roll) — that's a
  bigger tool; this goal is record + faithful replay.
- Cross-emulator movie compatibility (`.bk2`/`.lsmv` formats) — our own format
  is enough; interop is a later nicety.

**Scope:** `play.nim` record/replay taps + a small log format + a pinned start
state. Enables the regression half of `docs/accuracy.md`; parallel-safe; off the
`docs/goal.md` critical path.

## Recorded sessions

`make play-tas` re-reads the current `.tas` several times a second (title
shows `TAS frame/last file` and `live` when the file grew) and hops to a
new `play-cont` segment when the tape ends.

Chain a new segment from the last F12 / window-close end snap:

`make play-cont`

Each run writes `_start.state` plus `started_from.png` when you loaded an
F12. Close the window (not Ctrl+C) to write an end screenstate.

## Bench referee (`.ref` goldens)

`chk` lines only cover WRAM and the player position. `src/tools/bench_replay.nim`
replays a tape with rendering on and folds a crc32 of every frame image and of
the 533 APU samples per frame into running hashes, writing a `DBREF1` golden
(`<tape>.ref`, one `frame image audio wram` row per 60 frames, hashes only)
beside the tape in `decompbound_secret`. Later runs compare and fail on the first
divergent row, naming which of image/audio/wram moved, so an emulator
optimization is proven behaviour-preserving on every host it runs on
(the hot path is integer-only, so x86 and arm64 must agree). `make bench`
times the fixed workload (`20260816-223148 --frames 3600`), `make bench-check`
replays all five verified tapes in full, `make bench-ref` rewrites the goldens
(deliberate, after an intended rendering fix; `--accept-image` rewrites only
the image column). The Raspberry Pi workflow is in [raspberry-pi.md](raspberry-pi.md).

Diagnose a session with [run-report.md](run-report.md):
`make run-report SESSION=../decompbound_secret/sessions/<ts>`.

- [2026-08-16/17 day-1 TAS](2026-08-16-day1-tas.md) — **extremely
  unlucky** (9 deaths on the early tape, then **3 more to Mondo Mole**)
  that still **beat Titanic Ant** (F12 `011117`) and reached **Peaceful
  Rest Valley**. Paula is in (`003751`). Sunrise → sharks → Frank →
  Giant Step → Twoson → valley → Mondo Mole → Happy Happy. Deaths are
  **edge-case coverage**. Segments `235052` + `000051` + `225201` +
  `230734`.
- [2026-08-16 sunrise TAS](2026-08-16-sunrise-tas.md) — **first cadence-emu
  movie, human-verified.** Fast-text bedroom → meteor night → leaving
  Pokey's house / sunrise. `make play-tas TAS=../decompbound_secret/sessions/20260816-223148/20260816-223148.tas`.
- [2026-08-16 Fast-text TAS](2026-08-16-fast-text-tas.md) — cold-boot new file
  (Steak / Rockin', Fast text), meteor night through Starman Jr, sunrise,
  sharks, Frank (loss). `.tas` is window-loop; F12s are the ground truth.
  `bin/states/llm/bedroom.state` is that run's standing-bedroom F12.
- [2026-08-16 bedroom TAS](2026-08-16-bedroom-tas.md) — aborted after one fight.
  Fixture text speed was medium/slow. Do not use as bot ground truth.
</content>
