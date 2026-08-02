## Extract + rebuild round-trip (synthetic always; gold when present).

import
  std/[os, strformat],
  decompbound/[common, manifest, rom_pipeline]

const
  ScratchRoot = "bin/phase2_test_extract"

proc writeSyntheticGold(path: string, size: int = EarthboundRomSize) =
  ## Deterministic pseudo-ROM for offline tests (not a real game image).
  var rom = newSeq[uint8](size)
  for i in 0 ..< size:
    rom[i] = uint8((i * 131 + 17) and 0xFF)
  # Plausible checksum fields so recompute is stable.
  writeSnesChecksum(rom)
  createDir(parentDir(path))
  writeFile(path, rom)

block syntheticRoundTrip:
  let
    synthRom = ScratchRoot / "synth_gold.smc"
    extractDir = ScratchRoot / "extracted"
    manifestRaw = """
    {
      "version": 1,
      "romSize": 3145728,
      "regions": [
        {
          "name": "rom",
          "offset": 0,
          "length": 3145728,
          "kind": "blob",
          "source": "blobs/rom.bin",
          "build": "copy",
          "comprehension": "unknown"
        }
      ]
    }
    """
  writeSyntheticGold(synthRom)
  let gold = readGoldBaserom(synthRom)
  let m = parseManifestString(manifestRaw)
  doAssert validateManifest(m).ok
  if dirExists(extractDir):
    removeDir(extractDir)
  let n = extractRegions(m, gold, extractDir)
  doAssert n == EarthboundRomSize
  doAssert fileExists(extractDir / "blobs/rom.bin")
  let built = rebuildRom(m, extractDir, computeChecksum = true)
  doAssert built.len == EarthboundRomSize
  doAssert romsEqual(built, gold), "synthetic extract→rebuild must be byte-identical"
  # Checksum path is computed, not a pasted constant alone.
  let csum = computeSnesChecksum(built)
  doAssert built[ChecksumOffset] == uint8(csum and 0xFF)
  doAssert built[ChecksumOffset + 1] == uint8((csum shr 8) and 0xFF)
  echo &"[test_rom_pipeline] synthetic round-trip ok checksum=0x{csum:04X}"

block goldRoundTrip:
  if not goldBaseromAvailable():
    echo "[test_rom_pipeline] skip gold (no baserom)"
  else:
    let
      m = parseManifestFile("manifest.json")
      extractDir = ScratchRoot / "gold_extracted"
    doAssert validateManifest(m).ok
    let gold = readGoldBaserom()
    # Gold checksum must match our compute (proves formula on real ROM).
    let expected = gold[ChecksumOffset].uint16 or
      (gold[ChecksumOffset + 1].uint16 shl 8)
    let computed = computeSnesChecksum(gold)
    doAssert computed == expected,
      &"checksum formula: computed 0x{computed:04X} != gold 0x{expected:04X}"
    if dirExists(extractDir):
      removeDir(extractDir)
    let n = extractRegions(m, gold, extractDir)
    doAssert n == EarthboundRomSize
    let built = rebuildRom(m, extractDir, computeChecksum = true)
    doAssert romsEqual(built, gold), "gold extract→rebuild must be BYTE-IDENTICAL"
    echo &"[test_rom_pipeline] gold round-trip BYTE-IDENTICAL checksum=0x{computed:04X}"

echo "[test_rom_pipeline] ok"
