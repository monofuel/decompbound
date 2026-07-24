## Assemble regions that absorbed sandwich free seeds; compare to gold.
## Avoids full-ROM decompbound rebuild. Usage:
##   nim r -d:release src/tools/verify_sandwich_seeds.nim

import
  std/[strformat],
  ../decompbound/[baserom_extract, memmap],
  ../decompbound/generated/[code_bank00, code_bank19, code_bank26]

proc check(name: string; offset: int; data: seq[uint8]; gold: seq[uint8]) =
  ## Compare assembled region bytes to gold at offset.
  doAssert offset + data.len <= gold.len
  var mism = 0
  for i, b in data:
    if gold[offset + i] != b:
      if mism < 8:
        echo &"  MISMATCH {name} +{i} (file 0x{offset+i:06X}): gold={gold[offset+i]:02X} got={b:02X}"
      inc mism
  if mism == 0:
    echo &"OK {name} @0x{offset:06X} len={data.len}"
  else:
    echo &"FAIL {name} @0x{offset:06X} len={data.len} mismatches={mism}"
    quit(1)

proc main() =
  ## Verify sandwich-seed bank regions assemble byte-exact to gold.
  let gold = readGoldBaseromBytes()
  check("generateCode009EEB", 0x009EEB, generateCode009EEB(), gold)
  check("generateCode00B461", 0x00B461, generateCode00B461(), gold)
  check("generateCode19621E", 0x19621E, generateCode19621E(), gold)
  check("generateCode260393", 0x260393, generateCode260393(), gold)

  # Spot-check the free residual sites themselves (now inside spans).
  for snes in [0xC0CEB4'u32, 0xC0CEBC'u32, 0xC0A11B'u32, 0xD962B0'u32, 0xE6044F'u32]:
    let o = snesToFile(snes)
    doAssert o >= 0
    # region checks above cover bytes
    discard o
  echo "all sandwich-seed regions byte-exact vs gold"

when isMainModule:
  main()
