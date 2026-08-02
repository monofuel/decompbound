## Extract gold ROM regions into extracted/ per manifest.json.
##
## Usage (repo root):
##   nim r src/tools/rom_extract.nim
##   nim r src/tools/rom_extract.nim --manifest manifest.json --out extracted
##
## Exit 0 on success. Does not commit assets; extracted/ is gitignored.

import
  std/[os, strformat, strutils],
  ../decompbound/[common, manifest, rom_pipeline]

proc usage() =
  ## Print CLI help.
  echo """rom_extract — gold + manifest → extracted/

  nim r src/tools/rom_extract.nim [--manifest PATH] [--out DIR] [--rom PATH]

Defaults: manifest.json, extracted/, gold from DECOMPBOUND_ROM or
bin/Earthbound (U) [!].smc
"""

proc main() =
  ## Extract every manifest region from the gold baserom.
  var
    manifestPath = ManifestDefaultPath
    outDir = ExtractDefaultRoot
    romPath = ""
  var i = 1
  while i <= paramCount():
    let a = paramStr(i)
    if a in ["-h", "--help"]:
      usage()
      quit(0)
    elif a == "--manifest" and i < paramCount():
      i += 1
      manifestPath = paramStr(i)
    elif a == "--out" and i < paramCount():
      i += 1
      outDir = paramStr(i)
    elif a == "--rom" and i < paramCount():
      i += 1
      romPath = paramStr(i)
    else:
      echo "unknown arg: ", a
      usage()
      quit(1)
    i += 1

  if not fileExists(manifestPath):
    echo &"manifest missing: {manifestPath}"
    quit(1)
  let m = parseManifestFile(manifestPath)
  let cov = validateManifest(m)
  echo cov.message
  if not cov.ok:
    quit(1)

  let gold = readGoldBaserom(romPath)
  let n = extractRegions(m, gold, outDir)
  echo &"extract ok: wrote {n} bytes ({m.regions.len} regions) under {outDir}/"
  echo &"coverage: {cov.covered} (expect {EarthboundRomSize})"

main()
