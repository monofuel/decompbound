## Extract + rebuild round-trip (synthetic always; gold when present).

import
  std/[os, strformat, unittest],
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

block mixedArchitectureSources:
  let
    sourceDir = ScratchRoot / "mixed_source"
    extractDir = ScratchRoot / "mixed_extract"
    cpuSource = sourceDir / "cpu.asm"
    spcSource = sourceDir / "apu.spc.asm"
    rawSource = sourceDir / "structure.bin"
    expectedPrefix = @[0xA9'u8, 0x5A, 0x60, 0xCA, 0xFE,
      0xE8, 0xA6, 0x2F, 0x01, 0x99, 0x3F, 0x00, 0x34, 0x6F]
  createDir(sourceDir)
  createDir(extractDir)
  writeFile(cpuSource, ".a8\nLDA #$5A\nRTS\n")
  writeFile(spcSource, ".org $3400\nentry: MOV A,#$A6\nBRA done\n.byte $99\ndone: CALL entry\nRET\n")
  writeFile(rawSource, @[0xCA'u8, 0xFE])
  var
    expected = newSeq[uint8](EarthboundRomSize)
    layout = Manifest(version: ManifestSchemaVersion, romSize: EarthboundRomSize,
      regions: @[
        ManifestRegion(name: "cpu", offset: 0, length: 3, kind: rkCode,
          source: cpuSource, build: blReproduce, comprehension: clExplained),
        ManifestRegion(name: "structure", offset: 3, length: 2, kind: rkData,
          source: rawSource, build: blReproduce, comprehension: clExplained),
        ManifestRegion(name: "apu", offset: 5, length: 9, kind: rkCode,
          source: spcSource, build: blReproduce, comprehension: clExplained),
        ManifestRegion(name: "tail", offset: 14, length: EarthboundRomSize - 14,
          kind: rkBlob, source: "tail.bin", build: blCopy,
          comprehension: clUnknown)])
  for index, value in expectedPrefix:
    expected[index] = value
  for index in expectedPrefix.len ..< expected.len:
    expected[index] = uint8((index * 131 + 17) and 255)
  writeFile(extractDir / "tail.bin", expected[14 .. ^1])
  doAssert rebuildRom(layout, extractDir, computeChecksum = false) == expected,
    "SPC label addresses must use APU .org while placement uses ROM offset"
  # Retain the pipeline's exact-length gate for assembled SPC sources.
  dec layout.regions[2].length
  dec layout.regions[3].offset
  inc layout.regions[3].length
  writeFile(extractDir / "tail.bin", expected[13 .. ^1])
  doAssert validateManifest(layout).ok
  expect ValueError:
    discard rebuildRom(layout, extractDir, computeChecksum = false)
  echo "[test_rom_pipeline] mixed 65816/SPC/raw sources and exact-length rejection ok"

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
