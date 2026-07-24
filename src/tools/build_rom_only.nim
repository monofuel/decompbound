## Build bin/Decompbound.smc from allRegions.
import
  std/[os, strformat, times],
  ../decompbound/[common, regions]

proc main() =
  ## Assemble every implemented region into the decomp ROM image.
  echo "building regions..."
  let t0 = epochTime()
  var rom = newSeq[uint8](EarthboundRomSize)
  var n = 0
  var bytes = 0
  for region in eachRegion():
    for i, b in region.data:
      rom[region.offset + i] = b
    n += 1
    bytes += region.data.len
    if n mod 1000 == 0:
      echo &"  {n} regions, {bytes} bytes..."
  createDir("bin")
  writeFile("bin/Decompbound.smc", rom)
  echo &"wrote bin/Decompbound.smc regions={n} filled={bytes} in {epochTime()-t0:.1f}s"

main()
