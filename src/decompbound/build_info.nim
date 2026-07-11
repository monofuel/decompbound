## Build provenance baked in at COMPILE time (staticExec), so every binary
## self-reports the exact source it was built from — no runtime git query that
## could drift from the running binary. Used to stamp screenstates, replays,
## and session logs with a commit, answering "what version produced this?".
## staticExec runs where nim is invoked (repo root for `make`/`nim r`); if git
## is unavailable it degrades to "unknown".

import
  std/strutils

const
  BuildCommit* = staticExec("git rev-parse --short=10 HEAD 2>/dev/null").strip()
    ## Short commit of the tree this binary was compiled from ("" if no git).
  BuildDirty* = staticExec("git status --porcelain 2>/dev/null").strip().len > 0
    ## True if the working tree had uncommitted changes at build time.
  BuildDate* = staticExec("date -u +%Y-%m-%dT%H:%M:%SZ").strip()
    ## UTC build timestamp (helps when the tree was dirty).

proc buildLabel*(): string =
  ## Compact one-line build id, e.g. "a1b2c3d4e5" or "a1b2c3d4e5+dirty".
  result = if BuildCommit.len > 0: BuildCommit else: "unknown"
  if BuildDirty:
    result &= "+dirty"
