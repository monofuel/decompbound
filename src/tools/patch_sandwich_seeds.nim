## Patch Decompbound.smc with sandwich-seed bank regions (no full rebuild).
## Usage: nim r -d:release src/tools/patch_sandwich_seeds.nim

import
  std/[os, strformat],
  ../decompbound/[baserom_extract, common],
  ../decompbound/generated/[code_bank00, code_bank19, code_bank26]

proc patchBank(rom: var seq[uint8]; offset: int; data: seq[uint8]) =
  ## Write assembled region bytes into the ROM image.
  doAssert offset + data.len <= rom.len, &"patch overflow @0x{offset:06X}"
  for i, b in data:
    rom[offset + i] = b

proc main() =
  ## Rebuild sandwich-seed regions into bin/Decompbound.smc.
  let path = "bin/Decompbound.smc"
  var rom: seq[uint8]
  if fileExists(path):
    let raw = readFile(path)
    rom = newSeq[uint8](raw.len)
    for i, c in raw:
      rom[i] = c.uint8
    if rom.len == EarthboundRomSize + 512:
      rom = rom[512 .. ^1]
  else:
    rom = newSeq[uint8](EarthboundRomSize)
  doAssert rom.len == EarthboundRomSize

  let regions = [
    (0x009EEB, generateCode009EEB()),
    (0x00B461, generateCode00B461()),
    (0x19621E, generateCode19621E()),
    (0x260393, generateCode260393()),
  ]
  var patched = 0
  for (off, data) in regions:
    patchBank(rom, off, data)
    patched += data.len
    echo &"  patched 0x{off:06X}+{data.len}"

  writeFile(path, rom)
  echo &"wrote {path} ({rom.len} bytes); patched {patched} B"

  let gold = readGoldBaseromBytes()
  var tot, matchc = 0
  for (off, data) in regions:
    for i, b in data:
      inc tot
      if gold[off + i] == b: inc matchc
  echo &"patched regions exact: {matchc}/{tot}"
  if matchc != tot: quit(1)

  # Whole-ROM exactness of currently-built image (patched regions + prior).
  var exact = 0
  for i in 0..<gold.len:
    if rom[i] == gold[i]: inc exact
  let pct = 100.0 * exact.float / gold.len.float
  echo &"full image exact: {exact}/{gold.len} ({pct:.4f}%)"

when isMainModule:
  main()
