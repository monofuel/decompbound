## ca65-convention 65816 assembly text front end → AsmNode stream.
## Feeds existing assemble() / opcodes.nim. M/X via .a8/.a16/.i8/.i16 and REP/SEP.

import
  std/[parseutils, strformat, strutils, tables],
  ./[assembler, opcodes]

type
  AsmParseError* = object of CatchableError
    line*: int

proc parseError(line: int, msg: string) =
  ## Raise a parse error with line context.
  var e: ref AsmParseError
  new(e)
  e.msg = &"line {line}: {msg}"
  e.line = line
  raise e

proc stripComment(line: string): string =
  ## Remove ; and // comments outside of quotes (we have no strings yet).
  var i = 0
  while i < line.len:
    if line[i] == ';':
      return line[0 ..< i]
    if i + 1 < line.len and line[i] == '/' and line[i + 1] == '/':
      return line[0 ..< i]
    i += 1
  result = line

proc parseHexInt(s: string): uint32 =
  ## Parse $hex or plain decimal.
  var t = s.strip()
  if t.startsWith("$"):
    t = t[1 .. ^1]
    var v: int
    if parseHex(t, v) != t.len:
      raise newException(ValueError, &"bad hex: {s}")
    result = v.uint32
  else:
    var v: int
    if parseInt(t, v) != t.len:
      raise newException(ValueError, &"bad int: {s}")
    result = v.uint32

proc hexDigitWidth(s: string): int =
  ## Count hex digits after optional $.
  var t = s.strip()
  if t.startsWith("$"):
    t = t[1 .. ^1]
  result = t.len

proc isIdentChar(c: char): bool =
  ## Label / mnemonic character.
  c.isAlphaNumeric or c == '_'

proc parseLabelOrDirective(line: string, lineNo: int, nodes: var seq[AsmNode]): bool =
  ## Handle `name:` labels and `.a8`/`.byte`/… directives. Returns true if consumed.
  let t = line.strip()
  if t.len == 0:
    return true
  if t.endsWith(":") and not t.startsWith("."):
    let name = t[0 ..< ^1].strip()
    if name.len == 0:
      parseError(lineNo, "empty label")
    nodes.add label(name)
    return true
  if not t.startsWith("."):
    return false
  let parts = t.splitWhitespace()
  let dir = parts[0].toLowerAscii
  case dir
  of ".a8":
    # Preserve index width from previous hint if any — use last flagHint or default m8.
    nodes.add flagHint(true, true)  # refined below by dual-width tracking in multi-pass? 
    # Simpler: .a8 only sets M; we encode as m8=true and keep x from a paired model.
    # assemble() flagHint sets both. Emit only M change by reading: use a sticky pair.
    discard
  else:
    discard
  # Handled in main with sticky m8/x8 state.
  result = false

type
  WidthState = object
    m8: bool
    x8: bool

proc emitWidth(nodes: var seq[AsmNode], w: WidthState) =
  ## Push explicit flag hint for current width state.
  nodes.add flagHint(w.m8, w.x8)

proc classifyOperand(operand: string, m8, x8: bool): tuple[mode: AddressingMode, value: uint32, target: string] =
  ## Map ca65-style operand text to AddressingMode + value or label target.
  let o = operand.strip()
  if o.len == 0:
    return (amImplied, 0'u32, "")

  # Accumulator.
  if o == "A" or o == "a":
    return (amAccumulator, 0'u32, "")

  # Immediate: #expr
  if o.startsWith("#"):
    let imm = o[1 .. ^1].strip()
    let v = parseHexInt(imm)
    # Width for # depends on caller mnemonic class — use size of hex digits as hint
    # when ambiguous; prefer flag state for M/X immediates.
    let digits = hexDigitWidth(imm)
    if digits <= 2 and (m8 or digits == 2):
      # still may be 8-bit M or X — caller adjusts via mnemonic
      return (amImmediateM, v, "")  # patched by caller
    return (amImmediateM, v, "")

  # Block move: $aa,$bb
  if "," in o and not o.endsWith(",X") and not o.endsWith(",Y") and
      not o.endsWith(",S") and not o.endsWith(",x") and not o.endsWith(",y") and
      not o.endsWith(",s") and not o.startsWith("(") and not o.startsWith("["):
    let bits = o.split(",")
    if bits.len == 2 and bits[0].strip().startsWith("$") and bits[1].strip().startsWith("$"):
      let dst = parseHexInt(bits[0])
      let src = parseHexInt(bits[1])
      return (amBlockMove, dst or (src shl 8), "")

  # (sr,S),Y
  if o.startsWith("(") and (",S),Y" in o.toUpperAscii or ",s),y" in o):
    let inner = o.strip(chars = {'(', ')'})
    # form: $nn,S),Y already stripped wrong — parse carefully
    let up = o.toUpperAscii
    let p = up.find(",S),Y")
    if p > 0:
      let num = o[1 ..< p]
      return (amStackRelativeY, parseHexInt(num), "")

  # (dp,X)
  if o.startsWith("(") and (o.endsWith(",X)") or o.endsWith(",x)")):
    let inner = o[1 ..< ^3].strip()  # drop ( and ,X)
    return (amDpIndirectX, parseHexInt(inner), "")

  # (abs,X) for JMP/JSR — 4+ hex digits
  if o.startsWith("(") and (o.endsWith(",X)") or o.endsWith(",x)")):
    discard

  # (dp),Y
  if o.startsWith("(") and (o.endsWith("),Y") or o.endsWith("),y")):
    let inner = o[1 ..< ^3].strip()
    return (amDpIndirectY, parseHexInt(inner), "")

  # (dp)
  if o.startsWith("(") and o.endsWith(")") and "," notin o:
    let inner = o[1 ..< ^1].strip()
    let digits = hexDigitWidth(inner)
    if digits <= 2:
      return (amDpIndirect, parseHexInt(inner), "")
    return (amAbsIndirect, parseHexInt(inner), "")

  # [dp],Y
  if o.startsWith("[") and (o.endsWith("],Y") or o.endsWith("],y")):
    let inner = o[1 ..< ^3].strip()
    return (amDpIndirectLongY, parseHexInt(inner), "")

  # [abs] or [dp]
  if o.startsWith("[") and o.endsWith("]") and "," notin o:
    let inner = o[1 ..< ^1].strip()
    let digits = hexDigitWidth(inner)
    if digits <= 2:
      return (amDpIndirectLong, parseHexInt(inner), "")
    return (amAbsIndirectLong, parseHexInt(inner), "")

  # sr,S
  if o.endsWith(",S") or o.endsWith(",s"):
    let num = o[0 ..< ^2].strip()
    return (amStackRelative, parseHexInt(num), "")

  # abs,X / dp,X
  if o.endsWith(",X") or o.endsWith(",x"):
    let num = o[0 ..< ^2].strip()
    if num.startsWith("("):
      # (abs,X)
      let inner = num.strip(chars = {'(', ')'}).strip()
      return (amAbsIndirectX, parseHexInt(inner), "")
    let digits = hexDigitWidth(num)
    if digits <= 2:
      return (amDirectPageX, parseHexInt(num), "")
    if digits <= 4:
      return (amAbsoluteX, parseHexInt(num), "")
    return (amAbsoluteLongX, parseHexInt(num), "")

  # abs,Y / dp,Y
  if o.endsWith(",Y") or o.endsWith(",y"):
    let num = o[0 ..< ^2].strip()
    let digits = hexDigitWidth(num)
    if digits <= 2:
      return (amDirectPageY, parseHexInt(num), "")
    return (amAbsoluteY, parseHexInt(num), "")

  # bare number (incl. signed branch offsets like +42 / -2) or label
  if o.startsWith("$") or o[0].isDigit or (o[0] in {'+', '-'} and o.len > 1 and o[1].isDigit):
    if o[0] in {'+', '-'} and not o.startsWith("$"):
      var iv: int
      if parseInt(o, iv) != o.len:
        raise newException(ValueError, &"bad signed int: {o}")
      # Relative operands are raw encoded offsets; callers set amRelative*.
      return (amRelative8, cast[uint32](cast[uint8](iv.int8)), "")
    let digits = hexDigitWidth(o)
    let v = parseHexInt(o)
    if digits <= 2:
      return (amDirectPage, v, "")
    if digits <= 4:
      return (amAbsolute, v, "")
    return (amAbsoluteLong, v, "")

  # relative branch target as signed decimal already handled as number
  # label name
  return (amAbsolute, 0'u32, o)

proc fixImmediateMode(mnemonic: string, mode: AddressingMode, m8, x8: bool): AddressingMode =
  ## Choose M/X/8 immediate mode from mnemonic.
  if mode != amImmediateM:
    return mode
  let m = mnemonic.toUpperAscii
  case m
  of "REP", "SEP", "BRK", "COP", "WDM":
    amImmediate8
  of "LDX", "LDY", "CPX", "CPY":
    amImmediateX
  else:
    amImmediateM

proc fixBranchMode(mnemonic: string, mode: AddressingMode, target: string, value: uint32):
    tuple[mode: AddressingMode, value: uint32, target: string] =
  ## Branches: label → relative; numeric → relative offset.
  let m = mnemonic.toUpperAscii
  let isBr8 = m in ["BPL", "BMI", "BVC", "BVS", "BCC", "BCS", "BNE", "BEQ", "BRA", "BRL"]
  let isBr16 = m == "BRL" or m == "PER"
  if not isBr8 and m != "PER":
    return (mode, value, target)
  if target.len > 0:
    if m == "BRL" or m == "PER":
      return (amRelative16, 0'u32, target)
    return (amRelative8, 0'u32, target)
  # numeric offset
  if m == "BRL" or m == "PER":
    return (amRelative16, value, "")
  return (amRelative8, value, "")

proc parseDataDirective(dir: string, rest: string, lineNo: int, nodes: var seq[AsmNode]) =
  ## .byte / .word / .db / .dw → sequence of instructions? We emit raw via synthetic.
  ## Data is encoded as a chain of .byte-equivalent by using a side channel:
  ## for the assembler front end, expand to PEA/etc is wrong. Instead store as
  ## multiple 1-byte "BRK" — no, we need real data emission.
  ##
  ## Phase-2 v1: represent data with ankInstr is wrong. Extend by assembling
  ## via a post-pass: we inject pseudo nodes... For simplicity, encode data as
  ## a list of bytes by using assemble only for code, and for .byte we append
  ## using a parallel path.
  ##
  ## Here we only support code + width + labels for the fixture gate. Data
  ## directives raise a clear error if used without data support.
  ## Actually implement .byte/.word as raw bytes via a small extension:
  discard dir
  discard rest
  discard lineNo
  discard nodes

# Data bytes collected separately for hybrid programs.
type
  AsmProgram* = object
    nodes*: seq[AsmNode]
    ## Optional raw bytes spliced after assembly at end — unused for pure code.
    entryFlags*: FlagState

proc parseAsm*(source: string, entryFlags: FlagState = FlagState(m8: true, x8: true, emulation: false)): seq[AsmNode] =
  ## Parse ca65-convention assembly text into AsmNode list for assemble().
  var nodes: seq[AsmNode] = @[]
  var width = WidthState(m8: entryFlags.m8, x8: entryFlags.x8)
  var widthDirty = true  # emit initial hint so assemble entry matches
  var lineNo = 0
  for rawLine in source.splitLines():
    lineNo += 1
    var line = stripComment(rawLine).strip()
    if line.len == 0:
      continue

    # Label alone or label + insn on same line.
    var labelName = ""
    if not line.startsWith("."):
      let colon = line.find(':')
      if colon > 0:
        var allIdent = true
        for c in line[0 ..< colon]:
          if not isIdentChar(c):
            allIdent = false
            break
        if allIdent:
          labelName = line[0 ..< colon].strip()
          line = line[colon + 1 .. ^1].strip()
          nodes.add label(labelName)
          if line.len == 0:
            continue

    # Directives.
    if line.startsWith("."):
      let parts = line.splitWhitespace()
      let dir = parts[0].toLowerAscii
      case dir
      of ".a8":
        width.m8 = true
        widthDirty = true
      of ".a16":
        width.m8 = false
        widthDirty = true
      of ".i8":
        width.x8 = true
        widthDirty = true
      of ".i16":
        width.x8 = false
        widthDirty = true
      of ".byte", ".db":
        let rest = line[parts[0].len .. ^1].strip()
        var raw: seq[uint8] = @[]
        for tok in rest.split(','):
          let tt = tok.strip()
          if tt.len == 0: continue
          raw.add uint8(parseHexInt(tt) and 0xFF)
        nodes.add rawData(raw)
      of ".word", ".dw":
        let rest = line[parts[0].len .. ^1].strip()
        var raw: seq[uint8] = @[]
        for tok in rest.split(','):
          let tt = tok.strip()
          if tt.len == 0: continue
          let v = parseHexInt(tt)
          raw.add uint8(v and 0xFF)
          raw.add uint8((v shr 8) and 0xFF)
        nodes.add rawData(raw)
      of ".smart":
        discard  # REP/SEP tracking is always on in assemble()
      else:
        parseError(lineNo, &"unknown directive {dir}")
      continue

    if widthDirty:
      emitWidth(nodes, width)
      widthDirty = false

    # Instruction: MNEMONIC operand...
    let sp = line.find(' ')
    var mnem: string
    var operand: string
    if sp < 0:
      mnem = line
      operand = ""
    else:
      mnem = line[0 ..< sp]
      operand = line[sp + 1 .. ^1].strip()
    mnem = mnem.toUpperAscii

    var mode: AddressingMode
    var value: uint32
    var target: string
    if operand.len == 0:
      mode = amImplied
      # Accumulator forms written as "INC A" already have operand A.
    else:
      let c = classifyOperand(operand, width.m8, width.x8)
      mode = c.mode
      value = c.value
      target = c.target

    mode = fixImmediateMode(mnem, mode, width.m8, width.x8)
    let br = fixBranchMode(mnem, mode, target, value)
    mode = br.mode
    value = br.value
    target = br.target

    # JMP (abs,X) vs dp indirect X: if mnemonic is JMP/JSR and mode is dp ind X with large — 
    if mnem in ["JMP", "JSR"] and mode == amDpIndirectX:
      # operand was (abs,X) with 4 digits — re-check
      let o = operand.strip()
      if o.startsWith("(") and (o.endsWith(",X)") or o.endsWith(",x)")):
        let inner = o[1 ..< ^3].strip()
        if hexDigitWidth(inner) > 2:
          mode = amAbsIndirectX
          value = parseHexInt(inner)

    # JML [abs]
    if mnem == "JML" and mode == amDpIndirectLong:
      mode = amAbsIndirectLong

    # Prefer accumulator mode for INC/DEC/ASL/LSR/ROL/ROR when operand is A or empty with A form
    if operand.toUpperAscii == "A":
      mode = amAccumulator

    if target.len > 0:
      nodes.add instrTo(mnem, mode, target)
    else:
      nodes.add instr(mnem, mode, value)

    # Track local width from REP/SEP text for subsequent immediates in the source.
    if mnem == "REP":
      let bits = value
      if (bits and 0x20) != 0: width.m8 = false
      if (bits and 0x10) != 0: width.x8 = false
    elif mnem == "SEP":
      let bits = value
      if (bits and 0x20) != 0: width.m8 = true
      if (bits and 0x10) != 0: width.x8 = true

  result = nodes

proc assembleAsm*(
    source: string,
    origin: uint32 = 0,
    entryFlags: FlagState = FlagState(m8: true, x8: true, emulation: false)
): seq[uint8] =
  ## Parse ca65 text and assemble to bytes.
  let nodes = parseAsm(source, entryFlags)
  assemble(nodes, origin, entryFlags)
