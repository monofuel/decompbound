
import std/[strformat, os]
import ../decompbound/[rom_chunks, baserom_extract, common]

proc main() =
  ## Write implemented offset mask and rebuild honest decomp image.
  let gold = readGoldBaseromBytes()
  var impl = newSeq[bool](EarthboundRomSize)
  for c in allRomChunksMeta():
    if c.kind != ckUnclaimed:
      for i in c.offset ..< min(c.offset + c.length, impl.len):
        impl[i] = true
  var free = 0
  for b in impl:
    if not b: free += 1
  echo &"free residual={free}"
  var rom = newSeq[uint8](EarthboundRomSize)
  var filled = 0
  for i in 0 ..< EarthboundRomSize:
    if impl[i]:
      rom[i] = gold[i]
      filled += 1
  createDir("bin")
  writeFile("bin/Decompbound.smc", rom)
  echo &"wrote bin/Decompbound.smc filled={filled} free_zeroed={EarthboundRomSize-filled}"

main()
