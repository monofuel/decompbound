## 65816 singlestep harness: per-opcode coverage + state verification from
## SingleStepTests vectors (TomHarte). Always runs synthetic vectors for
## core load/step/assert proof. Tallies per-opcode and flags uncovered.
## Real vectors optional/large: do not commit.
## Fetch: git clone --depth 1 https://github.com/SingleStepTests/65816 bin/65816-vectors
## (bin/* is gitignored). Set CPU_VECTOR_LIMIT=0 for full sweep.
## State+RAM asserted; cycles are recorded in vectors but unchecked here.
## Run: nix develop -c nim c -r tests/test_65816_singlestep.nim

import
  std/[os, strutils, json, sequtils, tables],
  decompbound/cpu,
  tools/run_vectors

const
  VectorDir = "bin/65816-vectors/v1"

block syntheticProof:
  ## Hand-written synthetic vectors for simple opcodes (LDA imm, NOP, STA abs).
  ## Prove the harness: json initial -> poke ram+cpu state -> cpu.step -> match final state+ram.
  ## These always execute (no 3GB data needed) and give basic opcode coverage.
  let bus = newBus()
  bus.recordDirty = true  # runOne resets touched RAM between vectors via bus.dirty
  let synthVectors = @[
    %*{
      "name": "synth-ea-nop-e",
      "initial": {
        "pc": 32768, "s": 511, "p": 48, "a": 0, "x": 0, "y": 0,
        "dbr": 0, "d": 0, "pbr": 0, "e": 1,
        "ram": [[32768, 234]]
      },
      "final": {
        "pc": 32769, "s": 511, "p": 48, "a": 0, "x": 0, "y": 0,
        "dbr": 0, "d": 0, "pbr": 0, "e": 1,
        "ram": [[32768, 234]]
      }
    },
    %*{
      "name": "synth-a9-lda-imm8-e",
      "initial": {
        "pc": 32768, "s": 511, "p": 48, "a": 0, "x": 0, "y": 0,
        "dbr": 0, "d": 0, "pbr": 0, "e": 1,
        "ram": [[32768, 169], [32769, 66]]
      },
      "final": {
        "pc": 32770, "s": 511, "p": 48, "a": 66, "x": 0, "y": 0,
        "dbr": 0, "d": 0, "pbr": 0, "e": 1,
        "ram": [[32768, 169], [32769, 66]]
      }
    },
    %*{
      "name": "synth-a9-lda-imm16-n",
      "initial": {
        "pc": 32768, "s": 511, "p": 0, "a": 0, "x": 0, "y": 0,
        "dbr": 0, "d": 0, "pbr": 0, "e": 0,
        "ram": [[32768, 169], [32769, 52], [32770, 18]]
      },
      "final": {
        "pc": 32771, "s": 511, "p": 0, "a": 4660, "x": 0, "y": 0,
        "dbr": 0, "d": 0, "pbr": 0, "e": 0,
        "ram": [[32768, 169], [32769, 52], [32770, 18]]
      }
    },
    %*{
      "name": "synth-8d-sta-abs8-e",
      "initial": {
        "pc": 32768, "s": 511, "p": 48, "a": 171, "x": 0, "y": 0,
        "dbr": 0, "d": 0, "pbr": 0, "e": 1,
        "ram": [[32768, 141], [32769, 1], [32770, 0]]
      },
      "final": {
        "pc": 32771, "s": 511, "p": 48, "a": 171, "x": 0, "y": 0,
        "dbr": 0, "d": 0, "pbr": 0, "e": 1,
        "ram": [[32768, 141], [32769, 1], [32770, 0], [1, 171]]
      }
    }
  ]
  var synthPassed = 0
  for tv in synthVectors:
    let (ok, diff) = runOne(bus, tv)
    doAssert ok, "synthetic " & tv["name"].getStr() & ": " & diff
    synthPassed += 1
  echo "SYNTHETIC: ", synthPassed, " vectors passed (NOP + LDA#8 + LDA#16 + STA abs)"

block vectorCoverage:
  ## Fast coverage: filenames prove which of 256 opcodes have vectors (no full parse).
  ## Exercise a handful of real vectors via runOne on first entry to tally pass/fail
  ## for sampled ops and prove end-to-end with real data. Full per-vector run uses the
  ## run_vectors tool (small limit).
  if dirExists(VectorDir):
    var presentOps: set[uint8]
    var fileCount = 0
    for path in walkFiles(VectorDir / "*.json"):
      fileCount += 1
      let fname = path.extractFilename()
      if fname.len >= 2:
        let op = parseHexInt(fname[0..1]).uint8
        presentOps.incl(op)
    let covered = presentOps.card
    echo "65816 singlestep coverage: ", covered, "/256 opcodes (", fileCount,
      " vector files present)"
    echo "  state+RAM asserted; cycles list present in vectors but unchecked (note for timing)"
    if covered < 256:
      var uncovered: seq[string]
      for i in 0..255:
        if i.uint8 notin presentOps:
          uncovered.add toHex(i.uint8, 2)
      echo "  UNCOVERED (no vector file): ", uncovered.join(" ")
    else:
      echo "  all 256 opcodes have vector data available"

    # Exercise a few real vectors (parse only these; proves harness against real data)
    let bus = newBus()
    bus.recordDirty = true  # runOne resets touched RAM between vectors via bus.dirty
    var sampleFails: seq[string]
    let samples = ["ea.n.json", "a9.n.json", "00.e.json"]
    var sampledOps: seq[uint8]
    for s in samples:
      let p = VectorDir / s
      if fileExists(p):
        let tests = parseFile(p)
        if tests.len > 0:
          let (ok, diff) = runOne(bus, tests[0])
          let op = parseHexInt(s[0..1]).uint8
          sampledOps.add op
          if not ok:
            sampleFails.add s & ": " & diff
    doAssert sampleFails.len == 0, "real vector samples failed: " & sampleFails.join("; ")
    echo "  real sample vectors passed for ops: ", sampledOps.mapIt(toHex(it,2)).join(" ")
  else:
    echo "vectors dir absent: only synthetic coverage (", VectorDir, ")"
    echo "full harness coverage (256 opcodes): git clone --depth 1 https://github.com/SingleStepTests/65816 bin/65816-vectors"
