## Trace original cold-boot package requests, wire headers and completed uploader returns.
## Run from this worktree using the user's ROM and an isolated debug cache:
##   nim r -d:debug --nimcache:bin/nimcache/boot-packages-source src/probes/probe_spc_boot_packages.nim
## Optional first argument changes the bounded modeled-frame budget (default 1200).
## Add --service after the numeric budget to observe the separate setup/service instruction boundary.
## A shorter 400-frame prefix reaches only the resident upload in this blank-SRAM run.
## Core SnesBus/Cpu/APU paths, including MMIO catch-up, remain unchanged. Every
## generated PCM sample is discarded; no frontend, audio device or SRAM file is used.
## Battery RAM starts zero-filled in memory. No state, capture or asset bytes are written.
## Output is structural IDs, addresses, lengths, cache transitions and coverage only.
## The default checkpoint observes completed packages 1,0,1 and a separately completed
## loadSong caller for ID 1. Sender reset-word high bytes before the first payload
## header are control traffic, excluded from payload-byte counts and comparisons.
## No completion here initializes the eleven queried instrument rows; this bounded
## first-song history does not establish what later scene/song libraries upload.
import
  std/[algorithm, os, strformat, strutils, tables],
  ../decompbound/[cpu, music_player, rom_pipeline, snesbus]

type
  Block = object
    destination, length, payloadFile: int
  Header = object
    destination, length, flag: int
  Upload = object
    source, returnAddress: uint32
    entrySp: uint16
    fileOffset: int
    packages: seq[int]
    blocks: seq[Block]
    headers: seq[Header]
    payloadWrites, payloadMatching, payloadBlock, payloadInBlock, preHeaderControlWrites: int
    iplPortWrites, receiverPortWrites, otherSpcPortWrites: int
    bootstrapControl, receiverReturnControl: bool
    addressLow, addressHigh: int
    awaitingFlag, payloadOpen, completed: bool
  SongCall = object
    id: int
    returnAddress: uint32
    entrySp: uint16
    completed: bool
  InitializerCall = object
    returnAddress: uint32
    entrySp, entryDirect, entrySong: uint16
    entryBank: uint8
    completed: bool
  Trace = ref object
    uploads: seq[Upload]
    pending: seq[int]
    songs: seq[SongCall]
    initializers: seq[InitializerCall]
    packageIds: Table[int, seq[int]]
    cacheDirty: bool
    cache: array[6, uint16]
    hostPc: uint32
    hostOpcode: uint8
    hostX: uint16
    hostInstructions, cacheTransitions, initEntries: int
    gapWriter: array[11, int]
    gapMask: array[11, uint8]
    auditService: bool
    serviceVisits: CountTable[int]

const
  PackageCount = 169
  InstructionsPerLine = 150
  Scanlines = 262
  SamplesPerFrame = 32000 div 60
  DefaultFrames = 1200
  CacheOffsets = [0xB53B, 0xB53D, 0xB53F, 0xB541, 0xB543, 0xB547]
  CacheNames = ["song", "slot0", "slot1", "slot2", "alternate1", "addressMask"]
  GapRows = [0x6E36, 0x6E3C, 0x6E78, 0x6E7E, 0x6E84, 0x6E90,
    0x6E96, 0x6E9C, 0x6EA2, 0x6EA8, 0x6EAE]

proc canonical(address: uint32): uint32 =
  ## Normalize executable HiROM mirrors while preserving WRAM/low-address identities.
  let
    bank = address shr 16
    offset = address and 65535
  if bank in 0x40'u32 .. 0x7D'u32: return ((bank + 0x80) shl 16) or offset
  if (bank <= 0x3F or bank in 0x80'u32 .. 0xBF'u32) and offset >= 0x8000:
    return (((bank and 0x3F) + 0xC0) shl 16) or offset
  address

proc sourceFile(address: uint32): int =
  ## Resolve only real HiROM aliases, never treating WRAM pointers as package references.
  let normalized = canonical(address)
  if normalized >= 0xC00000: ((normalized shr 16).int and 63) * 65536 + (normalized.int and 65535)
  else: -1

proc describe(rom: seq[uint8], fileOffset: int): seq[Block] =
  ## Read package block headers, retaining payload offsets but no copied asset bytes.
  var position = fileOffset
  while true:
    doAssert position >= 0 and position + 2 <= rom.len
    let length = rom[position].int or (rom[position + 1].int shl 8)
    position += 2
    if length == 0: break
    doAssert position + 2 <= rom.len
    let destination = rom[position].int or (rom[position + 1].int shl 8)
    position += 2
    doAssert position + length <= rom.len and destination + length <= 65536
    result.add Block(destination: destination, length: length, payloadFile: position)
    position += length

proc callerReturn(snes: SnesBus, host: Cpu): uint32 =
  ## Observe the existing native JSL frame without changing any stack byte.
  doAssert host.s.int + 3 < 0x2000 # Only side-effect-free WRAM stack reads.
  let
    low = snes.bus.read8((host.s + 1).uint32).uint32
    high = snes.bus.read8((host.s + 2).uint32).uint32
    bank = snes.bus.read8((host.s + 3).uint32).uint32
  (bank shl 16) or ((((high shl 8) or low) + 1) and 65535)

proc cacheValues(snes: SnesBus): array[6, uint16] =
  ## Read only structural loader cache words from canonical WRAM.
  for index, offset in CacheOffsets:
    result[index] = snes.bus.read16((0x7E0000 + offset).uint32)

proc watchCaches(trace: Trace, snes: SnesBus) =
  ## Report coherent instruction-complete cache transitions, not half-word stores.
  if trace.cacheDirty:
    let current = snes.cacheValues()
    for index, value in current:
      if value != trace.cache[index]:
        echo &"cache {CacheNames[index]} ${trace.cache[index]:04X} -> ${value:04X} " &
          &"after CPU ${trace.hostPc:06X}"
        inc trace.cacheTransitions
    trace.cache = current
    trace.cacheDirty = false

proc completeUpload(trace: Trace, snes: SnesBus, rom: seq[uint8], index: int) =
  ## Separate a genuine RTL completion and observed wire transfer from a request.
  trace.uploads[index].completed = true
  let upload = trace.uploads[index]
  var
    expectedPayload = 0
    headerMatches = upload.headers.len == upload.blocks.len + 1
  for blockIndex, chunk in upload.blocks:
    expectedPayload += chunk.length
    if blockIndex >= upload.headers.len or
       upload.headers[blockIndex] != Header(destination: chunk.destination, length: chunk.length, flag: 1):
      headerMatches = false
  if upload.headers.len > 0:
    if upload.headers[^1] != Header(destination: 0x500, length: 0, flag: 0): headerMatches = false
  var rowsTouched, gapBytes, matchingGapBytes: int
  for rowIndex, row in GapRows:
    var touched = false
    for address in row .. row + 5:
      var lastBlock = -1
      for blockIndex, chunk in upload.blocks:
        if address >= chunk.destination and address < chunk.destination + chunk.length:
          lastBlock = blockIndex
      if lastBlock >= 0:
        let chunk = upload.blocks[lastBlock]
        touched = true
        trace.gapMask[rowIndex] = trace.gapMask[rowIndex] or (1 shl (address - row)).uint8
        inc gapBytes
        if snes.apu.spc.ram[address] == rom[chunk.payloadFile + address - chunk.destination]:
          inc matchingGapBytes
    if touched:
      trace.gapWriter[rowIndex] = index
      inc rowsTouched
  echo &"completed upload #{index + 1}: packages={upload.packages} source=${upload.source:06X} " &
    &"blocks={upload.blocks.len} wireHeaders={upload.headers.len} headersMatch={headerMatches} " &
    &"payloadWrites={upload.payloadWrites}/{expectedPayload} preHeaderControlWrites={upload.preHeaderControlWrites} " &
    &"payloadBytesMatching={upload.payloadMatching}/{expectedPayload} " &
    &"gapRowsTouched={rowsTouched} " &
    &"gapBytesMatching={matchingGapBytes}/{gapBytes}"
  echo &"  SPC paths: IPLportWrites={upload.iplPortWrites} residentReceiverPortWrites={upload.receiverPortWrites} " &
    &"otherDriverPortWrites={upload.otherSpcPortWrites} " &
    &"bootstrapControlObserved={upload.bootstrapControl} receiverReturnControlObserved={upload.receiverReturnControl}"
  for blockIndex, chunk in upload.blocks:
    echo &"  block {blockIndex + 1}: ARAM ${chunk.destination:04X}..${chunk.destination + chunk.length - 1:04X} length={chunk.length}"
  doAssert headerMatches and upload.payloadWrites == expectedPayload and upload.payloadMatching == expectedPayload

proc observe(trace: Trace, snes: SnesBus, host: Cpu, rom: seq[uint8]) =
  ## Trace original loader entries/returns while leaving execution and MMIO intact.
  let
    address = (host.pbr.uint32 shl 16) or host.pc.uint32
    pc = canonical(address)
  trace.hostPc = pc
  trace.hostOpcode = snes.bus.mem[address.int]
  trace.hostX = host.x
  inc trace.hostInstructions
  if trace.pending.len > 0:
    let index = trace.pending[^1]
    if address == trace.uploads[index].returnAddress and
       host.s == trace.uploads[index].entrySp + 3:
      trace.completeUpload(snes, rom, index)
      trace.pending.setLen(trace.pending.len - 1)
  for index in 0 ..< trace.songs.len:
    if not trace.songs[index].completed and address == trace.songs[index].returnAddress and
       host.s == trace.songs[index].entrySp + 3:
      trace.songs[index].completed = true
      echo &"completed song loader: id={trace.songs[index].id}"
  for index in 0 ..< trace.initializers.len:
    let call = trace.initializers[index]
    if not call.completed and address == call.returnAddress and host.s == call.entrySp + 3:
      let seed = rom[0x4F70C].uint16
      doAssert host.d == call.entryDirect and host.dbr == call.entryBank
      doAssert host.a == 1 and (host.p and (FlagM or FlagX)) == 0
      let restoredNz = (if host.d == 0: FlagZ else: 0'u8) or
        (if (host.d and 0x8000) != 0: FlagN else: 0'u8)
      doAssert (host.p and (FlagN or FlagZ)) == restoredNz
      doAssert snes.bus.read16(0x7EB53B) == call.entrySong
      doAssert snes.bus.read16(0x7EB53D) == 0xFFFF and snes.bus.read16(0x7EB541) == 0xFFFF
      doAssert snes.bus.read16(0x7EB53F) == seed and snes.bus.read16(0x7EB543) == seed
      doAssert snes.bus.read16(0x7EB547) == 0xFFFF and snes.bus.read16(0x7EB549) == 1
      trace.initializers[index].completed = true
      echo &"completed resident initializer: restoredDP=${host.d:04X} restoredDBR=${host.dbr:02X} " &
        &"seedPackage={seed} marker=1 currentSongPreserved=true"
  if host.nmiPending: return # The core will enter NMI before executing this PC.
  if trace.auditService and pc in 0xC0B7D8'u32 .. 0xC0B9BB'u32:
    trace.serviceVisits.inc(pc.int)
  if pc == 0xC4FB58:
    inc trace.initEntries
    trace.initializers.add InitializerCall(returnAddress: snes.callerReturn(host),
      entrySp: host.s, entryDirect: host.d, entryBank: host.dbr,
      entrySong: snes.bus.read16(0x7EB53B))
    echo "entered resident initializer $C4FB58"
  elif pc == 0xC4FBBD:
    trace.songs.add SongCall(id: host.a.int, entrySp: host.s, returnAddress: snes.callerReturn(host))
    echo &"requested song loader: id={host.a}"
  elif pc == 0xC0AB06:
    let
      source = ((host.x.uint32 and 255) shl 16) or host.a.uint32
      fileOffset = sourceFile(source)
      packages = trace.packageIds.getOrDefault(fileOffset)
    doAssert packages.len > 0, &"unrecognized upload source ${source:06X}"
    trace.uploads.add Upload(source: source, fileOffset: fileOffset, packages: packages,
      blocks: describe(rom, fileOffset), entrySp: host.s, returnAddress: snes.callerReturn(host))
    let index = trace.uploads.high
    trace.pending.add index
    echo &"requested upload #{index + 1}: packages={packages} source=${source:06X} " &
      &"file=${fileOffset:06X} return=${trace.uploads[index].returnAddress:06X}"

proc main() =
  ## Cold boot unchanged cores with blank in-memory battery RAM and discard all PCM.
  let
    rom = readGoldBaserom()
    snes = newSnesBus(rom)
    trace = Trace(packageIds: initTable[int, seq[int]](),
      auditService: "--service" in commandLineParams())
    frames = if paramCount() > 0: parseInt(paramStr(1)) else: DefaultFrames
  doAssert frames > 0 and frames <= 2000
  for value in snes.sram.mitems: value = 0 # Never load or save a user's SRAM.
  for index in 0 .. 10: trace.gapWriter[index] = -1
  for package in 0 ..< PackageCount:
    trace.packageIds.mgetOrPut(packFileOffset(rom, package), @[]).add package
  trace.cache = snes.cacheValues()
  let originalSpcWrite = snes.apu.spc.writeHook
  snes.apu.spc.writeHook = proc(address: uint16, value: uint8): bool =
    if trace.pending.len > 0:
      let
        index = trace.pending[^1]
        pc = snes.apu.spc.pc.int
      if address in 0xF4'u16 .. 0xF7'u16:
        if snes.apu.spc.iplEnabled and pc >= 0xFFC0:
          inc trace.uploads[index].iplPortWrites
        elif pc in 0x0EE1 .. 0x0F2C:
          inc trace.uploads[index].receiverPortWrites
        else: inc trace.uploads[index].otherSpcPortWrites
      if address == 0xF1:
        if pc in [0x0535, 0x0541]: trace.uploads[index].bootstrapControl = true
        if pc in 0x0EE1 .. 0x0F2C and value == 0x31:
          trace.uploads[index].receiverReturnControl = true
    originalSpcWrite(address, value)
  let originalWrite = snes.bus.writeHook
  snes.bus.writeHook = proc(address: uint32, value: uint8): bool =
    let
      bank = address shr 16
      offset = (address and 65535).int
    if bank == 0x7E:
      for cached in CacheOffsets:
        if offset in [cached, cached + 1]: trace.cacheDirty = true
    if trace.pending.len > 0 and trace.hostPc in 0xC0AB06'u32 .. 0xC0ABBC'u32 and
       trace.hostOpcode == 0x8D and
       (bank <= 0x3F or bank in 0x80'u32 .. 0xBF'u32):
      let index = trace.pending[^1]
      case offset
      of 0x2142: trace.uploads[index].addressLow = value.int
      of 0x2143:
        trace.uploads[index].addressHigh = value.int
        trace.uploads[index].awaitingFlag = true
      of 0x2141:
        if trace.uploads[index].awaitingFlag:
          trace.uploads[index].headers.add Header(
            destination: trace.uploads[index].addressLow + 256 * trace.uploads[index].addressHigh,
            length: trace.hostX.int, flag: value.int)
          trace.uploads[index].awaitingFlag = false
          trace.uploads[index].payloadOpen = value != 0
          trace.uploads[index].payloadBlock = trace.uploads[index].headers.high
          trace.uploads[index].payloadInBlock = 0
        elif trace.uploads[index].payloadOpen:
          inc trace.uploads[index].payloadWrites
          let
            blockIndex = trace.uploads[index].payloadBlock
            byteIndex = trace.uploads[index].payloadInBlock
          if blockIndex < trace.uploads[index].blocks.len:
            let chunk = trace.uploads[index].blocks[blockIndex]
            if byteIndex < chunk.length and value == rom[chunk.payloadFile + byteIndex]:
              inc trace.uploads[index].payloadMatching
          inc trace.uploads[index].payloadInBlock
        else:
          # Resident-reset STA2140 is 16-bit too; its port-one high byte is
          # control traffic before the first header, not a package payload byte.
          inc trace.uploads[index].preHeaderControlWrites
      else: discard
    originalWrite(address, value) # Delegate exactly once, preserving original semantics.
  var
    host = snes.resetCpu()
    scheduledSamples = 0
    firstNmi = -1
  snes.initHdma()
  echo &"cold boot: blank zero SRAM; modeledFrameBudget={frames}; core-only PCM discarded"
  for frame in 0 ..< frames:
    var samples = 0
    for line in 0 ..< Scanlines:
      snes.tickScanline(line)
      if line == 224 and (snes.nmitimen and 0x80) != 0: host.nmiPending = true
      for instruction in 0 ..< InstructionsPerLine:
        if not host.waiting: trace.observe(snes, host, rom)
        host.step(snes.bus)
        trace.watchCaches(snes)
        doAssert not host.stopped
        doAssert not (host.pbr == 0 and host.pc == 0x5FFF), "cold boot entered BRK sink"
      if line < 224: snes.runHdma()
      for sample in 0 .. 1:
        discard snes.tickApu()
        inc samples
    snes.initHdma()
    while samples < SamplesPerFrame:
      discard snes.tickApu()
      inc samples
    scheduledSamples += samples
    if firstNmi < 0 and (snes.nmitimen and 0x80) != 0: firstNmi = frame
  trace.observe(snes, host, rom)
  var completed, completedSongs, completedInitializers, coveredRows = 0
  for upload in trace.uploads:
    if upload.completed: inc completed
  for song in trace.songs:
    if song.completed: inc completedSongs
  for initializer in trace.initializers:
    if initializer.completed: inc completedInitializers
  for index, writer in trace.gapWriter:
    if writer >= 0:
      if trace.gapMask[index] == 0x3F: inc coveredRows
      echo &"gap row ${GapRows[index]:04X}: byteCoverageMask=${trace.gapMask[index]:02X} " &
        &"last touching completed upload #{writer + 1} packages={trace.uploads[writer].packages}"
    else: echo &"gap row ${GapRows[index]:04X}: never covered by a completed upload"
  echo &"bounded checkpoint: CPU=${host.pbr:02X}:{host.pc:04X} NMIenabled={firstNmi >= 0} " &
    &"residentInitializers={trace.initEntries} completedInitializers={completedInitializers} " &
    &"requestedUploads={trace.uploads.len} completedUploads={completed} " &
    &"requestedSongs={trace.songs.len} completedSongs={completedSongs} " &
    &"instrumentGapRowsCovered={coveredRows}/11 cacheTransitions={trace.cacheTransitions} " &
    &"CPUobservedInstructions={trace.hostInstructions} scheduledDiscardedSamples={scheduledSamples} " &
    &"SPCentry=${snes.apu.spc.pc:04X} IPLmapped={snes.apu.spc.iplEnabled} SRAMdirtyInMemory={snes.sramDirty}"
  echo "No visual-title, physical timing, complete library or musical-correctness claim."
  if trace.auditService:
    echo &"service observation: entries={trace.serviceVisits[0xC0B7D8]} " &
      &"iterationStarts={trace.serviceVisits[0xC0B814]} tailEntries={trace.serviceVisits[0xC0B95E]} " &
      &"returnInstructions={trace.serviceVisits[0xC0B999]} startupWrapperEntries={trace.serviceVisits[0xC0B99A]} " &
      &"distinctInstructionStarts={trace.serviceVisits.len}"
    var starts: seq[int]
    for address in trace.serviceVisits.keys: starts.add address
    starts.sort()
    for address in starts:
      echo &"service instruction ${address:06X}: visits={trace.serviceVisits[address]}"

when isMainModule:
  main()
