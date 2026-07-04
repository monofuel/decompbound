## CPU core verification against SingleStepTests 65816 vectors.
## Only runs where the vectors exist (bin/65816-vectors, gitignored, ~3GB);
## clone with: git clone --depth 1 https://github.com/SingleStepTests/65816
## bin/65816-vectors. CI has no vectors and skips, like the gold ROM tests.

import
  std/[os, strutils],
  decompbound/cpu,
  tools/run_vectors

const
  VectorDir = "bin/65816-vectors/v1"

block vectorSweep:
  if dirExists(VectorDir):
    # Limit per file keeps the suite fast for routine runs; set
    # CPU_VECTOR_LIMIT=0 for the full milestone sweep.
    var limit = 100
    if getEnv("CPU_VECTOR_LIMIT").len > 0:
      limit = parseInt(getEnv("CPU_VECTOR_LIMIT"))
    let bus = newBus()
    var failures: seq[string]
    for path in walkFiles(VectorDir / "*.json"):
      let r = runFile(bus, path, limit)
      if r.failed > 0:
        failures.add r.name & ": " & $r.failed & " failed (" & r.firstFailure & ")"
    doAssert failures.len == 0, "\n" & failures.join("\n")
