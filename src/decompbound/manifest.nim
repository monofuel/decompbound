## JSON ROM layout manifest: parse, validate, and coverage (tile) checks.
## One declarative description drives extract and rebuild (phase 2).

import
  std/[algorithm, json, os, strformat, strutils, tables],
  ./common

const
  ManifestDefaultPath* = "manifest.json"
  ExtractDefaultRoot* = "extracted"
  ManifestSchemaVersion* = 1

type
  RegionKind* = enum
    rkBlob = "blob"
    rkCode = "code"
    rkData = "data"
    rkHeader = "header"
    rkVectors = "vectors"

  BuildLevel* = enum
    blCopy = "copy"
    blReproduce = "reproduce"
    blModify = "modify"

  ComprehensionLevel* = enum
    clUnknown = "unknown"
    clIdentified = "identified"
    clExplained = "explained"

  ManifestRegion* = object
    name*: string
    offset*: int
    length*: int
    kind*: RegionKind
    source*: string
    build*: BuildLevel
    comprehension*: ComprehensionLevel
    evidence*: string

  Manifest* = object
    version*: int
    romSize*: int
    regions*: seq[ManifestRegion]

  CoverageReport* = object
    ok*: bool
    romSize*: int
    covered*: int
    gapBytes*: int
    overlapBytes*: int
    regionCount*: int
    message*: string

proc parseRegionKind(s: string): RegionKind =
  ## Parse a region kind string.
  case s
  of "blob": rkBlob
  of "code": rkCode
  of "data": rkData
  of "header": rkHeader
  of "vectors": rkVectors
  else:
    raise newException(ValueError, &"unknown region kind: {s}")

proc parseBuildLevel(s: string): BuildLevel =
  ## Parse a build-axis level string.
  case s
  of "copy": blCopy
  of "reproduce": blReproduce
  of "modify": blModify
  else:
    raise newException(ValueError, &"unknown build level: {s}")

proc parseComprehensionLevel(s: string): ComprehensionLevel =
  ## Parse a comprehension-axis level string.
  case s
  of "unknown": clUnknown
  of "identified": clIdentified
  of "explained": clExplained
  else:
    raise newException(ValueError, &"unknown comprehension level: {s}")

proc parseManifestJson*(node: JsonNode): Manifest =
  ## Parse a manifest from a JSON tree.
  if node.kind != JObject:
    raise newException(ValueError, "manifest root must be a JSON object")
  result.version = node["version"].getInt
  result.romSize = node["romSize"].getInt
  result.regions = @[]
  for r in node["regions"]:
    var region = ManifestRegion(
      name: r["name"].getStr,
      offset: r["offset"].getInt,
      length: r["length"].getInt,
      kind: parseRegionKind(r["kind"].getStr),
      source: r["source"].getStr,
      build: parseBuildLevel(r["build"].getStr),
      comprehension: parseComprehensionLevel(r["comprehension"].getStr),
      evidence: if r.hasKey("evidence"): r["evidence"].getStr else: ""
    )
    result.regions.add region

proc parseManifestFile*(path: string): Manifest =
  ## Load and parse a manifest JSON file.
  parseManifestJson(parseJson(readFile(path)))

proc parseManifestString*(raw: string): Manifest =
  ## Parse manifest JSON from a string (tests / synthetic).
  parseManifestJson(parseJson(raw))

proc validateManifest*(m: Manifest): CoverageReport =
  ## Validate schema basics and that regions tile romSize exactly.
  result.romSize = m.romSize
  result.regionCount = m.regions.len
  if m.version != ManifestSchemaVersion:
    result.message = &"unsupported manifest version {m.version} (want {ManifestSchemaVersion})"
    return
  if m.romSize != EarthboundRomSize:
    result.message = &"romSize {m.romSize} != EarthboundRomSize {EarthboundRomSize}"
    return
  if m.regions.len == 0:
    result.message = "manifest has no regions"
    return

  var names = initTable[string, int]()
  type Span = tuple[offset, length: int, name: string]
  var spans: seq[Span] = @[]
  for i, r in m.regions:
    if r.name.len == 0:
      result.message = &"region[{i}] has empty name"
      return
    if r.name in names:
      result.message = &"duplicate region name: {r.name}"
      return
    names[r.name] = i
    if r.offset < 0 or r.length <= 0:
      result.message = &"region {r.name}: bad offset/length"
      return
    if r.offset + r.length > m.romSize:
      result.message = &"region {r.name}: spans past romSize"
      return
    if r.source.len == 0:
      result.message = &"region {r.name}: empty source"
      return
    spans.add (r.offset, r.length, r.name)

  spans.sort(proc(a, b: Span): int = cmp(a.offset, b.offset))
  var cursor = 0
  var covered = 0
  var gaps = 0
  var overlaps = 0
  for s in spans:
    if s.offset > cursor:
      gaps += s.offset - cursor
    elif s.offset < cursor:
      overlaps += cursor - s.offset
    let endPos = s.offset + s.length
    if endPos > cursor:
      covered += endPos - max(cursor, s.offset)
      cursor = endPos
  if cursor < m.romSize:
    gaps += m.romSize - cursor

  result.covered = covered
  result.gapBytes = gaps
  result.overlapBytes = overlaps
  if gaps == 0 and overlaps == 0 and covered == m.romSize:
    result.ok = true
    result.message = &"coverage ok: {covered} bytes, {m.regions.len} regions, 0 gaps, 0 overlaps"
  else:
    result.ok = false
    result.message = &"coverage fail: covered={covered} gaps={gaps} overlaps={overlaps} romSize={m.romSize}"
