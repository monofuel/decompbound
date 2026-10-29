import
  std/strutils,
  decompbound/[asm_parse, cpu, snesbus]

const
  OracleWram* = 0x7E0000'u32
  OracleCaller = 0x1E00'u32
  OracleStack = 0x1FFF'u16
  OracleStepLimit = 4_000_000

proc putWord*(machine: SnesBus, offset, value: int) =
  ## Write a generated little-endian WRAM word for an isolated original call.
  machine.bus.write8(OracleWram + offset.uint32, uint8(value and 255))
  machine.bus.write8(OracleWram + offset.uint32 + 1, uint8((value shr 8) and 255))

proc wramWord*(machine: SnesBus, offset: int): int =
  ## Read a WRAM result independently of the native map decoder.
  machine.bus.read16(OracleWram + offset.uint32).int

proc callOriginal*(machine: SnesBus, target: uint32,
    a = 0, x = 0, y = 0, directPage = 0x0200): Cpu =
  ## Execute an original RTL routine with native registers and a bounded caller.
  let code = assembleAsm(".a16\n.i16\nJSL $" & target.toHex(6) & "\n", OracleCaller)
  for index, value in code:
    machine.bus.write8(OracleWram + OracleCaller + index.uint32, value)
  result = Cpu(pbr: 0x7E, pc: OracleCaller.uint16, dbr: 0x7E,
    s: OracleStack, d: directPage.uint16, a: uint16(a and 65535),
    x: uint16(x and 65535), y: uint16(y and 65535))
  var steps = 0
  while result.pbr != 0x7E or result.pc != (OracleCaller + code.len.uint32).uint16:
    doAssert steps < OracleStepLimit,
      "Original map routine $" & target.toHex(6) & " did not return"
    result.step(machine.bus)
    inc steps

proc releaseOriginal*(machine: SnesBus) =
  ## Release self-capturing emulator callbacks after an isolated reference run.
  machine.bus.readHook = nil
  machine.bus.writeHook = nil
  if machine.apu != nil:
    machine.apu.spc.readHook = nil
    machine.apu.spc.writeHook = nil
