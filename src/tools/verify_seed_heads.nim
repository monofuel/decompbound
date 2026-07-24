import std/strformat,
  ../decompbound/[assembler, baserom_extract, opcodes]

proc check(name: string; snes: uint32; off: int; nodes: seq[AsmNode];
           flags: FlagState; gold: seq[uint8]) =
  let data = assemble(nodes, snes, flags)
  var mism = 0
  for i, b in data:
    if gold[off + i] != b:
      mism += 1
      echo &"  {name} +{i}: {b:02X} vs gold {gold[off+i]:02X}"
  if mism == 0:
    echo &"OK {name} 0x{off:06X}+{data.len} exact"
  else:
    echo &"FAIL {name} {mism}"
    quit 1

let gold = readGoldBaseromBytes()
let f16 = FlagState(m8: false, x8: false, emulation: false)

check("TYA;RTL head", 0xC0922F'u32, 0x00922F, @[
  instr("TYA", amImplied),
  instr("RTL", amImplied),
], f16, gold)

check("PLD;RTS head", 0xC16170'u32, 0x016170, @[
  instr("PLD", amImplied),
  instr("RTS", amImplied),
], f16, gold)

check("LDA;PLD;RTS head", 0xC16EBA'u32, 0x016EBA, @[
  instr("LDA", amImmediateM, 0x0),
  instr("PLD", amImplied),
  instr("RTS", amImplied),
], f16, gold)

# Also assemble a bit more of 016170 to match gold after free
check("016170+20", 0xC16170'u32, 0x016170, @[
  instr("PLD", amImplied),
  instr("RTS", amImplied),
  instr("REP", amImmediate8, 0x31),
  instr("PHD", amImplied),
  instr("PHA", amImplied),
  instr("TDC", amImplied),
  instr("ADC", amImmediateM, 0xFFEC),
  instr("TCD", amImplied),
  instr("PLA", amImplied),
  instr("TXA", amImplied),
  instr("LDX", amImmediateX, 0x0),
  instr("STX", amDirectPage, 0x12),
], f16, gold)

check("016EBA+20", 0xC16EBA'u32, 0x016EBA, @[
  instr("LDA", amImmediateM, 0x0),
  instr("PLD", amImplied),
  instr("RTS", amImplied),
  instr("REP", amImmediate8, 0x31),
  instr("PHD", amImplied),
  instr("PHA", amImplied),
  instr("TDC", amImplied),
  instr("ADC", amImmediateM, 0xFFEE),
  instr("TCD", amImplied),
], f16, gold)

echo "all seed heads exact"
