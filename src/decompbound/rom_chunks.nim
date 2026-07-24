## Full-ROM partition into typed chunks for per-chunk gold checks.
##
## Inventory metadata (list/summary) is built from lightweight spans:
## `generated/code_spans.nim` + adopted sizes + header/vectors. That path must
## never import bank modules or assemble millions of instructions.
##
## Per-chunk gold checks fill `built` from the project decomp ROM
## (`bin/Decompbound.smc`) when present so agents can verify without
## re-assembling every bank. Full live assemble still goes through `allRegions`
## in regions.nim / `make build`.
##
## Copyrighted ROM *content* is never stored here — only offsets, lengths, and
## kinds. Gold comparison reads the local gitignored baserom at check time.

import
  std/[algorithm, os, strformat, strutils],
  ./[common, adopted, baserom_extract],
  ./generated/code_spans

type
  ChunkKind* = enum
    ## Assemblable code from generated banks or snes_src adoptions.
    ckImplementedCode
    ## Declared non-code implemented bytes (header, vectors, tables).
    ckImplementedMeta
    ## Not yet claimed by the decomp builder. May hold code or copyrighted data
    ## in gold; does not count as decompiled progress until reclassified.
    ckUnclaimed

  RomChunk* = object
    ## Stable identity for agent briefs and failure messages.
    id*: string
    kind*: ChunkKind
    offset*: int
    length*: int
    ## Human-facing done criteria for this kind (agent brief text).
    doneCriteria*: string
    ## When kind is implemented, the project-built bytes for this span.
    ## Empty for unclaimed gaps and for metadata-only inventory rows.
    built*: seq[uint8]

const
  DecompRomPath* = "bin/Decompbound.smc"
  DoneImplementedCode* =
    "Assemble from project source; every byte in [offset, offset+length) " &
    "must match the local gold ROM. Counts toward make compare decompiled %."
  DoneImplementedMeta* =
    "Declared data in project source (header/vectors); every byte must match " &
    "local gold. Counts toward make compare implemented exactness."
  DoneUnclaimed* =
    "Not yet reverse-engineered or extracted. Do not treat as decompiled " &
    "progress. Future: reclassify as code (disasm) or data (extract from gold " &
    "into gitignored paths only). Gold slice exists only on machines with baserom."

proc doneCriteriaFor(kind: ChunkKind): string =
  ## Done-criteria string for agent briefs.
  case kind
  of ckImplementedCode: DoneImplementedCode
  of ckImplementedMeta: DoneImplementedMeta
  of ckUnclaimed: DoneUnclaimed

proc classifyImplementedName*(name: string): ChunkKind =
  ## Map registry region names to chunk kinds.
  case name
  of "header", "resetVectors",
     "actionScriptDispatchTable", "jmpTable8C65", "jmpTableA1AE", "jmpTableA350":
    ckImplementedMeta
  else:
    if name.startsWith("gfxLz_") or name.startsWith("apuPack"):
      ckImplementedMeta
    else:
      ckImplementedCode

proc chunkId*(kind: ChunkKind, name: string, offset, length: int): string =
  ## Stable chunk id: unique even when many regions share name "code".
  case kind
  of ckUnclaimed:
    &"unclaimed_0x{offset:06X}_L{length}"
  of ckImplementedMeta:
    name
  of ckImplementedCode:
    if name == "code" or name.len == 0:
      &"code_0x{offset:06X}_L{length}"
    else:
      # Adopted / named routines keep their name; offset suffix if collisions.
      name

proc partitionFromSpans*(
    spans: seq[tuple[name: string, offset: int, length: int, kind: ChunkKind,
                     built: seq[uint8]]],
    romSize: int = EarthboundRomSize): seq[RomChunk] =
  ## Build a full-ROM non-overlapping inventory from implemented spans + gaps.
  ## Pure: no ROM I/O. Spans must not overlap; order does not matter.
  doAssert romSize > 0
  var ordered = spans
  ordered.sort(proc(a, b: auto): int =
    result = cmp(a.offset, b.offset)
    if result == 0:
      result = cmp(a.length, b.length))

  var cursor = 0
  for s in ordered:
    doAssert s.offset >= 0
    doAssert s.length > 0
    doAssert s.offset + s.length <= romSize,
      &"span {s.name} exceeds ROM bounds"
    doAssert s.offset >= cursor,
      &"overlap or unsorted span at 0x{s.offset:06X} (cursor 0x{cursor:06X})"
    if s.offset > cursor:
      let gapLen = s.offset - cursor
      result.add RomChunk(
        id: chunkId(ckUnclaimed, "", cursor, gapLen),
        kind: ckUnclaimed,
        offset: cursor,
        length: gapLen,
        doneCriteria: doneCriteriaFor(ckUnclaimed),
        built: @[])
    result.add RomChunk(
      id: chunkId(s.kind, s.name, s.offset, s.length),
      kind: s.kind,
      offset: s.offset,
      length: s.length,
      doneCriteria: doneCriteriaFor(s.kind),
      built: s.built)
    cursor = s.offset + s.length

  if cursor < romSize:
    let gapLen = romSize - cursor
    result.add RomChunk(
      id: chunkId(ckUnclaimed, "", cursor, gapLen),
      kind: ckUnclaimed,
      offset: cursor,
      length: gapLen,
      doneCriteria: doneCriteriaFor(ckUnclaimed),
      built: @[])

  # Deduplicate ids if two named adoptions somehow collide (append offset).
  var seen: seq[string] = @[]
  for i in 0..<result.len:
    var id = result[i].id
    if id in seen:
      id = id & &"_0x{result[i].offset:06X}"
      result[i].id = id
    seen.add id

proc collectImplementedSpanMeta*(): seq[
    tuple[name: string, offset: int, length: int, kind: ChunkKind]] =
  ## Offset/length inventory without bank-module imports or full code assemble.
  ## Header, vectors, adopted (small assemble), and generated code_spans.
  result.add (name: "header", offset: HiRomHeaderOffset, length: HeaderSize,
              kind: ckImplementedMeta)
  result.add (name: "resetVectors", offset: ResetVectorOffset,
              length: ResetVectorSize, kind: ckImplementedMeta)
  for region in allAdoptedRegions():
    let kind = classifyImplementedName(region.name)
    result.add (name: region.name, offset: region.offset,
                length: region.data.len, kind: kind)
  # Baserom extracts: offset/length only (no gold I/O). Content filled at
  # build/check time from the local baserom via baserom_extract.nim.
  for s in allBaseromExtractSpans():
    result.add (name: s.name, offset: s.offset, length: s.length,
                kind: ckImplementedMeta)
  for s in GeneratedCodeSpans:
    # convert_all carves adopted ranges out of traced code; skip if any
    # residual overlap appears after hand edits.
    if isAdoptedOffset(s.offset):
      continue
    if isBaseromExtractOffset(s.offset):
      continue
    result.add (name: "code", offset: s.offset, length: s.length,
                kind: ckImplementedCode)

proc allRomChunksMeta*(): seq[RomChunk] =
  ## Full-ROM inventory without assembling generated banks (built empty).
  ## Safe for list/summary and for intentional-coverage maps in compare.
  var spans: seq[tuple[name: string, offset: int, length: int, kind: ChunkKind,
                       built: seq[uint8]]]
  for s in collectImplementedSpanMeta():
    spans.add (name: s.name, offset: s.offset, length: s.length, kind: s.kind,
               built: @[])
  result = partitionFromSpans(spans, EarthboundRomSize)

proc allRomChunks*(): seq[RomChunk] =
  ## Alias for metadata inventory. Built bytes are filled at check time from
  ## the decomp ROM (see fillBuiltFromDecompRom) so agents never re-assemble
  ## every bank module for list/check.
  result = allRomChunksMeta()

proc fillBuiltFromDecompRom*(chunk: var RomChunk,
    decompPath: string = DecompRomPath) =
  ## Load project-built bytes for an implemented chunk from the decomp image.
  if chunk.kind == ckUnclaimed:
    return
  if not fileExists(decompPath):
    raise newException(IOError, &"decomp ROM missing at {decompPath} (run make build)")
  let decomp = readFile(decompPath)
  if decomp.len != EarthboundRomSize:
    raise newException(IOError,
      &"decomp ROM size {decomp.len} != {EarthboundRomSize}")
  chunk.built = newSeq[uint8](chunk.length)
  for i in 0..<chunk.length:
    chunk.built[i] = decomp[chunk.offset + i].uint8

proc findChunk*(chunks: seq[RomChunk], id: string): RomChunk =
  ## Look up a chunk by id; raises if missing.
  for c in chunks:
    if c.id == id:
      return c
  raise newException(KeyError, "unknown chunk id: " & id)

proc findChunkAt*(chunks: seq[RomChunk], offset: int): RomChunk =
  ## Chunk that contains file offset; raises if out of range.
  for c in chunks:
    if offset >= c.offset and offset < c.offset + c.length:
      return c
  raise newException(KeyError, &"no chunk covers offset 0x{offset:06X}")

proc inventoryCoversRom*(chunks: seq[RomChunk], romSize: int = EarthboundRomSize): bool =
  ## True if chunks are contiguous from 0 and cover exactly romSize with no gaps.
  if chunks.len == 0:
    return romSize == 0
  if chunks[0].offset != 0:
    return false
  var endPos = 0
  for c in chunks:
    if c.offset != endPos or c.length <= 0:
      return false
    endPos = c.offset + c.length
  result = endPos == romSize

proc totalBytesByKind*(chunks: seq[RomChunk]): array[ChunkKind, int] =
  ## Sum of lengths per kind.
  for c in chunks:
    result[c.kind] += c.length

type
  ChunkCheckStatus* = enum
    ccsMatch          ## implemented span matches gold
    ccsMismatch       ## implemented span differs from gold
    ccsUnclaimed      ## gap — not a match claim
    ccsNoGold         ## gold ROM missing
    ccsBadGoldSize    ## gold wrong length
    ccsMissingBuilt   ## implemented chunk has no built bytes

  ChunkCheckResult* = object
    chunk*: RomChunk
    status*: ChunkCheckStatus
    ## First mismatch file offset when status == ccsMismatch; else -1.
    mismatchOffset*: int
    message*: string

proc checkChunkAgainstGold*(
    chunk: RomChunk,
    gold: string): ChunkCheckResult =
  ## Compare one chunk to an in-memory gold image (no I/O).
  result.chunk = chunk
  result.mismatchOffset = -1
  if gold.len != EarthboundRomSize:
    result.status = ccsBadGoldSize
    result.message = &"chunk {chunk.id}: gold size {gold.len} != {EarthboundRomSize}"
    return
  case chunk.kind
  of ckUnclaimed:
    result.status = ccsUnclaimed
    result.message = &"chunk {chunk.id}: kind=unclaimed offset=0x{chunk.offset:06X} " &
      &"len={chunk.length} — not decompiled progress; gold slice not claimed"
  of ckImplementedCode, ckImplementedMeta:
    if chunk.built.len != chunk.length:
      result.status = ccsMissingBuilt
      result.message = &"chunk {chunk.id}: built.len={chunk.built.len} != length={chunk.length}"
      return
    for i in 0..<chunk.length:
      let go = chunk.offset + i
      if gold[go].uint8 != chunk.built[i]:
        result.status = ccsMismatch
        result.mismatchOffset = go
        result.message = &"chunk {chunk.id}: mismatch at file offset 0x{go:06X} " &
          &"(kind={chunk.kind}, span 0x{chunk.offset:06X}+{chunk.length})"
        return
    result.status = ccsMatch
    result.message = &"chunk {chunk.id}: OK match gold 0x{chunk.offset:06X}+{chunk.length} " &
      &"({chunk.kind})"

proc checkChunkAgainstGoldFile*(
    chunk: RomChunk,
    goldPath: string = "bin/Earthbound (U) [!].smc",
    decompPath: string = DecompRomPath): ChunkCheckResult =
  ## Load local gold and fill built from decomp ROM when needed, then check.
  if not fileExists(goldPath):
    result.chunk = chunk
    result.status = ccsNoGold
    result.mismatchOffset = -1
    result.message = &"chunk {chunk.id}: gold ROM missing at {goldPath}"
    return
  var c = chunk
  if c.kind != ckUnclaimed and c.built.len != c.length:
    if not fileExists(decompPath):
      result.chunk = c
      result.status = ccsMissingBuilt
      result.mismatchOffset = -1
      result.message = &"chunk {c.id}: no built bytes and decomp ROM missing at {decompPath}"
      return
    fillBuiltFromDecompRom(c, decompPath)
  let gold = readFile(goldPath)
  result = checkChunkAgainstGold(c, gold)

proc kindName*(k: ChunkKind): string =
  ## Stable string for CLI/docs.
  case k
  of ckImplementedCode: "implemented_code"
  of ckImplementedMeta: "implemented_meta"
  of ckUnclaimed: "unclaimed"
