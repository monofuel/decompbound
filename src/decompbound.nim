## Public interface for the decompbound decompilation project.
## Phase-2: vanilla ROM is built from manifest.json + extracted/ (blob gate).
## Named adopted regions remain available via decompbound/regions for tools.

# nim r src/decompbound.nim

import
  std/[os, parseopt, strformat],
  decompbound/[common, manifest, rom_pipeline]

proc generateRom(): seq[uint8] =
  ## Build the vanilla ROM via the phase-2 pipeline (extract must already exist,
  ## or we extract from gold first when present).
  let m = parseManifestFile(ManifestDefaultPath)
  let cov = validateManifest(m)
  if not cov.ok:
    raise newException(ValueError, cov.message)
  if not dirExists(ExtractDefaultRoot) or
      not fileExists(ExtractDefaultRoot / "blobs/rom.bin"):
    if not goldBaseromAvailable():
      raise newException(IOError,
        "no extracted/ tree and no gold baserom — run rom_extract first")
    discard extractRegions(m, readGoldBaserom(), ExtractDefaultRoot)
  result = rebuildRom(m, ExtractDefaultRoot, computeChecksum = true)

when isMainModule:
  var runCompare = false
  var p = initOptParser()
  for kind, key, val in p.getOpt():
    case kind:
    of cmdLongOption, cmdShortOption:
      if key == "compare" or key == "c":
        runCompare = true
      else:
        echo "Unknown option: ", key
        quit(1)
    of cmdArgument:
      discard
    of cmdEnd:
      discard

  echo "building ROM (phase-2 manifest + extracted/)..."
  let rom = generateRom()
  createDir("bin")
  writeFile(outputRom, rom)
  echo &"wrote {outputRom} ({rom.len} bytes)"

  if runCompare:
    if not goldBaseromAvailable():
      echo "gold missing; skip compare"
      quit(0)
    let gold = readGoldBaserom()
    if romsEqual(rom, gold):
      echo "BYTE-IDENTICAL to gold"
      quit(0)
    let d = firstDiff(rom, gold)
    echo &"MISMATCH at 0x{d:06X}"
    quit(2)
