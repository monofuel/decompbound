## Per-chunk gold validation for sub-agent briefs.
##
## Usage (from repo root, gold ROM at bin/Earthbound (U) [!].smc):
##   nim r src/tools/chunk_check.nim summary
##   nim r src/tools/chunk_check.nim list [--kind implemented_code|implemented_meta|unclaimed]
##   nim r src/tools/chunk_check.nim check <chunk_id>
##   nim r src/tools/chunk_check.nim check-all-implemented
##
## Exit codes:
##   0 — success (match, or unclaimed classification, or list/summary)
##   1 — usage / unknown chunk
##   2 — implemented chunk gold mismatch or missing built bytes
##   3 — gold ROM missing / bad size (only for check commands that need gold)
##
## Never writes ROM bytes or extracted assets. See docs/rom-chunks.md.

import
  std/[os, strformat, strutils],
  ../decompbound/[common, rom_chunks]

const
  GoldPath = "bin/Earthbound (U) [!].smc"

proc usage() =
  ## Print CLI help.
  echo """chunk_check — full-ROM typed chunks + per-chunk gold check

  nim r src/tools/chunk_check.nim summary
  nim r src/tools/chunk_check.nim list [--kind KIND]
  nim r src/tools/chunk_check.nim check <chunk_id>
  nim r src/tools/chunk_check.nim check-all-implemented

KIND: implemented_code | implemented_meta | unclaimed

Agent brief: pick one chunk_id from list, then:
  nim r src/tools/chunk_check.nim check <chunk_id>
Expect exit 0 and a line containing "OK match" for implemented chunks.
"""

proc parseKind(s: string): ChunkKind =
  ## Parse kind name from CLI.
  case s
  of "implemented_code": ckImplementedCode
  of "implemented_meta": ckImplementedMeta
  of "unclaimed": ckUnclaimed
  else:
    raise newException(ValueError, "unknown kind: " & s)

proc cmdSummary() =
  ## Print inventory size totals by kind (metadata only — no bank assemble).
  let chunks = allRomChunksMeta()
  doAssert inventoryCoversRom(chunks)
  let totals = totalBytesByKind(chunks)
  var nCode, nMeta, nUncl = 0
  for c in chunks:
    case c.kind
    of ckImplementedCode: inc nCode
    of ckImplementedMeta: inc nMeta
    of ckUnclaimed: inc nUncl
  echo &"rom_chunks: {chunks.len} chunks covering {EarthboundRomSize} bytes"
  echo &"  implemented_code: {nCode} chunks, {totals[ckImplementedCode]} bytes"
  echo &"  implemented_meta: {nMeta} chunks, {totals[ckImplementedMeta]} bytes"
  echo &"  unclaimed:        {nUncl} chunks, {totals[ckUnclaimed]} bytes"
  echo &"  implemented total: {totals[ckImplementedCode] + totals[ckImplementedMeta]} bytes " &
    &"({100.0 * float(totals[ckImplementedCode] + totals[ckImplementedMeta]) / float(EarthboundRomSize):.2f}% of ROM)"

proc cmdList(kindFilter: string) =
  ## List chunk ids (optionally filtered by kind). Metadata only.
  let chunks = allRomChunksMeta()
  var want: set[ChunkKind] = {ckImplementedCode, ckImplementedMeta, ckUnclaimed}
  if kindFilter.len > 0:
    want = {parseKind(kindFilter)}
  for c in chunks:
    if c.kind in want:
      echo &"{c.id}\tkind={kindName(c.kind)}\toffset=0x{c.offset:06X}\tlen={c.length}"

proc statusExitCode(st: ChunkCheckStatus): int =
  ## Map check status to process exit code.
  case st
  of ccsMatch, ccsUnclaimed: 0
  of ccsMismatch, ccsMissingBuilt: 2
  of ccsNoGold, ccsBadGoldSize: 3

proc cmdCheck(id: string) =
  ## Check one chunk against gold (built from decomp ROM when needed).
  let chunks = allRomChunksMeta()
  var chunk = findChunk(chunks, id)
  let r = checkChunkAgainstGoldFile(chunk, GoldPath)
  echo r.message
  quit(statusExitCode(r.status))

proc cmdCheckAllImplemented() =
  ## Gold-check every implemented chunk against decomp ROM; fail on first mismatch.
  if not fileExists(GoldPath):
    echo &"gold ROM missing at {GoldPath}"
    quit(3)
  if not fileExists(DecompRomPath):
    echo &"decomp ROM missing at {DecompRomPath} (run make build)"
    quit(2)
  let gold = readFile(GoldPath)
  let decomp = readFile(DecompRomPath)
  if gold.len != EarthboundRomSize or decomp.len != EarthboundRomSize:
    echo "ROM size mismatch for gold/decomp"
    quit(3)
  let chunks = allRomChunksMeta()
  var ok, fail, skip = 0
  for c in chunks:
    if c.kind == ckUnclaimed:
      inc skip
      continue
    var filled = c
    filled.built = newSeq[uint8](c.length)
    for i in 0..<c.length:
      filled.built[i] = decomp[c.offset + i].uint8
    let r = checkChunkAgainstGold(filled, gold)
    if r.status == ccsMatch:
      inc ok
    else:
      echo r.message
      inc fail
      quit(statusExitCode(r.status))
  echo &"check-all-implemented: {ok} matched, {skip} unclaimed skipped, {fail} failed"
  quit(0)

proc main() =
  ## CLI entry.
  let args = commandLineParams()
  if args.len == 0:
    usage()
    quit(1)
  case args[0]
  of "summary":
    cmdSummary()
  of "list":
    var kind = ""
    var i = 1
    while i < args.len:
      if args[i] == "--kind" and i + 1 < args.len:
        kind = args[i + 1]
        i += 2
      else:
        echo "unknown list arg: ", args[i]
        quit(1)
    cmdList(kind)
  of "check":
    if args.len < 2:
      echo "usage: check <chunk_id>"
      quit(1)
    cmdCheck(args[1])
  of "check-all-implemented":
    cmdCheckAllImplemented()
  of "help", "-h", "--help":
    usage()
  else:
    echo "unknown command: ", args[0]
    usage()
    quit(1)

when isMainModule:
  main()
