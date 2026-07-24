# decompbound

- Earthbound (SNES) decompilation project in Nim.
- This will be a complex and open ended progress, you will need to get creative and may have to make tools to help.

## Tools vs probes (keep `src/tools/` clean)

| Path | What goes here |
|------|----------------|
| **`src/tools/`** | Product tools only (`play`, `llm_ai`, `story_percents`, extractors, …). Ship-quality. |
| **`src/probes/`** | One-off RE digs, LLM-play experiments, `probe_*.nim`, fixture `synth_*.nim`. Agents create digs **here only**. |

- Run digs: `nim r src/probes/probe_foo.nim`
- Digs import product modules via `../tools/[…]` and `../decompbound/[…]`.
- When a dig graduates to product: move logic into `src/tools/` (or `src/decompbound/`), add a real test, delete or slim the probe.
- Do **not** dump new probes next to `play.nim` / `llm_ai.nim`.

## Delegate via Grok 4.5 sub-agents — and be proactive about it

Most substantive work should be **fanned out to Grok Build native sub-agents**
(`spawn_subagent`). One Grok 4.5 top session is the conductor: it sets goals,
verifies results, and re-drives incomplete children. Be *responsive*: when a
bounded task lands (an RE dig, a new tool, a self-contained feature), spawn a
child right away rather than doing it all inline or queuing it. Keep the
pipeline full — when a wave lands, verify it and dispatch the next.

- **Workers do:** ROM/format reverse-engineering (report offsets + format —
  *analysis only*, never commit assets / ROM / dumps) and bounded build tasks
  (new tools, self-contained features, adoptions). Prefer `explore` for pure
  RE; `general-purpose` for write work; **worktree isolation** when parallel
  writers would collide (see `docs/delegation.md` → Worktrees).
- **Conductor keeps:** final verify/merge calls, emulator-correctness +
  risky/timing ownership, and **re-running every worker result against the gold
  harness before trusting, committing, or pushing** — this has repeatedly
  caught real bugs. Never merge on a worker's self-report. The referee
  (`compare.nim`, `tests/`, opcode table) is sacred.
- **How:** self-contained briefs (task + verification bar + handoff fields).
  Children get no chat history. Parent re-drives ~70% bail-outs until green.
- **Parallel-safety:** don't let concurrent children edit the same shared file
  (e.g. the Makefile) — they clobber each other. Have them build/verify via
  `nim r` / targeted tests directly; conductor adds shared make targets afterward.
- **Commit / push:** conductor duty after gates are green and copyright hygiene
  is clean. Workers do not push; they do not commit unless the brief says so.
  Prefer focused commits; push when the user/session asks to ship. Details in
  `docs/delegation.md` → Commit and push.
- **Human verify:** monofuel plays and often skips chat "please test this."
  Anything that needs human eyes goes in **`docs/human-verify.md`** as a short
  checkbox (**Run** + **Pass if** only) — never chat-only. New bugs he finds
  while playing land under **Found in play** there; promote durable ones to
  `docs/issues.md`. See that file's "For agents" section.
- **`agnt`:** optional dogfood / cross-harness only — not the default worker lane.

See `docs/delegation.md` for the fuller playbook.

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

## Copyright hygiene — keep the repo asset-free

This is a decompilation project. Like `n64decomp/sm64` and the OoT decomp, the
repo must contain **NO copyrighted content from the game** — only our own
reverse-engineered code, tools, and docs. The user supplies their own legally
dumped ROM; everything copyrighted is extracted from it at build/run time and
never committed. When in doubt, do not commit it.

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

### Screenshots, save-states, and SRAM — hard ban (especially save-states)

These are the easy, high-frequency slip. Treat them as **non-negotiable**:

| Kind | Examples | Why banned |
|------|----------|------------|
| **Screenshots** | F12 / play captures, `earthbound_*.png`, any `*.png` / `*.jpg` of in-game graphics | Literal game art (tiles, sprites, UI, text rendering) |
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

**Agents must refuse** requests to `git add` / commit screenshots, save-states,
or SRAM (`.srm`). Record milestones with empty commits or docs text; keep the
file local.

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
  - **Screenshots of the game** — any still of rendered graphics (see table
    above). Repo root `/*.png` is already gitignored for this reason.
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
  baserom into assets/scripts locally; the repo stays asset-free.

- **The ROM is always user-supplied** (the `ROM` var in the Makefile); it is
  never bundled. Users must own the original.

- **Before every commit, confirm nothing slipped in** — `git status` for ROMs,
  `*.state` / `bin/states/`, `*.srm` / `bin/sram_backups/`, F12 /
  `earthbound_*.png`, extracted scripts/assets, dumps, `*.wav`, other `*.png`.
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
