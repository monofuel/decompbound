import std/[strformat, strutils],
  ../decompbound/[baserom_extract, common, rom_chunks]

proc main() =
  ## Check no residualFree_*, code∩extract=0, free residual stats.
  for s in KnownBaseromExtracts:
    if s.name.startsWith("residualFree_"):
      echo "FORBIDDEN ", s.name
      quit 1
  echo "noBlind residualFree_*: OK"

  var code = newSeq[bool](EarthboundRomSize)
  var claimed = newSeq[bool](EarthboundRomSize)
  var codeB, metaB, freeB = 0
  for c in allRomChunksMeta():
    if c.kind == ckImplementedCode:
      for i in c.offset ..< min(c.offset + c.length, code.len):
        code[i] = true
        claimed[i] = true
      codeB += c.length
    elif c.kind == ckImplementedMeta:
      for i in c.offset ..< min(c.offset + c.length, claimed.len):
        claimed[i] = true
      metaB += c.length

  var overlap = 0
  for s in KnownBaseromExtracts:
    for i in s.offset ..< s.offset + s.length:
      if i < code.len and code[i]:
        overlap += 1
        if overlap <= 5:
          echo &"overlap 0x{i:06X} {s.name}"
  echo &"code∩extract bytes: {overlap}"
  if overlap != 0: quit 1
  echo "code∩extract=0: OK"

  for i in 0 ..< claimed.len:
    if not claimed[i]: freeB += 1

  let total = EarthboundRomSize
  let claimedB = total - freeB
  let pct = 100.0 * claimedB.float / total.float
  echo &"implemented_code: {codeB} B"
  echo &"implemented_meta: {metaB} B"
  echo &"free residual: {freeB} B"
  echo &"claimed coverage: {claimedB}/{total} ({pct:.4f}%)"

when isMainModule:
  main()
