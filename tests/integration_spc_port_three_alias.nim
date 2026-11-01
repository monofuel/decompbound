## Execute the original full service caller and its copied code/data alias.
## Inputs are package one plus authored idle/native-return state and stable host ports.
## No timers, mixer, frontend, device, extracted contents or instruction patches are used.
## Raw contexts use a cached original RET; real two-pass chains consume original runtime records.
## Later record evolution and unstable host reads are outside this bounded contract.
import
  std/strformat,
  decompbound/[apu, manifest, music_player, spc700],
  ./engine/rebuilt_rom

const
  ServiceEntry = 0x0596
  ServiceExit = 0x05C6
  Alias = 0x2E48
  AliasTarget = 0x2E25
  ReturnEntry = 0x148A
  DispatchReturn = 0x05A5
  FilterReturn = 0x05B0
  Stop = 0x5000
  DriverMap = 0x25FB42

type Totals = object
  cases, aliases, changedAliases, unchangedAliases, nominalAliases, rejectedAliases: int
  installedAliases, installations, nativeCommands, chains, selectors: int

proc checkOwnership() =
  ## Require identified copied data ownership for the dual-use pointer and branch word.
  let layout = parseManifestFile(ManifestDefaultPath)
  for address in Alias .. Alias + 1:
    var owners = 0
    for region in layout.regions:
      if DriverMap + address in region.offset ..< region.offset + region.length:
        inc owners
        doAssert region.build == blCopy and region.kind == rkData and
          region.comprehension in {clIdentified, clExplained},
          "The dual-use sequence-pointer bytes must remain known, copied data."
    doAssert owners == 1

proc word(spc: Spc, address: int): int =
  ## Read a structural pointer from original runtime memory.
  spc.ram[address].int or (spc.ram[address + 1].int shl 8)

proc checkPass(machine: Apu, baseline: array[65536, uint8], raw, previous: int,
    unchanged: bool): bool =
  ## Model one complete original pass with an accepted native-return or rejected active slot.
  machine.spc.ram[] = baseline
  template spc: untyped = machine.spc
  spc.pc = ServiceEntry
  spc.sp = 0xEF
  spc.a = 0x53
  spc.x = 0xA6
  spc.y = 0xD2
  spc.psw = (if (raw and 1) == 0: 0'u8 else: 0xDF'u8) # DP remains zero.
  spc.ram[0x4B7] = previous.uint8
  spc.ram[0x48F] = 8 # Active nominal slot uses original native RET callback.
  spc.ram[0x446] = (ReturnEntry and 255).uint8
  spc.ram[0x447] = (ReturnEntry shr 8).uint8
  spc.ram[0x4A7] = (if unchanged: raw else: raw xor 255).uint8
  for port in 0 .. 3:
    machine.portsIn[port] = 0
    machine.portsOut[port] = 0xA5
  machine.portsIn[3] = raw.uint8
  let
    sampled = if unchanged: 0 else: raw
    value = sampled and 127
    expectedAlias = value < 8 and previous >= 8
    clear = expectedAlias or (value == 7 and previous == 7)
  var steps, aliases, nativeReturns, filters = 0
  while spc.pc.int != ServiceExit:
    doAssert steps < 400
    if spc.pc == ReturnEntry:
      inc nativeReturns
      doAssert spc.sp == 0xED and spc.word(0x1EE) == DispatchReturn
    if spc.pc == 0x2E1D:
      inc filters
      doAssert spc.a.int == sampled and spc.ram[0x4B3].int == sampled
      doAssert spc.ram[0x4B7].int == previous
      doAssert spc.sp == 0xED and spc.word(0x1EE) == FilterReturn
    if spc.pc.int == Alias:
      inc aliases
      doAssert (spc.psw and PswZ) != 0 and spc.a == 0
      doAssert spc.ram[0x4B3] == 0
      let stack = spc.sp
      let frame = spc.ram[0x100 .. 0x1FF]
      let flags = spc.psw
      spc.step()
      doAssert spc.pc.int == AliasTarget and spc.sp == stack and spc.psw == flags
      doAssert spc.ram[0x100 .. 0x1FF] == frame
    else:
      doAssert spc.pc != 0x2E4A
      spc.step()
    inc steps
  doAssert filters == 1 and aliases == expectedAlias.int
  doAssert nativeReturns == (previous > 0 and previous < 128).int
  doAssert spc.sp == 0xEF and spc.ram[0x4B7].int == previous
  doAssert spc.ram[0x1F0 .. 0x1FF] == baseline[0x1F0 .. 0x1FF]
  doAssert spc.ram[0x4B3].int == (if clear: 0 else: sampled)
  doAssert spc.ram[0x4A7].int == raw and spc.ram[3].int == raw
  doAssert machine.portsOut[3].int == raw
  doAssert machine.portsOut[1] == 0 and machine.portsOut[2] == 0
  doAssert spc.ram[Alias .. Alias + 1] == baseline[Alias .. Alias + 1]
  expectedAlias

proc checkImage(image: seq[uint8]): Totals =
  ## Sweep raw host bytes and active-slot bytes through original callers without altering produced flags.
  let
    machine = newApu()
  applyPackageBlocks(machine.spc.ram[], image, packFileOffset(image, 1))
  machine.spc.pc = 0x500
  var startupSteps = 0
  while machine.spc.pc != 0x546:
    doAssert startupSteps < 40000
    machine.spc.step()
    inc startupSteps
  # Authored idle state disables unrelated counters and continuations, preserving all code/data.
  for address in [0x491, 0x438, 0x439, 0x43A, 0x4B1, 0x4B2, 0x4B3,
      0x4B5, 0x4B6, 0x4A5, 0x4A6]: machine.spc.ram[address] = 0
  let baseline = machine.spc.ram[]
  var cases, aliases, changedAliases, unchangedAliases, nominalAliases, rejectedAliases = 0
  for unchanged in [false, true]:
    for raw in 0 .. 255:
      for previous in 0 .. 255:
        let taken = machine.checkPass(baseline, raw, previous, unchanged)
        inc cases
        if taken:
          inc aliases
          if unchanged: inc unchangedAliases else: inc changedAliases
          if previous < 128: inc nominalAliases else: inc rejectedAliases
  var installedAliases, installations, nativeCommands, expectedInstallAliases = 0
  for command in 1 .. 127:
    machine.spc.ram[] = baseline
    machine.spc.pc = ServiceEntry
    machine.spc.sp = 0xEF
    machine.spc.psw = 0
    machine.spc.ram[0x4B7] = 0
    machine.spc.ram[0x4B3] = 0
    machine.spc.ram[0x4A7] = 0
    for port in 0 .. 3: machine.portsIn[port] = 0
    machine.portsIn[3] = command.uint8
    var sampleSteps = 0
    while machine.spc.pc.int != ServiceExit:
      doAssert sampleSteps < 400 and machine.spc.pc.int != Alias
      machine.spc.step()
      inc sampleSteps
    doAssert machine.spc.ram[0x4B3].int == command
    doAssert machine.spc.ram[0x4A7].int == command and machine.spc.sp == 0xEF
    # Consume the byte produced by the preceding original sampler, without rewriting its state.
    machine.spc.pc = ServiceEntry
    machine.portsIn[3] = 0
    let
      pointer = machine.spc.word(0x16C7 + 2 * (command - 1))
      kind = machine.spc.ram[pointer - 1].int
    var steps, hits, activeAtFilter = 0
    while machine.spc.pc.int != ServiceExit:
      doAssert steps < 3000, &"original installation command {command} exceeded budget"
      if machine.spc.pc == 0x2E1D:
        activeAtFilter = machine.spc.ram[0x4B7].int
        doAssert machine.spc.a == 0
        doAssert machine.spc.sp == 0xED and machine.spc.word(0x1EE) == FilterReturn
      if machine.spc.pc.int == Alias:
        inc hits
        doAssert machine.spc.a == 0 and (machine.spc.psw and PswZ) != 0
        let
          frame = machine.spc.ram[0x100 .. 0x1FF]
          stack = machine.spc.sp
          flags = machine.spc.psw
        machine.spc.step()
        doAssert machine.spc.pc.int == AliasTarget
        doAssert machine.spc.sp == stack and machine.spc.psw == flags
        doAssert machine.spc.ram[0x100 .. 0x1FF] == frame
      else:
        doAssert machine.spc.pc != 0x2E4A
        machine.spc.step()
      inc steps
    doAssert hits == (activeAtFilter >= 8).int
    doAssert machine.spc.sp == 0xEF
    if kind == 8:
      inc nativeCommands
      doAssert command in [71, 127]
      doAssert activeAtFilter == (if command == 71: 71 else: 0)
    else:
      inc installations
      doAssert activeAtFilter == command
      if command >= 8: inc expectedInstallAliases
    installedAliases += hits
    inc result.chains
    doAssert machine.spc.ram[0x1F0 .. 0x1FF] == baseline[0x1F0 .. 0x1FF]
    doAssert machine.spc.ram[Alias .. Alias + 1] == baseline[Alias .. Alias + 1]
  doAssert installedAliases == expectedInstallAliases + 1
  machine.spc.ram[] = baseline
  let selectorZero = machine.spc.word(Alias)
  machine.spc.pc = 0x772
  machine.spc.a = 0
  machine.spc.psw = 0
  machine.spc.sp = 0xEF
  machine.spc.ram[0x1F0] = (Stop and 255).uint8
  machine.spc.ram[0x1F1] = (Stop shr 8).uint8
  var selectorSteps = 0
  var highRead, lowRead = false
  while machine.spc.pc.int != Stop:
    doAssert selectorSteps < 64
    if machine.spc.pc == 0x77E:
      doAssert machine.spc.x == 0 and machine.spc.a.int == (selectorZero shr 8)
      highRead = true
    if machine.spc.pc == 0x782:
      doAssert machine.spc.x == 0 and machine.spc.a.int == (selectorZero and 255)
      doAssert machine.spc.y.int == (selectorZero shr 8)
      lowRead = true
    machine.spc.step()
    inc selectorSteps
  doAssert highRead and lowRead
  doAssert machine.spc.word(0x40) == selectorZero and machine.spc.sp == 0xF1
  doAssert machine.spc.ram[Alias .. Alias + 1] == baseline[Alias .. Alias + 1]
  result.cases = cases
  result.aliases = aliases
  result.changedAliases = changedAliases
  result.unchangedAliases = unchangedAliases
  result.nominalAliases = nominalAliases
  result.rejectedAliases = rejectedAliases
  result.installedAliases = installedAliases
  result.installations = installations
  result.nativeCommands = nativeCommands
  inc result.selectors

proc main() =
  ## Run the same independent host-state oracle on the original and freshly rebuilt images.
  checkOwnership()
  var totals: Totals
  for image in engineImages("bin/engine-spc-port-three-alias"):
    let checked = checkImage(image)
    doAssert checked.cases == 131072 and checked.aliases == 67456
    doAssert checked.changedAliases == 3968 and checked.unchangedAliases == 63488
    doAssert checked.nominalAliases == 32640 and checked.rejectedAliases == 34816
    doAssert checked.chains == 127 and checked.installedAliases == 119
    doAssert checked.installations == 125 and checked.nativeCommands == 2
    totals.cases += checked.cases
    totals.aliases += checked.aliases
    totals.chains += checked.chains
    totals.installedAliases += checked.installedAliases
    totals.selectors += checked.selectors
  echo &"SPC port-three alias passed: {totals.cases} raw full passes with {totals.aliases} taken aliases, {totals.chains} real two-pass command chains with {totals.installedAliases} taken aliases, {totals.selectors} selector-zero reads and copied noncode ownership."

when isMainModule:
  main()
