## Observe actual song-3 instrument reads without a frontend, device or asset output.
## Inputs/startup/periodic song pokes match music_player; original I/O hooks remain intact.
## Run: nim r -d:debug --nimcache:bin/nimcache/song-instruments-source src/probes/probe_spc_song_instruments.nim
## Default playback budget is three modeled seconds; optional argument selects 1..5.
## PCM is hashed in memory and discarded, then cross-checked against public MusicPlayer.
## Output contains only structural code/data addresses, coverage masks and aggregate counts.
import
  std/[algorithm, hashes, os, sets, strformat, strutils, tables],
  ../decompbound/[apu, dsp, music_player, rom_pipeline, spc700]

type
  RowUse = object
    reads, selectedReads: int
    readMask, nonzeroUncovered: uint8
    phases, callers: CountTable[string]
  Pending = object
    active: bool
    address: int
    key: string
  Trace = object
    phase: string
    previousPc: int
    caller: string
    rows: Table[int, RowUse]
    route, native, continuation, nativeContinuation: Pending
    accepted, executedRoutes, executedNative, executedContinuations, executedNativeContinuations: CountTable[string]
    sites, phases, sequenceCommands: CountTable[string]
    instrumentCalls, instrumentReads, instructions, selectedSamples, nonzeroPcmFrames: int
    pcm: Hash

const
  Song = 3
  SampleRate = 32000
  InitialSamples = SampleRate div 5
  GapSamples = SampleRate div 200
  RefreshSamples = SampleRate div 2
  PackageCount = 169
  GapRows = [0x6E36, 0x6E3C, 0x6E78, 0x6E7E, 0x6E84, 0x6E90,
    0x6E96, 0x6E9C, 0x6EA2, 0x6EA8, 0x6EAE]
  RecordSites = [(0x0F56, "install-six"), (0x0F4B, "install-marked"),
    (0x14DF, "install-seven"), (0x14EE, "install-extended"),
    (0x1170, "retarget-marked"), (0x1176, "retarget-ordinary"),
    (0x0FB7, "stream-continuation"), (0x134E, "extended-continuation"),
    (0x148B, "single-continuation"), (0x1491, "finish"), (0x1557, "initialize")]

proc word(spc: Spc, address: int): int =
  ## Read a wrapping structural word from live memory.
  spc.ram[address and 65535].int or (spc.ram[(address + 1) and 65535].int shl 8)

proc counts(table: CountTable[string]): string =
  ## Sort aggregate structural categories without exposing sequence content.
  var keys: seq[string]
  for key in table.keys: keys.add key
  keys.sort()
  var fields: seq[string]
  for key in keys: fields.add key & ":" & $table[key]
  fields.join(", ")

proc noteCoverage(rom: seq[uint8], package: int, owner: var array[65536, int]) =
  ## Track applied block ownership using only package headers and destinations.
  var position = packFileOffset(rom, package)
  while true:
    let length = rom[position].int or (rom[position + 1].int shl 8)
    position += 2
    if length == 0: break
    let destination = rom[position].int or (rom[position + 1].int shl 8)
    position += 2
    doAssert destination + length <= 65536 and position + length <= rom.len
    for address in destination ..< destination + length: owner[address] = package
    position += length

proc reached(pending: var Pending, pc: int, counts: var CountTable[string]) =
  ## Count a promised target only when its original instruction actually executes.
  if pending.active and pc == pending.address:
    counts.inc(pending.key)
    pending.active = false

proc observe(trace: var Trace, machine: Apu, owner: array[65536, int]) =
  ## Observe original instruction boundaries and exact instrument indirect reads.
  let
    spc = machine.spc
    pc = spc.pc.int
  trace.route.reached(pc, trace.executedRoutes)
  trace.native.reached(pc, trace.executedNative)
  trace.continuation.reached(pc, trace.executedContinuations)
  trace.nativeContinuation.reached(pc, trace.executedNativeContinuations)
  for site in RecordSites:
    if pc == site[0]: trace.sites.inc(trace.phase & "/" & site[1])
  if pc == 0x1258:
    let
      kind = spc.x.int
      port = spc.ram[0x2E].int
      command = spc.ram[0x2D].int
      pointer = spc.word(0x20)
      key = &"port{port}/command{command}/kind{kind:02X}/record${pointer:04X}"
      route = spc.word(0x125B + kind)
    trace.accepted.inc(trace.phase & "/" & key)
    trace.route = Pending(active: true, address: route, key: &"kind{kind:02X}/entry${route:04X}")
    if kind == 8:
      trace.native = Pending(active: true, address: pointer, key: &"port{port}/entry${pointer:04X}")
  if pc == 0x132A:
    let
      kind = spc.x.int
      target = spc.word(0x132E + kind)
    trace.continuation = Pending(active: true, address: target, key: &"kind{kind:02X}/entry${target:04X}")
  if pc == 0x1345:
    let target = spc.word(0x440 + spc.x.int)
    trace.nativeContinuation = Pending(active: true, address: target, key: &"entry${target:04X}")
  if pc == 0x943:
    trace.sequenceCommands.inc(&"opcode${spc.a:02X}")
  if pc == 0x962:
    inc trace.instrumentCalls
    trace.caller = if trace.previousPc == 0x95F: "sequence-E0"
      elif trace.previousPc == 0x1140: "record-E0"
      elif trace.previousPc == 0x158B: "record-initialize"
      else: &"caller${trace.previousPc:04X}"
    trace.phases.inc(trace.phase & "/" & trace.caller)
  if pc in 0x095F .. 0x09B7 and spc.ram[pc] == 0xF7:
    let
      direct = if (spc.psw and PswP) == 0: 0 else: 256
      pointer = spc.ram[(pc + 1) and 65535].int
      base = spc.ram[direct + pointer].int or
        (spc.ram[direct + ((pointer + 1) and 255)].int shl 8)
      address = (base + spc.y.int) and 65535
    doAssert pointer == 0x14 and address in 0x6E00 .. 0x73FF
    let
      row = 0x6E00 + ((address - 0x6E00) div 6) * 6
      offset = address - row
    var usage = trace.rows.getOrDefault(row)
    inc usage.reads
    if spc.ram[4] == Song: inc usage.selectedReads
    usage.readMask = usage.readMask or (1 shl offset).uint8
    if owner[address] < 0 and spc.ram[address] != 0:
      usage.nonzeroUncovered = usage.nonzeroUncovered or (1 shl offset).uint8
    usage.phases.inc(trace.phase)
    usage.callers.inc(trace.caller)
    trace.rows[row] = usage
    inc trace.instrumentReads
  trace.previousPc = pc
  inc trace.instructions

proc sample(machine: Apu, trace: var Trace, owner: array[65536, int]): tuple[left, right: int16] =
  ## Match Apu.runSample exactly, adding read-only observation before each CPU instruction.
  let start = machine.spc.cycles
  while machine.spc.cycles - start < CyclesPerSample and not machine.spc.stopped:
    trace.observe(machine, owner)
    machine.spc.step()
  if machine.spc.stopped: machine.spc.cycles += CyclesPerSample
  machine.tickTimers(CyclesPerSample)
  machine.dsp.mixSample()

proc pcmHash(samples: openArray[int16]): Hash =
  ## Compare generated PCM only in memory; never output or save samples.
  for value in samples: result = result !& hash(value)
  result = !$result

proc main() =
  ## Observe one bounded product-equivalent standalone run and verify its PCM against the public API.
  let
    rom = readGoldBaserom()
    seconds = if paramCount() > 0: parseInt(paramStr(1)) else: 3
    playbackSamples = seconds * SampleRate
    machine = newApu()
  doAssert seconds in 1 .. 5
  var
    packages = songPackIndices(rom, Song)
    owner: array[65536, int]
    trace: Trace
  for address in 0 .. 65535: owner[address] = -1
  if 1 notin packages: packages = @[1] & packages
  for package in packages:
    applyPackageBlocks(machine.spc.ram[], rom, packFileOffset(rom, package))
    noteCoverage(rom, package, owner)
  machine.spc.pc = 0x0500
  machine.spc.sp = 0xEF
  trace.phase = "warmup"
  for index in 0 ..< InitialSamples: discard machine.sample(trace, owner)
  for command in [(3, 0x57), (1, 1), (0, 0)]:
    machine.portsIn[command[0]] = command[1].uint8
    trace.phase = &"startup-port{command[0]}"
    for index in 0 ..< GapSamples: discard machine.sample(trace, owner)
  machine.portsIn[0] = Song.uint8
  trace.phase = "playback"
  for index in 0 ..< playbackSamples:
    if index > 0 and index mod RefreshSamples == 0: machine.portsIn[0] = Song.uint8
    let pair = machine.sample(trace, owner)
    trace.pcm = (trace.pcm !& hash(pair.left)) !& hash(pair.right)
    if pair.left != 0 or pair.right != 0: inc trace.nonzeroPcmFrames
    if machine.spc.ram[4] == Song: inc trace.selectedSamples
  trace.pcm = !$trace.pcm
  let
    library = newMusicLibrary(rom)
    player = newMusicPlayer(library)
  player.startTrack(Song)
  var referencePcm: seq[int16]
  player.renderPcm(playbackSamples, referencePcm)
  let matches = pcmHash(referencePcm) == trace.pcm
  doAssert referencePcm.len == playbackSamples * 2 and matches
  player.stop()
  echo &"profile: song={Song} packages={packages} initialSamples={InitialSamples} " &
    &"startupGapSamples={3 * GapSamples} playbackSamples={playbackSamples} " &
    &"songRefreshes={(playbackSamples - 1) div RefreshSamples} " &
    &"publicMusicPlayerPcmMatches={matches} noFrontendOrDevice=true"
  echo &"observed: instructions={trace.instructions} instrumentCalls={trace.instrumentCalls} " &
    &"instrumentByteReads={trace.instrumentReads} rows={trace.rows.len} " &
    &"song3SelectedSamples={trace.selectedSamples} nonzeroPcmFrames={trace.nonzeroPcmFrames}"
  var rows: seq[int]
  for row in trace.rows.keys: rows.add row
  rows.sort()
  var observedGaps, uncoveredRows = 0
  for row in rows:
    let usage = trace.rows[row]
    var coveredMask = 0
    var owners = initHashSet[int]()
    for offset in 0 .. 5:
      if owner[row + offset] >= 0:
        coveredMask = coveredMask or (1 shl offset)
        owners.incl owner[row + offset]
    if row in GapRows: inc observedGaps
    if coveredMask != 0x3F: inc uncoveredRows
    echo &"row ${row:04X}: reads={usage.reads} whileSong3Selected={usage.selectedReads} " &
      &"readMask=${usage.readMask:02X} coveredMask=${coveredMask:02X} " &
      &"uncoveredNonzeroMask=${usage.nonzeroUncovered:02X} packageOwners={owners} " &
      &"phases=[{usage.phases.counts()}] callers=[{usage.callers.counts()}]"
  for row in GapRows:
    if not trace.rows.hasKey(row): echo &"queried gap row ${row:04X}: no actual reads"
  echo &"gap summary: queriedRowsRead={observedGaps}/11 observedRowsNotFullyCovered={uncoveredRows}"
  echo "instrument call phases: ", trace.phases.counts()
  echo "accepted record lookups: ", trace.accepted.counts()
  echo "executed record route entries: ", trace.executedRoutes.counts()
  echo "executed native entries: ", trace.executedNative.counts()
  echo "executed continuation routes: ", trace.executedContinuations.counts()
  echo "executed native continuation entries: ", trace.executedNativeContinuations.counts()
  echo "actual record sites: ", trace.sites.counts()
  echo "actual sequence commands: ", trace.sequenceCommands.counts()
  echo "Scope: one bounded standalone song/startup sequence, not all records, song sections or library fidelity."

when isMainModule:
  main()
