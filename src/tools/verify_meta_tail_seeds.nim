## Assemble regions that absorbed meta-tail free seeds; compare to gold.
import
  std/[strformat],
  ../decompbound/[baserom_extract, common],
  ../decompbound/generated/[code_bank00, code_bank01]

proc check(name: string; off: int; data: seq[uint8]; gold: seq[uint8]) =
  ## Compare one assembled region to gold.
  doAssert data.len > 0, name
  var mism = 0
  for i, b in data:
    if gold[off + i] != b:
      mism += 1
      if mism <= 5:
        echo &"  MISMATCH {name} +{i}: built={b:02X} gold={gold[off+i]:02X}"
  if mism == 0:
    echo &"OK {name} 0x{off:06X}+{data.len} exact"
  else:
    echo &"FAIL {name} {mism}/{data.len} mismatches"
    quit 1

proc main() =
  ## Verify meta-tail seed regions assemble byte-exact to gold.
  let gold = readGoldBaseromBytes()
  check("generateCode00922F", 0x00922F, generateCode00922F(), gold)
  check("generateCode016170", 0x016170, generateCode016170(), gold)
  check("generateCode016EBA", 0x016EBA, generateCode016EBA(), gold)
  # Spot-check the free residual sites themselves (now inside spans).
  for off in [0x00922F, 0x016170, 0x016EBA]:
    echo &"  free-site byte gold@0x{off:06X}={gold[off]:02X}"
  echo "all meta-tail seed regions byte-exact vs gold"

when isMainModule:
  main()
