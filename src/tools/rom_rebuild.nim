## Rebuild a ROM from manifest.json + extracted/ and compare to gold.
##
## Usage (repo root):
##   nim r src/tools/rom_rebuild.nim
##   nim r src/tools/rom_rebuild.nim --out bin/phase2_rebuild.smc
##
## Always computes the SNES header checksum (does not paste gold checksum
## as the rebuild strategy). Exit 0 when byte-identical to gold.

import
  std/[os, strformat, strutils],
  ../decompbound/[common, manifest, rom_pipeline]

proc usage() =
  ## Print CLI help.
  echo """rom_rebuild — manifest + extracted/ → ROM (computed checksum)

  nim r src/tools/rom_rebuild.nim [--manifest PATH] [--extracted DIR]
                                  [--out PATH] [--rom PATH] [--no-compare]

Defaults: manifest.json, extracted/, out bin/phase2_rebuild.smc
Compares to gold unless --no-compare.
"""

proc main() =
  ## Rebuild ROM image and optionally byte-compare to gold.
  var
    manifestPath = ManifestDefaultPath
    extractDir = ExtractDefaultRoot
    outPath = "bin/phase2_rebuild.smc"
    romPath = ""
    doCompare = true
  var i = 1
  while i <= paramCount():
    let a = paramStr(i)
    if a in ["-h", "--help"]:
      usage()
      quit(0)
    elif a == "--manifest" and i < paramCount():
      i += 1
      manifestPath = paramStr(i)
    elif a == "--extracted" and i < paramCount():
      i += 1
      extractDir = paramStr(i)
    elif a == "--out" and i < paramCount():
      i += 1
      outPath = paramStr(i)
    elif a == "--rom" and i < paramCount():
      i += 1
      romPath = paramStr(i)
    elif a == "--no-compare":
      doCompare = false
    else:
      echo "unknown arg: ", a
      usage()
      quit(1)
    i += 1

  let m = parseManifestFile(manifestPath)
  let cov = validateManifest(m)
  echo cov.message
  if not cov.ok:
    quit(1)

  echo "rebuild: placing regions + computing SNES header checksum..."
  let built = rebuildRom(m, extractDir, computeChecksum = true)
  createDir(parentDir(outPath))
  writeFile(outPath, built)
  echo &"wrote {outPath} ({built.len} bytes)"

  let csum = computeSnesChecksum(built)
  let comp = csum xor 0xFFFF'u16
  echo &"computed checksum=0x{csum:04X} complement=0x{comp:04X}"

  if doCompare:
    if not goldBaseromAvailable() and romPath.len == 0:
      echo "gold missing; skip compare (use --rom or DECOMPBOUND_ROM)"
      quit(0)
    let gold = readGoldBaserom(romPath)
    if romsEqual(built, gold):
      echo "round-trip: BYTE-IDENTICAL to gold"
      quit(0)
    let d = firstDiff(built, gold)
    echo &"round-trip FAIL: first diff at 0x{d:06X} built=0x{built[d]:02X} gold=0x{gold[d]:02X}"
    quit(2)

main()
