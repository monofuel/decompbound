# Companion Apps & Observability

Beyond the core decomp/emulator goals (`docs/goal.md`), a set of small desktop
apps that make the project *browsable* and *legible* — turning the data we've
already reverse-engineered into things you can look at, listen to, and poke at
live. None of these are on the critical path; all three are "sanctioned fun"
that pays for itself by surfacing bugs and confirming our RE.

The common thread: **they build on stuff already mapped**, so they're mostly
plumbing over solid ground, not new reverse engineering.

- The **live APU** (real SPC700 + S-DSP + IPL boot ROM) already renders
  non-silent PCM (`render_song`, `music_explore.nim`).
- The **SRAM save format** has confirmed offsets (money, ATM, HP/PP, backup
  copy) mapped in `src/tools/sram_info.nim`, with a `--find` value-locator to
  map more.
- **play.nim** already tracks SNES button state each frame and has an F12
  PPU-state dump + an F10 per-scanline trace — the raw material for a HUD.
- **silky** (treeform's windy/opengl/pixie GUI helper) is already a dependency
  and is imported by three intended "explorer" apps — but `sound_explore.nim`,
  `sprites_explore.nim`, and `map_explore.nim` are all one-line TODO stubs
  today. These apps are where silky finally gets used for real.

---

## App 1: Music jukebox — browse & play every track in the game

**Status:** STARTED, doesn't work well yet. Two false starts to converge.

A desktop app to browse the full EarthBound soundtrack and play any track on
demand — a proper jukebox with a real track list, play/stop, and a now-playing
readout, backed by our live SPC700 + S-DSP.

### Why it's buildable now

The audio core already produces sound. `music_explore.nim` boots the ROM,
seeds a standalone APU from the captured driver image, replays the game's port
writes, and renders WAV — it works well enough to have confirmed real music
offline. The missing piece is a real **song directory** (which upload / port
command selects which track) plus a decent UI.

### What exists (and why it's rough)

- `src/tools/music_explore.nim` — a raw windy/OpenGL window with **3 hardcoded
  track presets** and a hand-rolled menu that fakes text labels with colored
  rectangles (`# crude label: fill a "number" area`). It renders to WAV files
  rather than playing live. It reinvents a UI instead of using silky.
- `src/tools/sound_explore.nim` — a silky stub (`import silky`, TODO). This is
  the natural *home* for the finished app: silky gives real text, lists, and
  buttons like the sibling explorers are meant to.

### Components

1. **Song directory** — enumerate EB's music tracks (the sound-driver song
   table: which song ID → which sequence + instrument set). This is the real RE
   work; everything else is UI. Sources: the sound-driver upload our boot
   captures, plus community song-ID lists to cross-check clean-room results.
2. **Live playback** — reuse play.nim's approach: run the APU in real time and
   stream 32kHz stereo PCM to a **slappy** `StreamingSource`, instead of
   rendering to WAV. Select a song by writing its ID to the driver's port
   command (the game's own "play song N" path), so sequence + samples stay
   coherent (avoids the #4 snapshot-replay mismatch).
3. **silky UI** — scrollable track list (real names), play/stop, now-playing +
   a simple level/voice meter. Built in `sound_explore.nim` on silky, matching
   the intended explorer-app pattern; retire `music_explore.nim`'s raw-GL menu.

### Definition of done

- [ ] A scrollable list of named tracks, not 3 hardcoded presets.
- [ ] Selecting a track plays it **live** (streamed), not to a WAV file.
- [ ] Song transitions are clean (pick the coherent live-APU path, per #4).
- [ ] Built on silky in `sound_explore.nim`; the raw-GL `music_explore.nim`
      menu is gone (its APU-render logic can be salvaged into `render_song`).

**Scope:** sound-driver RE (song table) + silky UI + live APU streaming.
Ties into issue #4 — doing this right *is* the "live two-way APU" win.

---

## App 2: Save-file report card — read the SRAM, print a full report

**Status:** NOT STARTED (but `sram_info.nim` is the seed).

Point it at a `.srm` and get a human-readable report of the whole save: every
character's stats, inventory, money, story flags, playtime — the save file as a
character sheet. Great for verifying our SRAM mapping and just fun to look at.

### Why it's buildable now

`src/tools/sram_info.nim` already validates the `HAL Laboratory, inc.` header,
reads little-endian fields, and has confirmed offsets for money/ATM/HP/PP plus
a `--find <value>` locator. A report generator is the same reading, widened to
the full format and formatted nicely — and `--find` is exactly how we widen it
(tell it an in-game value, it finds the offset).

### Components

1. **Widen the format map** — extend `sram_info.nim`'s `KnownFields` beyond
   money/HP/PP: all party members' stats (HP/PP/Offense/Defense/Speed/Guts/
   Luck/Vitality/IQ), level & EXP, name strings (EB's text encoding), inventory
   slots + equipment, ATM/money, and story/flag bytes. Map each with `--find`
   against known in-game values before trusting it. Confirmed-vs-guessed stays
   labeled, as the table already does.
2. **Report renderer** — two outputs from one field model:
   - **Text** (`make sram-report`) for the terminal / quick checks.
   - **HTML** into `docs/` (e.g. `docs/save-report.html`) so it renders in the
     Mummy docs server with tables per character, matching the
     `snes-architecture.html` theme-aware style.
3. **Both save slots** — EB mirrors a backup copy at +$500; report the primary
   and note if the backup diverges (a corruption canary).

### Definition of done

- [ ] Reads a `.srm` and reports every party member's full stat block, level,
      EXP (incl. EXP-to-next-level — the pending EXP-offset map lands here),
      names, inventory, equipment, money/ATM, and playtime.
- [ ] Each field is `--find`-verified against a real save, confidence labeled.
- [ ] Emits both a terminal report and a themed `docs/save-report.html`.
- [ ] Flags primary-vs-backup ($+500) divergence.

**Scope:** SRAM-format RE (widen the map) + report/HTML rendering. Pure
read-only tooling — no emulator changes. A strong grok ticket once the field
offsets are `--find`-confirmed.

---

## App 3: Live debug HUD — a second window of SNES internals during play

**Status:** NOT STARTED (play.nim already holds the data).

While `make play` runs the game in the main window, open a **second window**
showing live emulator internals: which controller buttons are pressed, CPU/PPU
state, timing metrics, audio activity — a real-time dashboard for spotting the
render/timing/input bugs in `docs/issues.md` as they happen.

### Why it's buildable now

play.nim already computes everything worth showing — it assembles the SNES
joypad byte each frame (keyboard + paddy gamepad), steps the CPU/PPU per
scanline, runs HDMA, and already has an **F12 PPU-state dump** and an **F10
per-scanline TM/TS/CGADSUB trace**. The HUD is those one-shot dumps promoted to
a continuously-updating panel.

### Components

1. **Second silky window** alongside the game window (windy supports multiple
   windows; silky for the widgets), refreshed each frame.
2. **Panels**, cheapest-first:
   - **Input:** a live SNES pad diagram lighting up pressed buttons — directly
     debugs the #8 input issues (B/X swap, touchy diagonals, dropped taps).
   - **CPU:** PC, A/X/Y, P flags (M/X/emulation), stack pointer, stopped/wai.
   - **PPU:** BG mode, INIDISP brightness, TM/TS main/subscreen masks, CGADSUB/
     CGWSEL color-math state, HDMAEN, scroll — the exact registers behind the
     open rendering bugs (#10 battle band, #12 stuck-bright, #2 iris).
   - **Timing/perf:** emulated FPS, instructions/frame, wall-clock vs. target
     (the #8 "quick taps merge" symptom is an emulated-cadence artifact — this
     panel would show it).
   - **Audio:** APU port I/O + a nonzero-sample / level meter (surfaces the #4
     BGM dropouts live).
3. **Toggle** — a key in play.nim opens/closes the HUD window so it stays
   zero-cost when off.

### Definition of done

- [ ] A second window opens from `make play` (togglable) without disrupting the
      game window or input.
- [ ] Live input diagram + CPU + PPU-register panels update each frame.
- [ ] At least one open issue becomes visibly diagnosable from the HUD (e.g.
      watch CGADSUB during the #12 stuck-bright state, or dropped taps in #8).

**Scope:** play.nim + a silky HUD window. Reuses existing F10/F12 dump logic;
no core-emulator changes, just surfacing state that's already computed.

---

## Ordering (suggested, not binding)

All three are parallel-safe and off the critical path. Rough effort / payoff:

1. **Save report card** — lowest effort (read-only, `sram_info.nim` seed), high
   payoff (verifies SRAM RE, answers "EXP to next level" permanently).
2. **Debug HUD** — medium effort, high payoff (turns `docs/issues.md` bugs from
   guesswork into watch-it-live).
3. **Music jukebox** — most effort (needs the song-table RE) but the most fun,
   and it doubles as the real fix for issue #4's audio coherence.

## See also

- **`docs/llm-plays.md`** — a fourth, meatier app: an **LLM-plays-the-game**
  agent harness where an LLM authors sandboxed Lua (read memory / see screen /
  press buttons, no writes) and revises its own policy. Its own doc because it's
  an agent architecture, not just an observability app — but same spirit, and it
  reuses the save-report's memory map for the readout it shows the model.
</content>
</invoke>
