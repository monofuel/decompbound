## Patch bin/Decompbound.smc with wave105 extract gold slices.
import
  std/[os, strformat, strutils],
  ../decompbound/[baserom_extract, common]

proc main() =
  ## Write gold bytes for every wave105 extract claim into the decomp image.
  let path = "bin/Decompbound.smc"
  let raw = readFile(path)
  var rom = newSeq[uint8](raw.len)
  for i, c in raw:
    rom[i] = c.uint8
  if rom.len == EarthboundRomSize + 512:
    rom = rom[512 .. ^1]
  doAssert rom.len == EarthboundRomSize
  let gold = readGoldBaseromBytes()
  var patched = 0
  var spans = 0
  for s in allBaseromExtractSpans():
    if "w105" notin s.name and "wave105" notin s.name:
      continue
    for i in 0 ..< s.length:
      rom[s.offset + i] = gold[s.offset + i]
    patched += s.length
    spans += 1
  writeFile(path, rom)
  echo &"patched {spans} spans / {patched} B into {path}"

  var tot = 0
  var matchc = 0
  for s in allBaseromExtractSpans():
    if "w105" notin s.name and "wave105" notin s.name:
      continue
    for i in 0 ..< s.length:
      inc tot
      if rom[s.offset + i] == gold[s.offset + i]:
        inc matchc
  echo &"wave105 exact: {matchc}/{tot}"
  if matchc != tot:
    quit(1)

main()
