## Bounded original-code evidence for C0B7D8's local loop/return policy.
## Run: nim r -d:debug --nimcache:bin/nimcache/startup-service-worker src/probes/probe_startup_service_loop.nim
## Optional --listing prints our decoded local instructions; broader setup/iteration remains open.
## Tail checks explicitly bypass the unclaimed setup/iteration callees. They do
## execute original C04FFE's state=2 early return, with genuine native frames.
## No callee stand-ins, audio frontend, assets or captures are produced.
import
  std/[os, sets, strutils],
  ../decompbound/[rom_pipeline, cpu, disasm, opcodes, assembler]

proc putWord(bus: Bus, address, value: int) =
  ## Set an authored WRAM word.
  bus.mem[address] = (value and 255).uint8
  bus.mem[address + 1] = (value shr 8).uint8

proc main() =
  ## Decode local closure and exercise the original framed tail across all held words.
  let
    rom = readGoldBaserom()
    bus = newBus()
  for offset in 0 ..< 65536: bus.mem[0xC00000 + offset] = rom[offset]
  bus.readHook = proc(address: uint32): int =
    if address < 0x2000: return bus.mem[0x7E0000 + address.int].int
    -1
  bus.writeHook = proc(address: uint32, value: uint8): bool =
    if address < 0x2000:
      bus.mem[0x7E0000 + address.int] = value
      return true
    false
  var starts = initHashSet[int]()
  let decoded = disassemble(rom, 0xB7D8, 200,
    FlagState(m8: false, x8: false, emulation: false))
  var callCount, exitCount = 0
  for entry in decoded:
    if entry.fileOffset > 0xB999: break
    starts.incl entry.fileOffset
    if "--listing" in commandLineParams():
      echo entry.fileOffset.toHex(6), " ", formatInstruction(entry.instr)
  for entry in decoded:
    if entry.fileOffset > 0xB999: break
    let
      instruction = entry.instr
      address = 0xC00000'u32 + entry.fileOffset.uint32
      target = branchTargetSnes(instruction, address)
    if instruction.mnemonic in ["JSR", "JSL"]:
      inc callCount
      echo "Original call ", address.toHex(6), " -> ", target.toHex(6)
    elif target >= 0:
      doAssert target >= 0xC0B7D8 and target <= 0xC0B999
      doAssert (target.int - 0xC00000) in starts
    if instruction.mnemonic in ["RTS", "RTL", "RTI"]:
      doAssert entry.fileOffset == 0xB999 and instruction.mnemonic == "RTL"
      inc exitCount
  doAssert starts.len > 100 and exitCount == 1
  # These two actual JSL sites are decoded callers, not assumed callback-table roots.
  for callSite in [0xC0B9B7, 0xEFE60F]:
    let fileOffset = callSite and 0x3FFFFF
    for index in 0 ..< 4:
      bus.mem[callSite + index] = rom[fileOffset + index]
    var caller = Cpu(pc: (callSite and 65535).uint16,
      pbr: (callSite shr 16).uint8, dbr: 0x7E, d: 0x1F00, s: 0x1FFF)
    caller.step(bus)
    doAssert caller.pbr == 0xC0 and caller.pc == 0xB7D8 and caller.s == 0x1FFC
    doAssert bus.mem[0x7E1FFF] == (callSite shr 16).uint8
    doAssert bus.mem[0x7E1FFE] == (((callSite + 3) shr 8) and 255).uint8
    doAssert bus.mem[0x7E1FFD] == ((callSite + 3) and 255).uint8
    while caller.pc != 0xB7E0: caller.step(bus)
    doAssert caller.s == 0x1FFA and caller.d == 0x1EF0
    echo "Original caller ", callSite.toHex(6), " supplies native frame; entry prologue reaches B7E0"
  # Tiny authored JSL caller: the original entry itself creates its PHD frame.
  for index, value in [0x22'u8, 0xD8, 0xB7, 0xC0]: bus.mem[0xC04000 + index] = value
  var contexts, returns, loops = 0
  for gate in [0, 1, 65535]:
    for held in 0 .. 65535:
      bus.putWord(0x7E436C, gate)
      bus.putWord(0x7E0065, held)
      bus.putWord(0x7E98A5, 2)
      var host = Cpu(pc: 0x4000, pbr: 0xC0, dbr: 0x7E, d: 0x1F00,
        s: 0x1FFF, x: 0x1234, y: 0xABCD)
      while host.pc != 0xB7E0: host.step(bus)
      doAssert host.s == 0x1FFA and host.d == 0x1EF0
      # Explicit shared-tail context, not a claim that setup/iteration executed.
      host.pc = 0xB95E
      var steps, originalHelperCalls = 0
      while host.pc notin [0xB814'u16, 0x4004'u16]:
        doAssert steps < 45 and host.pbr == 0xC0
        if host.pc == 0x4FFE: inc originalHelperCalls
        doAssert host.pc != 0xB967 # State=2 helper result skips C4C718.
        host.step(bus)
        inc steps
      let shouldReturn = gate != 0 and (held and 0x3000) == 0x3000
      doAssert (host.pc == 0x4004) == shouldReturn
      doAssert originalHelperCalls == 1
      doAssert host.a == (if shouldReturn: 0x2000'u16 else: 0'u16)
      doAssert host.x == 0x1234 and host.y == 0xABCD and host.dbr == 0x7E
      doAssert host.s == (if shouldReturn: 0x1FFF'u16 else: 0x1FFA'u16)
      doAssert host.d == (if shouldReturn: 0x1F00'u16 else: 0x1EF0'u16)
      doAssert host.p == (if shouldReturn: FlagC else: FlagC or FlagZ)
      doAssert bus.mem[0x7E1FFF] == 0xC0
      doAssert bus.mem[0x7E1FFE] == 0x40 and bus.mem[0x7E1FFD] == 3
      if shouldReturn: inc returns
      else: inc loops
      inc contexts
  echo "Original local body=450 bytes; calls=", callCount, "; sole exit=B999 RTL"
  echo "Original framed tail contexts=", contexts, "; returns=", returns, "; loops=", loops,
    "; setup/iteration callees bypassed explicitly, C04FFE executed unpatched."

when isMainModule:
  main()
