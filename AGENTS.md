# decompbound

Read [GOAL.md](GOAL.md) for the canonical five goals, completion criteria, and
investigation loop. Older goal numbering in topic docs is historical.

**Leave the code better than you found it.** Follow the
[maintenance rules in GOAL.md](GOAL.md#leave-the-code-better-than-you-found-it):
consolidate stale docs, retire completed probes after preserving their evidence,
and verify that tests exercise meaningful behavior and actually run. Keep cleanup
scoped to the task and never weaken the referee to obtain a passing result.

- Earthbound (SNES) decompilation project in Nim.
- This will be a complex and open ended progress, you will need to get creative and may have to make tools to help.

## Audible tests — immediate permission required

**Never produce audible output on monofuel's devices without his explicit,
immediate permission for that specific run.** This includes game playback,
music, tones and alarms during tests. General authorization to implement,
profile, test or deploy does not authorize speaker output. Earlier audio
permission does not carry forward to later runs.

Default automated player tests to `--mute` or a verified null audio backend.
Core PCM generation, capture and hash comparison can run without speakers.
Human-verify launch instructions are for monofuel; agents must not treat them
as permission to run audible checks. Stop approved audible runs promptly and
restore the menu afterward.

Human manual tests use normal game audio unless monofuel requests silence. An
explicit request for a particular manual playback session authorizes its normal
audio; general implementation or automated-test requests do not. Human-run launch
targets and instructions must not force mute. Agents running automated checks
must select `--mute` or a verified null backend themselves.

## Vanilla ROM gate (phase 2)

`generated/*` bank modules are **gone** (M2.5). Vanilla rebuild is:

```
nim r src/tools/rom_extract.nim
nim r src/tools/rom_rebuild.nim    # must print BYTE-IDENTICAL
```

or `make compare`. Prefer targeted `nim r tests/test_*.nim`; `make test` is fine.
`make test-banks` is a retired no-op. Details:
[`docs/decompilation-phase2.md`](docs/decompilation-phase2.md).

## Tools vs probes (keep `src/tools/` clean)

| Path | What goes here |
|------|----------------|
| **`src/tools/`** | Product tools only (`play`, `llm_ai`, `story_percents`, extractors, …). Ship-quality. |
| **`src/probes/`** | One-off RE digs, LLM-play experiments, `probe_*.nim`, fixture `synth_*.nim`. Agents create digs **here only**. |

- Run digs: `nim r src/probes/probe_foo.nim`
- Digs import product modules via `../tools/[…]` and `../decompbound/[…]`.
- When a dig graduates to product: move logic into `src/tools/` (or `src/decompbound/`), add a real test, delete or slim the probe.
- Do **not** dump new probes next to `play.nim` / `llm_ai.nim`.

## Delegate — and be proactive about it

Fan bounded work out to sub-agents rather than doing it all inline: when an RE
dig, a new tool, or a self-contained feature lands, spawn a child right away
and keep the pipeline full. The conductor sets goals, verifies, and re-drives
children that stop at "lmk if you want me to continue."

**Read `docs/delegation.md` before dispatching** — it holds this repo's verify
bars, contended files, task shapes, and the brief template, and links out to
the org chart (who/which model) and the sub-agent mechanics (worktrees,
parallel safety) in racha_notes.

The four rules you must not get wrong, stated here so they survive a missing
notes mount:

- **Never merge, commit, or trust on a worker's self-report** — re-run the gate.
- **The referee is sacred**: `compare.nim`, `tests/`, `opcodes.nim`.
- **Workers do not push.** Shipping is a conductor duty after green gates.
- **Copyright hygiene applies to every delegated diff** (see below) — agents
  must refuse to commit ROM slices, save-states, SRAM, uncurated screenshots,
  or extracted assets. The README screenshot exception below applies to workers.

Needs human eyes (play feel, visual, audio)? Add a row to
**`docs/human-verify.md`** (**Run** + **Pass if**) — never chat-only; monofuel
will have moved on. Bugs he finds in play land under **Found in play** there;
promote durable ones to `docs/issues.md`.

## State-screenshots (F12) — default location

**Do not look in `bin/` for play F12s.** Live-play screenshots land outside the
repo, under monofuel's home Pictures folder.

| | |
|---|---|
| **Dir** | `~/Pictures/Screenshots/` (absolute: `/home/monofuel/Pictures/Screenshots/`) |
| **Names** | `earthbound_yyyyMMdd-HHmmss.png` |
| **Payload** | PNG with an embedded compressed save-state in a private ancillary chunk **`ebSt`** (`png_state.nim` / `save_state.nim`) |
| **Writer** | `src/tools/play.nim` → F12 → `saveScreenshot` |
| **Restore** | drag-drop the PNG onto the play window (or load via tools that accept ebSt PNGs) |

**mono-retro-player sessions are separate:** its F12/exit screenstates and
five-second images are generated under `SAVE_DIR/captures/session-*/` (override
with `--capture-dir`). The player prints that path. With this repo's DS launch
target, the default is ignored `bin/libretro/earthbound-ds-saves/captures/`.
Those generated sessions remain private and must never be staged. This does
not move or change the standalone archive above; never copy its original F12s
into the repo. See `docs/state-screenshots.md` and `docs/libretro.md`.

When monofuel (or human-verify) names an F12 like `earthbound_20260708-191042.png`,
resolve it under **`~/Pictures/Screenshots/`** first. Repo `bin/` only has a few
tool/test PNGs (round-trips, probes); that is **not** the play capture archive.

- **List shots that carry state:** scan for the `ebSt` chunk (or open large
  `earthbound_*.png` files — plain image-only PNGs are much smaller).
- **NEVER commit F12s, and never copy them into the repo for a commit.** They
  are user-local: game **screenshots** (graphics) **plus** a full **save-state**
  in `ebSt`. Both halves are forbidden (see Copyright hygiene below). Keep them
  under `~/Pictures/Screenshots/`; do not move them into `bin/`, `docs/`, or
  any tracked path “just to attach a milestone.”
- **Progress / milestones in git:** empty bookmark commits, text in `docs/`,
  or chat — **not** the PNG. Reference the filename in prose if useful; leave
  the file on disk outside the tree.
- Design/background: `docs/state-screenshots.md`.

## Copyright hygiene — no game assets; curated README screenshots only

This is a decompilation project. Like `n64decomp/sm64` and the OoT decomp, the
repo ships our own reverse-engineered code, tools, and docs. The user supplies
their own legally dumped ROM; game assets are extracted at build/run time and
never committed. The sole presentation exception is a few curated, image-only
screenshots illustrating features in `README.md`, as specified below.
When in doubt, do not commit it.

**The line: the code is ours, the data is theirs.**

### By hand, from scratch — community docs are references, not sources

We are NOT using CoilSnake or any other external tool/codebase — no imported
code, no imported data, no generated assets from third-party tooling.
Everything here is reverse-engineered by hand in Nim against the user's own
ROM and our own emulator. Community documentation (CoilSnake's format notes,
fullsnes, romhacking wikis) is fine as a **reference or hypothesis source**,
but nothing ships until it is independently derived and verified with our own
evidence: disasm at named file offsets, live-WRAM cross-checks, byte-exact
round trips. Cite our offsets and probes in docs — not external tools.

### Curated README screenshots — narrow exception

- Allow a small set of screenshots under `docs/images/`, each used in the root
  `README.md` to demonstrate a project feature, with explanatory text or a caption.
- Export a fresh image from decoded pixels. Never add an original F12 PNG:
  those contain an `ebSt` save-state even though ordinary image viewers hide it.
- Before inclusion, decode the exported image and inspect its PNG chunks.
  Curated PNGs must contain only `IHDR`, `IDAT`, and `IEND`; no `ebSt`, text,
  arbitrary metadata, trailing payload, or other embedded state/memory data.
- Keep the selection explicit in `.gitignore` and document its purpose in
  `docs/images/README.md`. This is not permission for asset galleries, sprite
  sheets, tile/palette dumps, bulk captures, audio, or reusable game assets.
- Screenshots illustrate the project; they are not project-owned game artwork
  and do not become covered by the source-code license. This project policy
  does not assert permission from the game's rightsholders or guaranteed fair use.

### Save-states, SRAM, and other captures — hard ban

These are the easy, high-frequency slip. Treat them as **non-negotiable**:

| Kind | Examples | Why banned |
|------|----------|------------|
| **Uncurated screenshots** | F12 / play captures, bulk captures, game images outside the README exception above | Game art; only the small README selection is allowed |
| **Save-states** | `bin/states/slot*.state`, `*.state`, raw serialize blobs, APU/VRAM dumps used as “fixtures” | Full machine memory — ROM-derived WRAM, VRAM, APU RAM, OAM, script state — a **partial copy of the game**, not our code |
| **State-screenshots** | F12 PNGs with **`ebSt`** chunk | **Both**: pixels *and* an embedded save-state. Worst of both worlds |
| **Battery SRAM** | `*.srm`, e.g. `bin/Earthbound (U) [!].srm`, `bin/sram_backups/**` | The game’s own save file — party, story flags, inventory — copyrighted game data the cart would hold |

**Especially save-states:** do not commit them “for CI,” “for a bug report,” or
“as a milestone.” Private local use and git-ignored paths only. If a test needs
a machine image, generate it at test time from the **user’s ROM** + our code,
or use **tiny synthetic** buffers — never check in a real EB save-state. Full
reasoning: `docs/copyright-notes.md` (savestates section).

**SRAM** is the same class of ban as save-states for repo hygiene: never commit
real battery saves. Format docs and *empty/synthetic* test bytes are fine; a
player’s `.srm` is not. Already gitignored as `*.srm`.

**Agents must refuse** requests to `git add` / commit save-states, screenstates,
SRAM (`.srm`), or screenshots outside the README exception. Record milestones
with empty commits or docs text; keep the underlying capture local.

- **Committable — our own new expression / functional reproduction:**
  - Reverse-engineered **Nim source** and tooling.
  - **Annotated 65816 disassembly** — code expressed as mnemonics through our
    assembler, with our labels, comments, and cross-references. Byte-matching
    disassembly of *code* is transformative new expression (same basis as
    SM64/OoT), and the annotation is the added authorship. This is the whole
    point of the project — it is fine, and it is safe to commit.
  - **Interpreters / engines** — the code that *reads* scripts, graphics, and
    audio is code. Reverse the engine; commit it. (Then extract the data — see
    below.)
  - **Format documentation + codecs** — how the data is laid out, and the
    encode/decode logic. The *description* of a format is ours; the *contents*
    are not.
  - Tests using checksums, disasm diffs, or tiny synthetic inputs.

- **NEVER commit — the copyrighted work, in whole or in part:**
  - **ROM images** — `*.smc` / `*.sfc`, or any slice of the ROM.
  - **Screenshots outside the curated README exception** — see the rules above.
    Repo root `/*.png` remains ignored; original F12 captures are never allowed.
  - **Save-states and emulator memory dumps** — `*.state`, `bin/states/**`,
    F12 **`ebSt`** payloads, savestates used as fixtures, APU RAM / VRAM /
    CGRAM / OAM dumps that came from real play. **Especially do not commit
    save-states** — they are wholesale copies of game-derived memory, not
    “just debug files.”
  - **Battery SRAM** — `*.srm`, play battery saves next to the ROM, rotating
    backups under `bin/sram_backups/`. Real player progress / story data; never
    commit. (Format documentation of the SRAM layout is fine; the *bytes* are not.)
  - **Game scripts** — dialogue text (a literary work) *and* the event/script
    data (cutscene logic, flags, sequences — creative expression). Reversing the
    script **interpreter** is fine; the **extracted script content is a
    copyrighted asset**, exactly like graphics or music. No dialogue dumps, no
    event blobs, ever — "see the scripts" means *run the extractor on your ROM*,
    not *open a file in the repo*.
  - **Other extracted assets** — graphics/tiles/palettes, audio (BRR samples,
    song sequences), maps, and any data-region bytes. Declare a data region's
    shape/offset in source; never check in the real asset bytes.
  - **Other memory / capture dumps** — captured `*.wav`, partial RAM slices.
    A dump is a partial copy of the ROM — treat it like a ROM slice. Our own
    tools generate these constantly; this is the easy slip.

- **The build-time extraction pattern** (how real decomps stay clean): the repo
  ships the *extractor/codec*; the **user's own ROM** is the source of the bytes;
  extraction runs at build/run time and its output lands in a **git-ignored**
  path (`bin/` or `extracted/`), never committed. A `make` step turns the user's
  baserom into assets/scripts locally. Curated README illustrations are the
  only exception to the repository's exclusion of game imagery.

- **The ROM is always user-supplied** (the `ROM` var in the Makefile); it is
  never bundled. Users must own the original.

- **Before every commit, confirm nothing slipped in** — `git status` for ROMs,
  `*.state` / `bin/states/`, `*.srm` / `bin/sram_backups/`, F12 /
  `earthbound_*.png`, extracted scripts/assets, dumps, `*.wav`, other `*.png`.
  Verify each curated README PNG's chunk structure separately before inclusion.
  If you add a tool that writes screenshots, save-states, SRAM, or extracted
  data, point its output at a **git-ignored** path first (and never stage those
  paths).

- Full reasoning + precedents (Sega v. Accolade, Sony v. Connectix, § 117, plus
  the asm-disassembly and script-extraction specifics) live in
  `docs/copyright-notes.md`. We are not lawyers — this is the practical policy
  that keeps us in the "tolerated clean decomp" lane.

- we should avoid magic bytes as much as possible and instead figure out what they are representing properly.
  - but it's ok to hard code some magic bytes to get the ball rolling.
  - incremental process.
  - all magic bytes must be accompanied by a TODO and comments 

## Dependencies

- Nim >= 2.0.0

- pixie >= 5.1.0
- shady >= 0.1.4
- silky

## Tests

- Run `nimble test` to run all tests
- Individual test files can be run individually `nim r tests/test_*.nim` 

## Nim

## Nim best practices

**Prefer letting errors bubble up naturally** - Nim's stack traces are excellent for debugging:

Default approach - let operations fail with full context:
```nim
# Simple and clear - if writeFile fails, we get a full stack trace
writeFile(filepath, content)

# Database operations - let them fail with complete error information
db.exec(sql"INSERT INTO users (name) VALUES (?)", username)
```

For validation and early returns, check conditions explicitly:
```nim
# Check preconditions and exit early with clear messages
if not fileExists(parentDir):
  error "Parent directory does not exist"
  quit(1)

if username.len == 0:
  error "Username cannot be empty"
  quit(1)

# Now proceed with the operation
writeFile(filepath, content)
```

This approach ensures full stack traces in CI environments and makes debugging straightforward.

### Nim Imports

- std imports should be first, then libraries, and then local imports
- use [] brackets to group when possible
- split imports on newlines
for example,
```
import
  std/[strformat, strutils],
  debby/[pools, postgres],
  ./[models, logs, llm] 
```

### Nim Procs

- do not put comments before functions! comments go inside functions.
- every proc should have a nimdoc comment
- nimdoc comments start with ##
- nimdoc comments should be complete sentences followed by punctuation
for example,
```
proc sumOfMultiples(limit: int): int =
  ## Calculate the sum of all multiples of 3 or 5 below the limit.
  var total = 0
  for i in 1..<limit:
    if i mod 3 == 0 or i mod 5 == 0:
      total += i
  return total
```

### Nim Properties

- if an object property is the same name as a nim keyword, you must wrap it in backticks
```
  DeleteModelResponse* = ref object
    id*: string
    `object`*: string
    deleted*: bool
```

### Variables

- please group const, let, and var variables together.
- please prefer const over let, and let over var.
- please use capitalized camelCase for consts
- use regular camelcase for var and let
- do not place 'magic variables' in the code, instead make them a const and pull them up to the top of the file
- for example:

```
const
  Version = "0.1.0"
  Model = "llama3.2:1b"
let
  embeddingModel = "nomic-embed-text"
```

## Programming

- Don't use try/catch unless you have a very, very good reason to be handling the error at this level.
- never mask errors with catch: discard
- it's OK to allow errors to bubble up. we want things to be easy to debug and fail fast.
- returning in the middle of files is confusing, avoid doing it.
  - early returns at the start of the file is ok.
- try to make things as idempotent as possible. if a job runs every day, we should make sure it can be robust.
- never use booleans for 'success' or 'error'. If a function was successful, return nothing and do not throw an error. if a function failed, throw an error.

### Comments

- functions should have doc comments
- however code should otherwise not need comments. functions should be named properly and the code should be readable.
- comments may be ok for 'spooky at a distance' things in rare cases.
- comments should be complete sentences that are followed with a period.
