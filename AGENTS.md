# decompbound

- Earthbound (SNES) decompilation project in Nim.
- This will be a complex and open ended progress, you will need to get creative and may have to make tools to help.

## Copyright hygiene — keep the repo asset-free

This is a decompilation project. Like `n64decomp/sm64` and the OoT decomp, the
repo must contain **NO copyrighted material from the game**. Reverse-engineered
*code* is our own new expression and is fine; the game's *assets and data* are
not. When in doubt, do not commit it.

- **NEVER commit these** (they are the copyrighted work, in whole or in part):
  - **ROM images** — `*.smc` / `*.sfc`, the EarthBound ROM or any slice of it.
  - **Assets extracted from the ROM** — graphics/tiles/palettes, audio (BRR
    samples, music sequences), text/script, maps. These live in the user's own
    ROM and are read at build/run time, never checked in.
  - **Memory or state dumps that embed assets** — APU RAM images, VRAM/CGRAM/OAM
    dumps, savestates, captured audio (`*.wav`), and screenshots / frame
    captures (`*.png`) that show game graphics. A memory dump is a partial copy
    of the ROM — treat it exactly like a ROM slice. This is the easy one to slip
    up on: our own tools generate these constantly.

- **Fine to commit** (our own new expression / functional reproduction):
  - Reverse-engineered **Nim source** and tooling.
  - **Code regions expressed as 65816 mnemonics** through our assembler.
    Byte-matching disassembly is new expression, exactly as the SM64/OoT decomps
    treat it. But **data regions must be declared as data**, never checked in
    with real asset bytes — declare the shape/offset, not the copyrighted
    contents.
  - Tests using checksums, disassembly diffs, or small non-infringing inputs —
    never shipped dumps.

- **The ROM is user-supplied**, always. Every tool reads the user's own legally
  dumped ROM from a local path (the `ROM` var in the Makefile); it is never
  bundled. Users must own the original.

- **Before every commit, confirm nothing slipped in** — run `git status` and
  check for ROMs, assets, dumps, `*.wav`, `*.png`, or savestates. All generated
  captures must land under `bin/` (git-ignored) or otherwise be gitignored; if
  you add a tool that writes a capture, make sure its output path is ignored
  before you run it.

- Full reasoning + legal precedents (Sega v. Accolade, Sony v. Connectix, § 117)
  live in `docs/copyright-notes.md`. We are not lawyers — this is the practical
  policy that keeps us in the "tolerated clean decomp" lane.

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
