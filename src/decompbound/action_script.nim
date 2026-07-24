## Entity action-script bytecode walker (structure only).
##
## Operand widths reverse-engineered from the `$C09558` dispatch handlers
## (docs/scripts.md; re-verified 2026-07-24 against `code_bank00` generateCode0095F2
## bodies — stream INY only, excluding call-stack INYs). All low-path ops
## `0x00`–`0x4C` have known widths. Used to claim residual unclaimed ROM as
## `ekActionScript` without embedding script content — offset/length + structural
## gates only.
##
## Safe claim unit: a linear walk of known-width ops that ends on a control
## transfer (GOTO/GOSUB/halt/high-path) and includes signature ops `0x06` WAIT,
## `0x19` GOTO, `0x1A` GOSUB, or `0x42` FAR CALL. Classic idle block:
## `42 xx xx bb | 06 ww | 19 tt tt` (9 bytes, bank `$C0`–`$FF`).

const
  ## Minimum bytes for a residual action-script claim span.
  ActionScriptMinLen* = 6
  ## Minimum signature ops (WAIT/GOTO/GOSUB/FAR CALL) inside a claim.
  ActionScriptMinSig* = 1
  ## Max ops in one linear walk (safety bound).
  ActionScriptMaxOps* = 512
  ## Valid far-call bank range (HiROM game banks).
  ActionScriptBankLo* = 0xC0
  ActionScriptBankHi* = 0xFF

  ## Operand widths for low-path opcodes `0x00`–`0x4C`. `-1` = unsafe/unknown.
  ## Stream INY only (call-stack INYs on GOSUB paths are not stream advances).
  ## Control-transfer ops consume their operands then replace Y.
  ActionScriptOperandWidths*: array[256, int] = block:
    var w: array[256, int]
    for i in 0..255:
      w[i] = -1
    w[0x00] = 0
    w[0x01] = 1
    w[0x02] = 0
    w[0x03] = 3
    w[0x04] = 3
    w[0x05] = 0
    w[0x06] = 1
    w[0x07] = 2
    w[0x08] = 3
    w[0x09] = 0
    w[0x0A] = 2
    w[0x0B] = 2
    w[0x0C] = 0  # no stream ops; entity link/unlink style (handler $99C3)
    w[0x0D] = 5  # bitop: u16 addr + u8 sub + u16 value (handler $9A9F)
    w[0x0E] = 3
    w[0x0F] = 0
    w[0x10] = 1
    w[0x11] = 1  # switch/case on $1516 (handler $999E); control transfer
    w[0x12] = 3
    w[0x13] = 0
    w[0x14] = 4  # field-index bitop: u8 field + u8 sub + u16 val (handler $9A87)
    w[0x15] = 4
    w[0x16] = 2
    w[0x17] = 2  # conditional GOTO/return (handler $9B44); control transfer
    w[0x18] = 4
    w[0x19] = 2
    w[0x1A] = 2
    w[0x1B] = 0
    w[0x1C] = 3
    w[0x1D] = 2
    w[0x1E] = 2
    w[0x1F] = 1
    w[0x20] = 1
    w[0x21] = 1
    w[0x22] = 2
    w[0x23] = 2
    w[0x24] = 0
    w[0x25] = 2
    w[0x26] = 1
    w[0x27] = 3  # bitop on $1516,X: u8 sub + u16 val (handler $9A97)
    w[0x28] = 2
    w[0x29] = 2
    w[0x2A] = 2
    w[0x2B] = 2
    w[0x2C] = 2
    w[0x2D] = 2
    w[0x2E] = 2
    w[0x2F] = 2
    w[0x30] = 2
    w[0x31] = 3
    w[0x32] = 3
    w[0x33] = 3
    w[0x34] = 3
    w[0x35] = 3
    w[0x36] = 3
    w[0x37] = 3
    w[0x38] = 3
    w[0x39] = 0
    w[0x3A] = 1
    w[0x3B] = 1
    w[0x3C] = 0
    w[0x3D] = 0
    w[0x3E] = 1
    w[0x3F] = 2
    w[0x40] = 2
    w[0x41] = 2
    w[0x42] = 3
    w[0x43] = 1
    w[0x44] = 0
    # Tail ops 0x45..0x4C alias high-path handlers (same as 0x3B..0x42).
    w[0x45] = 1  # same $96CF as 0x3B
    w[0x46] = 0  # same $9A38 as 0x3C
    w[0x47] = 0  # same $9A3E as 0x3D
    w[0x48] = 1  # same $9A44 as 0x3E
    w[0x49] = 2  # same $9713 as 0x3F
    w[0x4A] = 2  # same $9731 as 0x40
    w[0x4B] = 2  # same $974F as 0x41
    w[0x4C] = 3  # same $993D as 0x42 (FAR CALL)
    w

  ## Ops that end a linear walk (Y replaced or halt/self-loop).
  ActionScriptTerminal*: array[256, bool] = block:
    var t: array[256, bool]
    for i in 0..255:
      t[i] = false
    t[0x00] = true
    t[0x03] = true
    t[0x04] = true
    t[0x09] = true
    t[0x0A] = true
    t[0x0B] = true
    t[0x11] = true
    t[0x16] = true
    t[0x17] = true
    t[0x19] = true
    t[0x1A] = true
    t

type
  ## One linear walk result (no decoded script text/content).
  ActionScriptWalk* = object
    length*: int
    ops*: int
    sig*: int
    ended*: bool

proc isSignatureOp*(op: int): bool =
  ## True for WAIT / GOTO / GOSUB / FAR CALL (incl. 0x4C alias).
  op in [0x06, 0x19, 0x1A, 0x42, 0x4C]

proc walkActionScript*(rom: openArray[uint8]; start, limit: int): ActionScriptWalk =
  ## Walk one action-script stream from start until terminal/high/unknown/limit.
  ## Validates FAR CALL banks; does not emit content.
  result = ActionScriptWalk()
  var pos = start
  while pos < limit and result.ops < ActionScriptMaxOps:
    let op = int(rom[pos])
    if op >= 0x70:
      pos += 1
      result.ops += 1
      result.length = pos - start
      result.ended = true
      return
    let w = ActionScriptOperandWidths[op]
    if w < 0:
      result.length = pos - start
      return
    if pos + 1 + w > limit:
      result.length = pos - start
      return
    if op in [0x42, 0x4C]:
      let bank = int(rom[pos + 3])
      if bank < ActionScriptBankLo or bank > ActionScriptBankHi:
        result.length = pos - start
        return
    if isSignatureOp(op):
      result.sig += 1
    pos += 1 + w
    result.ops += 1
    if ActionScriptTerminal[op]:
      result.length = pos - start
      result.ended = true
      return
  result.length = pos - start

proc isGoodActionScriptWalk*(w: ActionScriptWalk): bool =
  ## True when a walk is a claimable residual action-script unit.
  if not w.ended:
    return false
  if w.length < 6 or w.ops < 2:
    return false
  if w.sig < 1:
    return false
  result = true

proc isIdleActionBlock*(rom: openArray[uint8]; offset: int): bool =
  ## Classic 9-byte idle: FAR CALL + WAIT + GOTO with bank in `$C0`–`$FF`.
  if offset + 9 > rom.len:
    return false
  if rom[offset] != 0x42:
    return false
  let bank = int(rom[offset + 3])
  if bank < ActionScriptBankLo or bank > ActionScriptBankHi:
    return false
  if rom[offset + 4] != 0x06:
    return false
  if rom[offset + 6] != 0x19:
    return false
  result = true

proc consumeActionScriptRun*(rom: openArray[uint8]; start, length: int): int =
  ## Cover `[start, start+length)` with consecutive good walks; return consumed.
  ## Returns `length` on full cover, else bytes consumed before the first hole.
  let limit = start + length
  var pos = start
  while pos < limit:
    let w = walkActionScript(rom, pos, limit)
    if not isGoodActionScriptWalk(w):
      return pos - start
    pos += w.length
  result = pos - start

proc countSignatureBytes*(rom: openArray[uint8]; start, length: int): int =
  ## Count raw signature opcode bytes in a span (density gate for merged runs).
  result = 0
  for i in start ..< start + length:
    if i >= rom.len:
      break
    if isSignatureOp(int(rom[i])):
      result += 1

proc isGoodActionScriptSpan*(rom: openArray[uint8]; start, length: int): bool =
  ## True when a residual span is fully covered by good walks and passes gates.
  if length < ActionScriptMinLen:
    return false
  if consumeActionScriptRun(rom, start, length) != length:
    return false
  if countSignatureBytes(rom, start, length) < ActionScriptMinSig:
    return false
  result = true
