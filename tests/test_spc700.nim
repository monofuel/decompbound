## SPC700 core verification against SingleStepTests vectors.
## Only runs where the vectors exist (bin/spc700-vectors, gitignored);
## clone with: git clone --depth 1 https://github.com/SingleStepTests/spc700
## bin/spc700-vectors. CI has no vectors and skips.

import
  std/[os, strutils],
  decompbound/spc700,
  tools/run_spc_vectors

const
  VectorDir = "bin/spc700-vectors/v1"

block spcVectorSweep:
  if dirExists(VectorDir):
    var limit = 100
    if getEnv("SPC_VECTOR_LIMIT").len > 0:
      limit = parseInt(getEnv("SPC_VECTOR_LIMIT"))
    var spc = newSpc()
    var failures: seq[string]
    for path in walkFiles(VectorDir / "*.json"):
      let r = spc.runFile(path, limit)
      if r.failed > 0:
        failures.add r.name & ": " & $r.failed & " failed (" & r.firstFailure & ")"
    doAssert failures.len == 0, "\n" & failures.join("\n")
