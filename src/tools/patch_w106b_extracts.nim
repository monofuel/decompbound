## Patch bin/Decompbound.smc with wave106b carve extract gold slices.
import
  std/[os, strformat, strutils],
  ../decompbound/[baserom_extract, common]

proc main() =
  ## Write gold bytes for every wave106b carve claim into the decomp image.
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
    if "carve_w106b" notin s.name:
      continue
    for i in 0 ..< s.length:
      rom[s.offset + i] = gold[s.offset + i]
    patched += s.length
    spans += 1
  writeFile(path, rom)
  echo &"patched {spans} spans / {patched} B into {path}"

main()
