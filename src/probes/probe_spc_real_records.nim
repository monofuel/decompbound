## Observe structural coverage of real resident non-native records without exporting content.
## Input: the user's ROM via readGoldBaserom; package 1 plus song 3 packages [2,3,4].
## Run from this worktree with -d:debug and an isolated --nimcache directory:
##   nim r -d:debug --nimcache:bin/nimcache/real-records-source src/probes/probe_spc_real_records.nim
## Add --flush to execute the original DSP flush between observed service passes.
## Add --song-start --flush for the original CPU/timer standalone start prelude.
##
## Startup profiles execute all 126 exact non-native pointers from the initial inventory.
## The song-start profile feeds the same 126 command IDs after one pointer-table entry
## has changed; it does not establish identical startup-pointer coverage. Both expose
## 194 distinct non-native pointers, including 68 secondary retargeted records. Profile
## counts are printed separately; observed instructions exclude the startup/prelude.
##
## Observed passes run original $0596..05C6 plus settling, with actual APU hooks.
## Timers advance only in the optional song-start prelude. No sample mixer/device is
## used, and controlled pass counts are not wall-clock timing or musical correctness.
## Eleven instrument rows (66 bytes) actually read as zero outside the loaded packages.
## Package-header candidates describe destination coverage, not correct library identity.
## Output contains counts, classes and addresses only; RAM snapshots stay in memory.
import
  std/[algorithm, hashes, os, sets, strformat, strutils, tables],
  ../decompbound/[apu, dsp, music_player, rom_pipeline, spc700]

type
  Command = object
    port, command, pointer, kind: int
  Coverage = ref array[65536, bool]
  State = object
    ram: ref array[65536, uint8]
    registers: array[5, uint8]
    dspRegisters: array[128, uint8]
    portsIn, portsOut: array[4, uint8]
    timers: array[3, TimerSnapshot]
    dspAddress: uint8
    ipl: bool
  Totals = object
    records, passes, instructions, finite, cycles, prefixCycles, budgets, stopped: int
    primaryFinished, preemptions, nativeDispatches: int
    kinds, outcomes, classes, sites, targets: CountTable[string]
    dispatches: HashSet[(int, int, int)]
    pcs: HashSet[int]
    missing: Table[string, HashSet[int]]
    missingNonzero: Table[string, HashSet[int]]
    resources: Table[string, HashSet[int]]
    passCounts: Table[int, seq[int]]

const
  StartupDone = 0x0546'u16
  PassEntry = 0x0596'u16
  PassDone = 0x05C6'u16
  PointerTables = [0x180D, 0x17D5, 0x17C5, 0x16C7]
  MaxPasses = 1024
  MaxInstructions = 12000
  Song = 3
  Sites = [(0x0FB7, "stream-continuation"), (0x134E, "extended-continuation"),
    (0x148B, "single-record-continuation"), (0x1491, "finish"),
    (0x1557, "initialize"), (0x1130, "instrument-marker"),
    (0x10B6, "pan-gain-marker"), (0x10E7, "pitch-token"),
    (0x0F8F, "keyoff-timing"), (0x1170, "retarget-marked"),
    (0x1176, "retarget-ordinary"), (0x1288, "extended-header"),
    (0x14EE, "extended-install"), (0x14FC, "plain-install"),
    (0x14DF, "seven-byte-install"), (0x0F56, "six-byte-install"),
    (0x1343, "native-continuation")]

proc word(spc: Spc, address: int): int =
  ## Read one wrapping structural pointer from the actual machine.
  spc.ram[address and 65535].int or (spc.ram[(address + 1) and 65535].int shl 8)

proc counts(table: CountTable[string]): string =
  ## Render sorted structural categories without any record/asset content.
  var keys: seq[string]
  for key in table.keys: keys.add key
  keys.sort()
  var fields: seq[string]
  for key in keys: fields.add key & ":" & $table[key]
  fields.join(", ")

proc intervals(addresses: HashSet[int]): string =
  ## Compact observed addresses into inclusive ranges, never memory bytes.
  var sorted: seq[int]
  for address in addresses: sorted.add address
  sorted.sort()
  var parts: seq[string]
  var index = 0
  while index < sorted.len:
    let first = sorted[index]
    var last = first
    inc index
    while index < sorted.len and sorted[index] == last + 1:
      last = sorted[index]
      inc index
    parts.add(if first == last: &"${first:04X}" else: &"${first:04X}..${last:04X}")
  parts.join(",")

proc packageCoverage(rom: seq[uint8], package: int, coverage: Coverage): int =
  ## Inspect only package block headers/destinations, not extracted payload content.
  var position = packFileOffset(rom, package)
  while true:
    doAssert position + 2 <= rom.len
    let length = rom[position].int or (rom[position + 1].int shl 8)
    position += 2
    if length == 0: break
    let destination = rom[position].int or (rom[position + 1].int shl 8)
    position += 2
    doAssert destination + length <= 65536 and position + length <= rom.len
    for address in destination ..< destination + length: coverage[address] = true
    position += length
    inc result

proc runCycles(machine: Apu, cycles: int) =
  ## Advance only the original CPU and hardware timers, never the sample mixer.
  let target = machine.spc.cycles + cycles
  while machine.spc.cycles < target:
    doAssert not machine.spc.stopped
    let old = machine.spc.cycles
    machine.spc.step()
    machine.tickTimers(machine.spc.cycles - old)

proc boot(rom: seq[uint8], packages: seq[int], songStart = false): Apu =
  ## Execute real startup and its first flush with unchanged APU/DSP I/O hooks.
  result = newApu()
  for package in packages:
    applyPackageBlocks(result.spc.ram[], rom, packFileOffset(rom, package))
  result.spc.pc = 0x0500
  var instructions = 0
  while result.spc.pc != StartupDone:
    doAssert instructions < 40000
    result.spc.step()
    inc instructions
  while result.spc.pc != 0x0579:
    doAssert instructions < 40200
    result.spc.step()
    inc instructions
  doAssert result.spc.sp == 0xCF
  if songStart:
    # Same wire sequence/CPU-cycle budgets as music_player's sample-count prelude,
    # but no runSample/mixSample call or audio device exists in this probe.
    result.runCycles(204800)
    result.portsIn[3] = 0x57
    result.runCycles(5120)
    result.portsIn[1] = 1
    result.runCycles(5120)
    result.portsIn[0] = 0
    result.runCycles(5120)
    result.portsIn[0] = Song.uint8
    result.runCycles(512000)
    var steps = 0
    while result.spc.pc != PassEntry:
      doAssert steps < 12000
      let old = result.spc.cycles
      result.spc.step()
      result.tickTimers(result.spc.cycles - old)
      inc steps

proc fingerprint(machine: Apu): Hash =
  ## Hash CPU-visible mutable state; exact comparisons confirm every candidate cycle.
  var hashValue: Hash
  for address in 0 .. 0x4FF: hashValue = hashValue !& hash(machine.spc.ram[address])
  for address in [0x17C5, 0x17C6, 0x18EF, 0x18F7, 0x18FF]:
    hashValue = hashValue !& hash(machine.spc.ram[address])
  for value in [machine.spc.a, machine.spc.x, machine.spc.y, machine.spc.sp, machine.spc.psw]:
    hashValue = hashValue !& hash(value)
  for value in machine.dsp.regs: hashValue = hashValue !& hash(value)
  for value in machine.portsIn: hashValue = hashValue !& hash(value)
  for value in machine.portsOut: hashValue = hashValue !& hash(value)
  !$hashValue

proc snapshot(machine: Apu): State =
  ## Keep an in-memory comparison state only; never serialize RAM or asset data.
  result.ram = new(array[65536, uint8])
  result.ram[] = machine.spc.ram[]
  result.registers = [machine.spc.a, machine.spc.x, machine.spc.y, machine.spc.sp, machine.spc.psw]
  result.dspRegisters = machine.dsp.regs
  result.portsIn = machine.portsIn
  result.portsOut = machine.portsOut
  result.dspAddress = machine.dspAddr
  result.ipl = machine.spc.iplEnabled
  for timer in 0 .. 2: result.timers[timer] = machine.getTimerSnapshot(timer)

proc same(state: State, machine: Apu): bool =
  ## Compare complete CPU-readable state, excluding non-readable cycle/write counters.
  if state.registers != [machine.spc.a, machine.spc.x, machine.spc.y, machine.spc.sp, machine.spc.psw] or
     state.dspRegisters != machine.dsp.regs or state.portsIn != machine.portsIn or
     state.portsOut != machine.portsOut or state.dspAddress != machine.dspAddr or
     state.ipl != machine.spc.iplEnabled: return false
  for timer in 0 .. 2:
    if state.timers[timer] != machine.getTimerSnapshot(timer): return false
  state.ram[] == machine.spc.ram[]

proc repeated(states: var Table[Hash, seq[State]], machine: Apu): bool =
  ## Accept a cycle only after exact RAM/register/port/timer comparison.
  let key = machine.fingerprint()
  if states.hasKey(key):
    for state in states[key]:
      if state.same(machine): return true
  states.mgetOrPut(key, @[]).add machine.snapshot()

proc resource(totals: var Totals, category: string, address: int, coverage: Coverage,
              machine: Apu) =
  ## Count lookup addresses and package-coverage gaps without printing their contents.
  totals.resources.mgetOrPut(category, initHashSet[int]()).incl(address)
  if not coverage[address]:
    totals.missing.mgetOrPut(category, initHashSet[int]()).incl(address)
    if machine.spc.ram[address] != 0:
      totals.missingNonzero.mgetOrPut(category, initHashSet[int]()).incl(address)

proc observe(totals: var Totals, machine: Apu, coverage: Coverage) =
  ## Observe structural instruction classes and concrete data-read addresses.
  let
    spc = machine.spc
    pc = spc.pc.int
  totals.pcs.incl(pc)
  for site in Sites:
    if pc == site[0]: totals.sites.inc(site[1])
  if pc == 0x1258:
    let
      port = spc.ram[0x2E].int
      pointer = spc.word(0x20)
      kind = spc.x.int
    totals.dispatches.incl((port, pointer, kind))
    totals.targets.inc(&"kind-{kind:02X}")
    if kind == 8: inc totals.nativeDispatches
    if spc.ram[0x4B4 + port] != 0: inc totals.preemptions
  if pc == 0x0FE4:
    let token = spc.a.int
    totals.classes.inc(if token == 0: "stop-zero"
      elif token == 0x7F: "timing-keyoff"
      elif token < 128: "timing-prefix"
      elif token == 0xE0: "instrument"
      elif token == 0xE1: "pan"
      elif token == 0xED: "gain"
      elif token == 0xC9: "marker-C9"
      else: "pitch")
  if pc == 0x1366:
    totals.classes.inc(if spc.a == 0: "extended-stop"
      elif spc.a == 0x7F: "extended-keyoff" else: "extended-gain")
  if pc == 0x0FA1:
    let selector = spc.ram[0x22].int
    totals.classes.inc(if selector == 0: "selector-zero-wrap"
      elif selector == 127: "selector-special" elif selector > 127: "selector-high"
      else: "selector-low")
  if pc == 0x1062 and spc.ram[0x23] == 0: totals.classes.inc("gain-zero-control-return")
  if pc == 0x06D4 and (((spc.ram[0x11].int * 2) and 255) div 24) > 6:
    totals.classes.inc("pitch-over-six-normalization")
  if pc == 0x0C95 and spc.word(0x10) > 20 * 256:
    totals.classes.inc("stereo-outside-verified-domain")
  if pc == 0x0988:
    totals.classes.inc(if spc.a >= 128: "instrument-noise-branch" else: "instrument-sample-branch")
  if pc == 0x0FE0:
    totals.resource("stream", (spc.word(0x20) + spc.y.int) and 65535, coverage, machine)
  elif pc == 0x1364:
    totals.resource("extended-gain", (spc.word(0x26) + spc.y.int) and 65535, coverage, machine)
  elif pc == 0x1377:
    totals.resource("extended-noise", (spc.word(0x28) + spc.y.int) and 65535, coverage, machine)
  if spc.ram[pc] == 0xF7 and pc in 0x095F .. 0x09B7:
    totals.resource("instrument", (spc.word(0x14) + spc.y.int) and 65535, coverage, machine)
  if spc.ram[pc] == 0xF6:
    let base = spc.word(pc + 1)
    if base in [0xE73, 0xE74, 0xEBC, 0xEBD, 0xEBE, 0xEBF]:
      totals.resource("curve", (base + spc.y.int) and 65535, coverage, machine)

proc runRecord(rom: seq[uint8], packages: seq[int], command: Command,
               coverage: Coverage, totals: var Totals, flushProfile, songStart: bool) =
  ## Feed an actual command through real host sampling and bounded original service passes.
  let machine = boot(rom, packages, songStart)
  let callerSp = machine.spc.sp
  var wire = command.command.uint8
  if wire == machine.spc.ram[0x4A4 + command.port]: wire = wire xor 0x80
  machine.portsIn[command.port] = wire # Real host phase bit forces a fresh sampled value if needed.
  var
    states = initTable[Hash, seq[State]]()
    outcome = "pass-limit"
    passes = 0
    seenActive = false
    primaryDone = false
    lastPc = 0
  for pass in 1 .. MaxPasses:
    passes = pass
    machine.spc.pc = PassEntry
    var
      steps = 0
      anchors = initTable[Hash, seq[State]]()
    while machine.spc.pc != PassDone:
      if steps >= MaxInstructions:
        outcome = "within-pass-budget"
        break
      if machine.spc.stopped:
        outcome = "stopped"
        break
      if machine.spc.pc == 0x0FCB and anchors.repeated(machine):
        outcome = "closed-prefix-cycle"
        break
      totals.observe(machine, coverage)
      let previousPc = machine.spc.pc
      machine.spc.step()
      if previousPc == 0x0FBA and machine.spc.pc == 0x0FB6:
        totals.classes.inc("service-wait-RET")
      if previousPc == 0x102A and machine.spc.pc == 0x102C:
        totals.classes.inc("operand-cursor-wrap-fallthrough")
      inc steps
      inc totals.instructions
    lastPc = machine.spc.pc.int
    if outcome in ["within-pass-budget", "stopped", "closed-prefix-cycle"]: break
    doAssert machine.spc.sp == callerSp
    inc totals.passes
    # Execute the real seven-byte settle fragment, stopping before phase/timer use.
    while machine.spc.pc != 0x05CD: machine.spc.step()
    if flushProfile:
      machine.spc.pc = 0x0546
      var flushSteps = 0
      while machine.spc.pc != 0x0579:
        if machine.spc.pc == 0x0543:
          outcome = "flush-mode-bypass"
          break
        doAssert flushSteps < 200
        machine.spc.step()
        inc flushSteps
      if outcome == "flush-mode-bypass": break
    let active = machine.spc.ram[0x4B4 + command.port] != 0
    if active: seenActive = true
    elif seenActive: primaryDone = true
    var busy = false
    for port in 1 .. 3:
      if machine.spc.ram[0x4B0 + port] != 0 or machine.spc.ram[0x4B4 + port] != 0: busy = true
    if pass >= 2 and not busy:
      outcome = "finite-idle"
      break
    if states.repeated(machine):
      outcome = "closed-pass-cycle"
      break
  inc totals.records
  totals.kinds.inc(&"{command.kind:02X}")
  totals.passCounts.mgetOrPut(command.kind, @[]).add passes
  totals.outcomes.inc(&"{command.kind:02X}/{outcome}")
  if primaryDone: inc totals.primaryFinished
  case outcome
  of "finite-idle": inc totals.finite
  of "closed-pass-cycle": inc totals.cycles
  of "closed-prefix-cycle": inc totals.prefixCycles
  of "stopped": inc totals.stopped
  else: inc totals.budgets
  if outcome != "finite-idle":
    echo &"open port={command.port} command={command.command} kind={command.kind:02X} " &
      &"record=${command.pointer:04X} passes={passes} status={outcome} PC=${lastPc:04X} primaryDone={primaryDone}"

proc main() =
  ## Inventory one declared configuration and print structural evidence only, never content.
  let rom = readGoldBaserom()
  var packages = songPackIndices(rom, Song)
  if 1 notin packages: packages = @[1] & packages
  let
    coverage = new(array[65536, bool])
    flushProfile = "--flush" in commandLineParams()
    songStart = "--song-start" in commandLineParams()
  var blocks = 0
  for package in packages: blocks += packageCoverage(rom, package, coverage)
  let baseline = boot(rom, packages)
  if songStart:
    let warm = boot(rom, packages, true)
    var pointerChanges, capacityChanges = 0
    for port in 0 .. 3:
      if warm.spc.ram[0x4D0 + port] != baseline.spc.ram[0x4D0 + port]: inc capacityChanges
      for command in 1 ..< baseline.spc.ram[0x4D0 + port].int:
        if warm.spc.word(PointerTables[port] + 2 * (command - 1)) !=
           baseline.spc.word(PointerTables[port] + 2 * (command - 1)): inc pointerChanges
    echo &"song-start verification: selectionEquals3={warm.spc.ram[4] == 3} " &
      &"remapBaseChanged={warm.spc.ram[0x5F] != baseline.spc.ram[0x5F]} " &
      &"capacityChanges={capacityChanges} pointerChanges={pointerChanges} callerSP=${warm.spc.sp:02X}"
  var commands: seq[Command]
  for port in 1 .. 3:
    let capacity = baseline.spc.ram[0x4D0 + port].int
    for command in 1 ..< capacity:
      let
        pointer = baseline.spc.word(PointerTables[port] + 2 * (command - 1))
        kind = baseline.spc.ram[(pointer - 1) and 65535].int
      if kind != 8: commands.add Command(port: port, command: command, pointer: pointer, kind: kind)
  echo &"configuration: song={Song} packages={packages} blocks={blocks} nonNative={commands.len} " &
    &"flushEachPass={flushProfile} songStartPrelude={songStart}; original startup+first flush, " &
    "then direct service+settle; no timers during observed passes, no mixer/device"
  var totals: Totals
  for command in commands:
    runRecord(rom, packages, command, coverage, totals, flushProfile, songStart)
  echo &"summary: records={totals.records} completedPasses={totals.passes} instructions={totals.instructions} " &
    &"finite={totals.finite} closedPass={totals.cycles} closedPrefix={totals.prefixCycles} " &
    &"otherOpen={totals.budgets} stopped={totals.stopped} primaryFinished={totals.primaryFinished} " &
    &"preemptions={totals.preemptions} transitiveNativeDispatches={totals.nativeDispatches} uniqueDispatches={totals.dispatches.len}"
  echo "initial kinds: ", totals.kinds.counts()
  echo "outcomes: ", totals.outcomes.counts()
  echo "token classes: ", totals.classes.counts()
  echo "sites: ", totals.sites.counts()
  echo "dispatch kinds: ", totals.targets.counts()
  var
    allPointers, initialPointers, additionalPointers: HashSet[int]
  for command in commands: initialPointers.incl command.pointer
  for dispatch in totals.dispatches:
    allPointers.incl dispatch[1]
    if dispatch[1] notin initialPointers: additionalPointers.incl dispatch[1]
  echo &"record pointers: initial={initialPointers.len} transitiveTotal={allPointers.len} additional={additionalPointers.len}"
  echo "additional record addresses: ", additionalPointers.intervals()
  for kind in [2, 4, 6, 10, 12, 16]:
    var values = totals.passCounts[kind]
    values.sort()
    echo &"kind {kind:02X} pass span: min={values[0]} median={values[values.len div 2]} max={values[^1]}"
  for category, addresses in totals.resources:
    echo &"resource {category}: observedAddresses={addresses.len}"
  for category, addresses in totals.missing:
    let nonzero = if totals.missingNonzero.hasKey(category): totals.missingNonzero[category].len else: 0
    echo &"uncovered {category}: addresses={addresses.len} nonzeroObserved={nonzero} ranges={addresses.intervals()}"
    if category == "instrument":
      var rows = initHashSet[int]()
      for address in addresses: rows.incl(0x6E00 + ((address - 0x6E00) div 6) * 6)
      for row in rows:
        var candidates: seq[int]
        for package in 0 ..< 169:
          let candidate = new(array[65536, bool])
          discard packageCoverage(rom, package, candidate)
          var complete = true
          for address in row .. row + 5:
            if not candidate[address]: complete = false
          if complete: candidates.add package
        echo &"uncovered instrument row ${row:04X}: package-header candidates={candidates}"
  var parserPcs = initHashSet[int]()
  for pc in totals.pcs:
    if pc in 0x0F2D .. 0x1197: parserPcs.incl pc
  echo &"interpreter distinct instruction starts={parserPcs.len}: {parserPcs.intervals()}"

when isMainModule:
  main()
