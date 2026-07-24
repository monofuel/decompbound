## Assemble regions covering recent code seeds and compare to gold.
## Avoids full-ROM decompbound rebuild. Usage: nim r src/tools/verify_seed_regions.nim

import
  std/[strformat, strutils],
  ../decompbound/[baserom_extract, memmap],
  ../decompbound/generated/[code_bank00, code_bank01, code_bank02, code_bank04]

proc check(name: string; offset: int; data: seq[uint8]; gold: seq[uint8]) =
  ## Compare assembled region bytes to gold at offset.
  doAssert offset + data.len <= gold.len
  var mism = 0
  for i, b in data:
    if gold[offset + i] != b:
      if mism < 5:
        echo &"  MISMATCH {name} +{i}: gold={gold[offset+i]:02X} got={b:02X}"
      inc mism
  if mism == 0:
    echo &"OK {name} @0x{offset:06X} len={data.len}"
  else:
    echo &"FAIL {name} @0x{offset:06X} len={data.len} mismatches={mism}"
    quit(1)

proc main() =
  ## Verify seed-covering bank regions assemble byte-exact to gold.
  let gold = readGoldBaseromBytes()
  # Regions that absorbed the 2026-07-24 residual free code seeds.
  check("generateCode0012E4", 0x0012E4, generateCode0012E4(), gold)
  check("generateCode008573", 0x008573, generateCode008573(), gold)
  check("generateCode00CEBE", 0x00CEBE, generateCode00CEBE(), gold)
  check("generateCode010000", 0x010000, generateCode010000(), gold)
  check("generateCode026546", 0x026546, generateCode026546(), gold)
  check("generateCode02979C", 0x02979C, generateCode02979C(), gold)
  check("generateCode02AF1F", 0x02AF1F, generateCode02AF1F(), gold)
  check("generateCode04642A", 0x04642A, generateCode04642A(), gold)
  # Spot-check free residual stubs themselves
  for snes in [0xC28D3A'u32, 0xC02C83'u32, 0xC0865B'u32, 0xC29033'u32,
               0xC15C36'u32, 0xC2C145'u32, 0xC47369'u32, 0xC0D195'u32]:
    let o = snesToFile(snes)
    doAssert o >= 0
    # presence only — full region checks above cover bytes
    discard o
  echo "all seed-covering regions byte-exact vs gold"

when isMainModule:
  main()
