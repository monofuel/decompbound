## Phase-2 extract and fixed-offset rebuild from a JSON manifest.
## Does not import generated/* or baserom_extract (keeps compile cheap).

import
  std/[os, strformat, strutils],
  ./[common, manifest]

const
  GoldBaseromPath* = "bin/Earthbound (U) [!].smc"
  GoldBaseromEnvVar* = "DECOMPBOUND_ROM"
  ## SNES internal header checksum/complement (HiROM file offsets).
  ChecksumComplementOffset* = 0xFFDC
  ChecksumOffset* = 0xFFDE

proc resolveGoldBaseromPath*(): string =
  ## Prefer DECOMPBOUND_ROM, else the default gold path under bin/.
  result = getEnv(GoldBaseromEnvVar)
  if result.len == 0:
    result = GoldBaseromPath

proc goldBaseromAvailable*(): bool =
  ## True when a local gold baserom file exists.
  fileExists(resolveGoldBaseromPath())

proc readGoldBaserom*(path: string = ""): seq[uint8] =
  ## Load gold ROM bytes, stripping a 512-byte copier header when present.
  let p = if path.len > 0: path else: resolveGoldBaseromPath()
  if not fileExists(p):
    raise newException(IOError, &"gold baserom missing at {p}")
  let data = readFile(p)
  var start = 0
  if data.len mod 1024 == 512:
    start = 512
  let bodyLen = data.len - start
  if bodyLen != EarthboundRomSize:
    raise newException(IOError,
      &"gold baserom size {bodyLen} != {EarthboundRomSize} (path={p})")
  result = newSeq[uint8](bodyLen)
  for i in 0..<bodyLen:
    result[i] = data[start + i].uint8

proc nextPow2(n: int): int =
  ## Smallest power of two >= n (n > 0).
  result = 1
  while result < n:
    result = result shl 1

proc computeSnesChecksum*(rom: openArray[uint8]): uint16 =
  ## Compute the SNES ROM checksum for $FFDE.
  ##
  ## Sums every byte except the four checksum/complement field bytes, adds
  ## 0x01FE (the constant byte-sum of checksum||complement when complement is
  ## bitwise-not checksum), and for non-power-of-two sizes mirrors the trailing
  ## remainder (last `nextPow2(len)-len` bytes) once more. Verified against
  ## EarthBound (U) gold (checksum 0x4048).
  const
    FieldStart = ChecksumComplementOffset
    FieldEnd = ChecksumOffset + 1
  var total: uint32 = 0
  for i in 0 ..< rom.len:
    if i >= FieldStart and i <= FieldEnd:
      continue
    total += rom[i]
  total += 0x01FE
  let rem = nextPow2(rom.len) - rom.len
  if rem > 0:
    let start = rom.len - rem
    for i in start ..< rom.len:
      total += rom[i]
  result = uint16(total and 0xFFFF)

proc writeSnesChecksum*(rom: var openArray[uint8]) =
  ## Compute and write checksum + complement into the HiROM header fields.
  let csum = computeSnesChecksum(rom)
  let comp = csum xor 0xFFFF'u16
  rom[ChecksumComplementOffset] = uint8(comp and 0xFF)
  rom[ChecksumComplementOffset + 1] = uint8((comp shr 8) and 0xFF)
  rom[ChecksumOffset] = uint8(csum and 0xFF)
  rom[ChecksumOffset + 1] = uint8((csum shr 8) and 0xFF)

proc extractRegions*(
    m: Manifest,
    gold: openArray[uint8],
    extractRoot: string
): int =
  ## Write each region slice from gold into extractRoot / region.source.
  ## Returns total bytes written (sum of region lengths).
  let cov = validateManifest(m)
  if not cov.ok:
    raise newException(ValueError, cov.message)
  if gold.len != m.romSize:
    raise newException(ValueError,
      &"gold size {gold.len} != manifest romSize {m.romSize}")
  result = 0
  for r in m.regions:
    let outPath = extractRoot / r.source
    createDir(parentDir(outPath))
    var slice = newSeq[uint8](r.length)
    for i in 0 ..< r.length:
      slice[i] = gold[r.offset + i]
    writeFile(outPath, slice)
    result += r.length

proc rebuildRom*(
    m: Manifest,
    extractRoot: string,
    computeChecksum = true
): seq[uint8] =
  ## Place extracted region files at fixed offsets; optionally recompute header checksum.
  let cov = validateManifest(m)
  if not cov.ok:
    raise newException(ValueError, cov.message)
  result = newSeq[uint8](m.romSize)
  for r in m.regions:
    let path = extractRoot / r.source
    if not fileExists(path):
      raise newException(IOError, &"missing extract file: {path}")
    let data = readFile(path)
    if data.len != r.length:
      raise newException(ValueError,
        &"region {r.name}: file {path} length {data.len} != {r.length}")
    for i in 0 ..< r.length:
      result[r.offset + i] = data[i].uint8
  if computeChecksum:
    writeSnesChecksum(result)

proc romsEqual*(a, b: openArray[uint8]): bool =
  ## True when two ROM images are the same length and byte-identical.
  if a.len != b.len:
    return false
  for i in 0 ..< a.len:
    if a[i] != b[i]:
      return false
  result = true

proc firstDiff*(a, b: openArray[uint8]): int =
  ## Index of first differing byte, or -1 if equal (including length).
  if a.len != b.len:
    return 0
  for i in 0 ..< a.len:
    if a[i] != b[i]:
      return i
  result = -1
