## Disassemble bytes to ca65-convention text for committed `.asm` sources.

import
  std/[strformat, strutils],
  ./[assembler, opcodes]

proc emitWidth(m8, x8: bool): string =
  ## ca65 width directives for the current M/X state.
  result = ""
  if m8: result.add ".a8\n" else: result.add ".a16\n"
  if x8: result.add ".i8\n" else: result.add ".i16\n"

proc bytesToCa65*(
    data: openArray[uint8],
    origin: uint32,
    entryFlags: FlagState,
    headerComment: string = ""
): string =
  ## Turn a linear code blob into ca65-ish text that re-assembles byte-exact.
  var lines: seq[string] = @[]
  if headerComment.len > 0:
    for line in headerComment.splitLines():
      if line.len > 0:
        lines.add "; " & line
      else:
        lines.add ";"
  lines.add &"; origin file/SNES context: ${origin:06X}"
  lines.add emitWidth(entryFlags.m8, entryFlags.x8).strip()
  var flags = entryFlags
  var offset = 0
  var lastM = entryFlags.m8
  var lastX = entryFlags.x8
  while offset < data.len:
    let opSize = operandSize(OpcodeTable[data[offset]].mode, flags)
    if offset + 1 + opSize > data.len:
      # Residual bytes as .byte
      var parts: seq[string] = @[]
      for i in offset ..< data.len:
        parts.add &"${data[i]:02X}"
      lines.add ".byte " & parts.join(", ")
      break
    let instr = decode(data, offset, flags)
    if flags.m8 != lastM or flags.x8 != lastX:
      lines.add emitWidth(flags.m8, flags.x8).strip()
      lastM = flags.m8
      lastX = flags.x8
    lines.add formatInstruction(instr)
    flags.applyInstruction(instr.opcode, instr.operand)
    # After REP/SEP, next line may need width refresh for readability.
    if instr.opcode in [0xC2'u8, 0xE2'u8]:
      lastM = flags.m8
      lastX = flags.x8
      lines.add emitWidth(flags.m8, flags.x8).strip()
    offset += instr.size
  result = lines.join("\n") & "\n"

proc dataBytesToCa65*(
    data: openArray[uint8],
    origin: uint32,
    headerComment: string = ""
): string =
  ## Emit a pure data region as `.byte` lines (16 bytes per line).
  var lines: seq[string] = @[]
  if headerComment.len > 0:
    for line in headerComment.splitLines():
      lines.add "; " & line
  lines.add &"; data origin ${origin:06X} length {data.len}"
  var i = 0
  while i < data.len:
    let chunkEnd = min(i + 16, data.len)
    var parts: seq[string] = @[]
    for j in i ..< chunkEnd:
      parts.add &"${data[j]:02X}"
    lines.add ".byte " & parts.join(", ")
    i = chunkEnd
  result = lines.join("\n") & "\n"
