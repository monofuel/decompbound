## Batch conversion: trace the gold ROM from its interrupt vectors and
## generate an assembler-DSL module for every discovered code region,
## plus a registry module the ROM builder consumes.
## Usage: nim r src/tools/convert_all.nim <rom_file>
##
## Regions get the entry flag state the tracer actually observed at their
## start, so immediate widths reflect traced reality rather than guesses.

import
  std/[algorithm, os, strformat, strutils, tables],
  ../decompbound/[adopted, assembler, baserom_extract, disasm, memmap, opcodes, sourcegen]

const
  OutputDir = "src/decompbound/generated"
  EmulationVectors = [0xFFF4, 0xFFF8, 0xFFFA, 0xFFFC, 0xFFFE]
  NativeVectors = [0xFFE4, 0xFFE6, 0xFFE8, 0xFFEA, 0xFFEE]
  HeaderRegion = (start: 0xFFB0, last: 0xFFFF)
  # Ground-truth code entry points the emulator observed the CPU fetching from
  # (regenerate with tools/probe_pc_coverage.nim). Static tracing stops at every
  # computed/indirect jump; these seeds carry it past the frontier with code we
  # know is real because it actually executed. Addresses only — safe to commit.
  ObservedEntriesFile = "src/decompbound/observed_entries.txt"
  # Conductor-verified static jump-table targets (grok digs, each byte-checked
  # against the ROM before landing here). Complements the runtime-observed set
  # with handlers that gameplay didn't happen to exercise. Addresses only.
  ResolvedEntriesFile = "src/decompbound/resolved_entries.txt"

proc loadEntryFile(rom: seq[uint8], path: string,
                   flags: var Table[int, FlagState]): seq[int] =
  ## Parse an entry list of `<hex SNES addr> [width nibble]` into file offsets.
  ## The optional nibble (bit0=m8, bit1=x8, bit2=emulation) records the true CPU
  ## width at that fetch so the tracer decodes the seed at the right boundary.
  if not fileExists(path): return
  for rawLine in readFile(path).splitLines():
    let line = rawLine.strip()
    if line.len == 0 or line.startsWith("#"): continue
    let parts = line.splitWhitespace()
    let off = snesToFile(parseHexInt(parts[0]).uint32)
    if off >= 0 and off < rom.len:
      result.add off
      if parts.len >= 2:
        let nib = parseInt(parts[1])
        flags[off] = FlagState(m8: (nib and 1) != 0, x8: (nib and 2) != 0,
                               emulation: (nib and 4) != 0)

proc readRomFile(filepath: string): seq[uint8] =
  ## Read ROM file and return bytes, stripping a 512-byte copier header.
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512:
    start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0..<result.len:
    result[i] = data[start + i].uint8

proc readVector(data: seq[uint8], fileOffset: int): int =
  ## Read a 16-bit interrupt vector and map it to a file offset.
  let vec = data[fileOffset].int or (data[fileOffset + 1].int shl 8)
  result = snesToFile(vec.uint32)

proc main() =
  if paramCount() < 1:
    echo "Usage: nim r src/tools/convert_all.nim <rom_file>"
    quit(1)

  let rom = readRomFile(paramStr(1))

  var entryPoints: seq[int]
  for vecOffset in EmulationVectors:
    let target = readVector(rom, vecOffset)
    if target >= 0 and target < rom.len:
      entryPoints.add target
  for vecOffset in NativeVectors:
    let target = readVector(rom, vecOffset)
    if target >= 0 and target < rom.len:
      entryPoints.add target

  var seedFlags = initTable[int, FlagState]()
  let observed = loadEntryFile(rom, ObservedEntriesFile, seedFlags)
  let resolved = loadEntryFile(rom, ResolvedEntriesFile, seedFlags)
  entryPoints.add observed
  entryPoints.add resolved
  if observed.len > 0 or resolved.len > 0:
    stderr.writeLine &"Seeding {observed.len} observed + {resolved.len} resolved entry points ({seedFlags.len} width-annotated)."

  stderr.writeLine "Tracing control flow from vectors..."
  let analysis = analyzeControlFlow(rom, entryPoints, @[HeaderRegion],
                                    seedFlags = seedFlags)

  # Adopted byte-ranges + baserom extracts: carve OUT of traced code so curated
  # modules and gold-slice data claims never overlap generated code_spans.
  let adopted = adoptedRanges()
  let extractHoles = baseromExtractRanges()
  proc isCarved(off: int): bool =
    for r in adopted:
      if off >= r.start and off <= r.last: return true
    for r in extractHoles:
      if off >= r.start and off <= r.last: return true
    false

  # Group contiguous code bytes into regions, breaking at carved boundaries.
  var regions: seq[tuple[start: int, length: int]]
  var i = 0
  while i < analysis.byteTypes.len:
    if analysis.byteTypes[i] == Code and not isCarved(i):
      let start = i
      while i < analysis.byteTypes.len and analysis.byteTypes[i] == Code and
            not isCarved(i):
        inc i
      regions.add (start: start, length: i - start)
    else:
      inc i

  removeDir(OutputDir)
  createDir(OutputDir)

  var moduleNames: seq[string]
  var regionEntries: seq[string]
  var totalBytes = 0
  var totalInstructions = 0

  # Pack regions into one module per ROM bank (file offset >> 16) rather than
  # one file per region. Emulator-observed seeding produces thousands of small
  # regions; a file each explodes `make compare`/`make test` compile time, so
  # group them — same regions, same bytes, far fewer translation units.
  var byBank: OrderedTable[int, seq[tuple[start: int, length: int]]]
  let skippedAdopted = adopted.len
  for region in regions:
    byBank.mgetOrPut(region.start shr 16, @[]).add region

  for bank, bankRegions in byBank:
    let name = &"code_bank{bank:02X}"
    var moduleSrc = ""
    moduleSrc.add "## Generated by tools/convert_all.nim from the gold master ROM. Do not edit.\n"
    moduleSrc.add &"## Bank 0x{bank:02X}: {bankRegions.len} region(s).\n"
    moduleSrc.add "\n"
    moduleSrc.add "import\n"
    moduleSrc.add "  ../[assembler, opcodes]\n"
    moduleSrc.add "\n"
    for region in bankRegions:
      let procName = &"generateCode{region.start:06X}"
      let entryFlags = analysis.entryFlagStates.getOrDefault(
        region.start, FlagState(m8: false, x8: false, emulation: false))
      let (source, covered, instructions) = generateRegionProc(
        rom, region.start, region.length, procName, entryFlags)
      moduleSrc.add source
      moduleSrc.add "\n"
      regionEntries.add &"  yield (offset: 0x{region.start:06X}, data: {procName}())"
      totalBytes += region.length
      totalInstructions += instructions
      discard covered
    writeFile(OutputDir / name & ".nim", moduleSrc)
    moduleNames.add name

  # Registry module importing every generated bank module.
  var registry = ""
  registry.add "## Generated by tools/convert_all.nim. Do not edit by hand.\n"
  registry.add &"## {moduleNames.len} code regions, {totalBytes} bytes, {totalInstructions} instructions.\n"
  registry.add "\n"
  registry.add "import\n"
  for i, name in moduleNames:
    let sep = if i < moduleNames.len - 1: "," else: ""
    registry.add &"  ./{name}{sep}\n"
  registry.add "\n"
  registry.add "iterator eachCodeRegion*(): tuple[offset: int, data: seq[uint8]] =\n"
  registry.add "  ## Yield each traced code region, assembled one at a time.\n"
  for entry in regionEntries:
    registry.add entry & "\n"
  registry.add "\n"
  registry.add "proc allCodeRegions*(): seq[tuple[offset: int, data: seq[uint8]]] =\n"
  registry.add "  ## Every traced code region, assembled from mnemonics.\n"
  registry.add "  for item in eachCodeRegion():\n"
  registry.add "    result.add item\n"
  writeFile(OutputDir / "registry.nim", registry)

  # Lightweight spans (offset+length only) so list/summary/compare intentional
  # maps never import bank modules or assemble millions of instructions.
  var spansMod = ""
  spansMod.add "## Lightweight code-region spans (no bank imports). Generated; do not edit.\n"
  spansMod.add "## Used by list/summary inventory paths that must not assemble.\n"
  spansMod.add "\n"
  spansMod.add "const\n"
  spansMod.add "  GeneratedCodeSpans* = [\n"
  for region in regions:
    spansMod.add &"    (offset: 0x{region.start:06X}, length: {region.length}),\n"
  spansMod.add "  ]\n"
  writeFile(OutputDir / "code_spans.nim", spansMod)

  # The frontier: every computed/indirect jump static tracing stops at.
  # These are the doors the code map cannot open without the Goal 2
  # emulator (or manual jump-table analysis).
  var frontier = analysis.frontier
  frontier.sort(proc(a, b: FrontierSite): int = cmp(a.fileOffset, b.fileOffset))
  var report = ""
  report.add "# Static tracing frontier\n"
  report.add "\n"
  report.add "Generated by tools/convert_all.nim. Do not edit by hand.\n"
  report.add "\n"
  report.add &"{frontier.len} computed/indirect jump sites where static control\n"
  report.add "flow tracing stops. Each is a TODO: resolve the jump table or\n"
  report.add "observe the targets at runtime (Goal 2 emulator), then re-trace.\n"
  report.add "\n"
  for site in frontier:
    let snesAddr = fileToSnes(site.fileOffset)
    report.add &"- `${snesAddr:06X}` (file 0x{site.fileOffset:06X}): `{formatInstruction(site.instr)}`\n"
  writeFile(OutputDir / "frontier.md", report)

  stderr.writeLine &"Generated {moduleNames.len} region modules: {totalBytes} bytes, {totalInstructions} instructions."
  if skippedAdopted > 0:
    stderr.writeLine &"Carved out {skippedAdopted} adopted range(s) for curated modules (see decompbound/adopted.nim)."
  stderr.writeLine &"Frontier: {frontier.len} computed-jump sites recorded in {OutputDir}/frontier.md."

when isMainModule:
  main()
