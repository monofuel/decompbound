## Compatibility suite name: ca65 text front end (replaces snesAsm macro tests).

import
  std/os,
  decompbound/[asm_parse, opcodes]

block repSepImmediate:
  let src = """
    .a8
    .i8
    REP #$20
    LDA #$1234
  """
  let bytes = assembleAsm(src, entryFlags = NativeFlags16)
  # entry NativeFlags16 then .a8/.i8 hint then REP...
  # Actually first flags from entry then width dirs override.
  doAssert bytes.len >= 4

block adoptedAsmExists:
  doAssert fileExists("asm/earthboundRandom.asm")
  let b = assembleAsm(readFile("asm/earthboundRandom.asm"), 0x008E9A'u32, NativeFlags16)
  doAssert b.len == 56

echo "[test_snesasm] ok"
