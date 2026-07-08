# decompbound

- Earthbound (SNES) decompilation project in Nim.
- This will be a complex and open ended progress, you will need to get creative and may have to make tools to help.

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
  RE; `general-purpose` for write work; worktree isolation when parallel
  writers would collide.
- **Conductor keeps:** final verify/merge calls, emulator-correctness +
  risky/timing ownership, and **re-running every worker result against the gold
  harness before trusting or committing** — this has repeatedly caught real bugs.
  Never merge on a worker's self-report. The referee (`compare.nim`, `tests/`,
  opcode table) is sacred.
- **How:** self-contained briefs (task + verification bar + handoff fields).
  Children get no chat history. Parent re-drives ~70% bail-outs until green.
- **Parallel-safety:** don't let concurrent children edit the same shared file
  (e.g. the Makefile) — they clobber each other. Have them build/verify via
  `nim r` / targeted tests directly; conductor adds shared make targets afterward.
- **`agnt`:** optional dogfood / cross-harness only — not the default worker lane.

See `docs/delegation.md` for the fuller playbook.

## Copyright hygiene — keep the repo asset-free

This is a decompilation project. Like `n64decomp/sm64` and the OoT decomp, the
repo must contain **NO copyrighted content from the game** — only our own
reverse-engineered code, tools, and docs. The user supplies their own legally
dumped ROM; everything copyrighted is extracted from it at build/run time and
never committed. When in doubt, do not commit it.

**The line: the code is ours, the data is theirs.**

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
  - **Game scripts** — dialogue text (a literary work) *and* the event/script
    data (cutscene logic, flags, sequences — creative expression). Reversing the
    script **interpreter** is fine; the **extracted script content is a
    copyrighted asset**, exactly like graphics or music. No dialogue dumps, no
    event blobs, ever — "see the scripts" means *run the extractor on your ROM*,
    not *open a file in the repo*.
  - **Other extracted assets** — graphics/tiles/palettes, audio (BRR samples,
    song sequences), maps, and any data-region bytes. Declare a data region's
    shape/offset in source; never check in the real asset bytes.
  - **Memory / state dumps that embed assets** — APU RAM images, VRAM/CGRAM/OAM
    dumps, savestates, captured `*.wav`, screenshots/`*.png` of game graphics. A
    dump is a partial copy of the ROM — treat it like a ROM slice. Our own tools
    generate these constantly; this is the easy slip.

- **The build-time extraction pattern** (how real decomps stay clean): the repo
  ships the *extractor/codec*; the **user's own ROM** is the source of the bytes;
  extraction runs at build/run time and its output lands in a **git-ignored**
  path (`bin/` or `extracted/`), never committed. A `make` step turns the user's
  baserom into assets/scripts locally; the repo stays asset-free.

- **The ROM is always user-supplied** (the `ROM` var in the Makefile); it is
  never bundled. Users must own the original.

- **Before every commit, confirm nothing slipped in** — `git status` for ROMs,
  extracted scripts/assets, dumps, `*.wav`, `*.png`, savestates. If you add a
  tool that writes extracted data, point its output at a git-ignored path first.

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
