# Goal: input recording & replay (a TAS format)

**Status:** FORMAT + STUB IN PROGRESS. The text `.tas` codec lives in
`src/decompbound/replay.nim` (serialize/parse round-trip, file record appends,
`deltasToTable` / `joyAtFrame`). `play.nim` already has F7 record taps writing
`bin/replays/*.tas` + `start.state`; headless feed is `src/tools/replay.nim`.
Verified by `tests/test_replay.nim`. Full record→byte-identical replay from a
pinned state (checkpoint hashes end-to-end) is still open — see DoD below.
A companion to the accuracy work, and fun in its own right.

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

- **Boot-timing non-determinism** (issue #13): the live APU (real SPC700 + IPL)
  handshake + our fixed-cadence NMI make cold boot slightly non-deterministic
  run-to-run. So replays should start from a **pinned state**, not a cold boot —
  either a savestate snapshot bundled with the log, or a recording that begins
  after boot settles.
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
2. **Record mode** in `play.nim` — **stubbed.** F7 toggles recording: snaps
   `bin/replays/start.state`, writes deltas on joy1 change to `bin/replays/<ts>.tas`.
3. **Replay mode** — **headless stub.** `src/tools/replay.nim` loads start state
   + log and feeds `snes.joy1` from the schedule. Windowed replay-in-`play.nim`
   not required yet.
4. **Pinned start state** — **partial.** Recorder writes `start.state`; headless
   tool accepts a path or slot. Exact end-to-end determinism still blocked on
   boot-timing / full checkpoint story.
5. **Checkpoint hashes (optional)** — **helpers only.** `wramHash` exists for
   end-of-run reports; periodic in-log checkpoints not wired yet.

## Definition of done

- [x] Log format serialize/parse round-trip (`tests/test_replay.nim`).
- [x] `play` can **record** a session to an input-log file (F7 → `.tas`).
- [x] Replay runs **headless** (`src/tools/replay.nim`).
- [ ] The log **replays** to a byte-identical run from a pinned start state
      (verified by matching WRAM checkpoint hashes end to end).
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
</content>
