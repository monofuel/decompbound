## Patch Decompbound.smc with reassembled banks that absorbed code seeds.
## Only banks 00/01/02/04 — avoids full multi-bank decompbound compile.
## Usage: nim r -d:release src/tools/patch_seed_banks.nim

import
  std/[os, strformat],
  ../decompbound/[baserom_extract, common],
  ../decompbound/generated/[code_bank00, code_bank01, code_bank02, code_bank04,
                            code_spans]

proc patchBank(rom: var seq[uint8]; offset: int; data: seq[uint8]) =
  ## Write assembled region bytes into the ROM image.
  doAssert offset + data.len <= rom.len, &"patch overflow @0x{offset:06X}"
  for i, b in data:
    rom[offset + i] = b

proc main() =
  ## Rebuild affected bank regions into bin/Decompbound.smc.
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

  # Regions covering residual free code seeds (from convert_all code_spans).
  let regions = [
    (0x0012E4, generateCode0012E4()),
    (0x008573, generateCode008573()),
    (0x00CEBE, generateCode00CEBE()),
    (0x010000, generateCode010000()),
    (0x026546, generateCode026546()),
    (0x02979C, generateCode02979C()),
    (0x02AF1F, generateCode02AF1F()),
    (0x04642A, generateCode04642A()),
  ]
  var patched = 0
  for (off, data) in regions:
    patchBank(rom, off, data)
    patched += data.len
    echo &"  patched 0x{off:06X}+{data.len}"

  writeFile(path, rom)
  echo &"wrote {path} ({rom.len} bytes); patched {patched} B from 8 seed regions"

  let gold = readGoldBaseromBytes()
  var ok = 0
  var bad = 0
  for snesOff in [0x028D3A, 0x028E3B, 0x029D7A, 0x047369, 0x002C83, 0x004049,
                  0x00D195, 0x010078, 0x010C4F, 0x029033, 0x015C36, 0x02C145,
                  0x00865B, 0x008799, 0x0087A7]:
    var match = true
    for i in 0..<8:
      if gold[snesOff + i] != rom[snesOff + i]:
        match = false
        break
    if match: inc ok
    else:
      inc bad
      echo &"seed site 0x{snesOff:06X} mismatch after patch"
  echo &"seed site 8B windows: {ok} match, {bad} mismatch"

  var tot, matchc = 0
  for s in GeneratedCodeSpans:
    let bank = s.offset shr 16
    if bank notin [0x00, 0x01, 0x02, 0x04]: continue
    for i in 0..<s.length:
      # only count bytes we know we patched if inside our regions; else skip
      # full bank spans may include unpatched sibling regions — count all span
      # bytes that fall inside patched regions only
      discard
  # exactness of the 8 patched regions only
  for (off, data) in regions:
    for i, b in data:
      inc tot
      if gold[off + i] == b: inc matchc
  echo &"patched regions exact: {matchc}/{tot} ({100.0*matchc.float/tot.float:.4f}%)"
  if matchc != tot or bad != 0:
    quit(1)

when isMainModule:
  main()
