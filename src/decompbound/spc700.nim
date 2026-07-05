## SPC700 CPU core: the audio processor (Goal 2a, docs/audio.md).
## Instruction-level accuracy verified against SingleStepTests spc700
## vectors (tests/test_spc700.nim). The DSP and timers layer on later;
## this core plus 64KB RAM is what an SPC player needs.

const
  PswC* = 0x01'u8  ## Carry.
  PswZ* = 0x02'u8  ## Zero.
  PswI* = 0x04'u8  ## Interrupt enable.
  PswH* = 0x08'u8  ## Half carry.
  PswB* = 0x10'u8  ## Break.
  PswP* = 0x20'u8  ## Direct page selector.
  PswV* = 0x40'u8  ## Overflow.
  PswN* = 0x80'u8  ## Negative.

const
  IplRom*: array[64, uint8] = [
    0xCD'u8, 0xEF, 0xBD, 0xE8, 0x00, 0xC6, 0x1D, 0xD0, 0xFC, 0x8F, 0xAA, 0xF4, 0x8F, 0xBB, 0xF5, 0x78,
    0xCC, 0xF4, 0xD0, 0xFB, 0x2F, 0x19, 0xEB, 0xF4, 0xD0, 0xFC, 0x7E, 0xF4, 0xD0, 0x0B, 0xE4, 0xF5,
    0xCB, 0xF4, 0xD7, 0x00, 0xFC, 0xD0, 0xF3, 0xAB, 0x01, 0x10, 0xEF, 0x7E, 0xF4, 0x10, 0xEB, 0xBA,
    0xF6, 0xDA, 0x00, 0xBA, 0xF4, 0xC4, 0xF4, 0xDD, 0x5D, 0xD0, 0xDB, 0x1F, 0x00, 0x00, 0xC0, 0xFF]
    ## The standard 64-byte SPC700 IPL boot ROM at $FFC0-$FFFF. Its reset
    ## vector ($FFFE/F) points at $FFC0; it runs the upload handshake the main
    ## CPU speaks over the APU ports. Only mapped in when iplEnabled (real boot).

type
  Spc* = object
    a*: uint8
    x*: uint8
    y*: uint8
    sp*: uint8
    pc*: uint16
    psw*: uint8
    ram*: ref array[0x10000, uint8]
    stopped*: bool
    iplEnabled*: bool  ## When set, $FFC0-$FFFF reads the IPL ROM (default off:
                       ## plain RAM, so vector tests are unaffected). $F1 bit 7
                       ## clears it once the game's driver takes over.
    cycles*: int  ## Approximate cycle counter for timer pacing.
    readHook*: proc(address: uint16): int  ## $F0-$FF I/O; -1 = plain RAM.
    writeHook*: proc(address: uint16, value: uint8): bool

proc newSpc*(): Spc =
  ## Fresh SPC700 with zeroed RAM.
  result.ram = new(array[0x10000, uint8])

proc read8(spc: Spc, address: uint16): uint8 =
  ## Read one byte of APU RAM (I/O hooks cover $F0-$FF when installed; the IPL
  ## ROM overlays $FFC0-$FFFF while iplEnabled).
  if spc.readHook != nil and (address and 0xFFF0) == 0x00F0:
    let hooked = spc.readHook(address)
    if hooked >= 0:
      return hooked.uint8
  if spc.iplEnabled and address >= 0xFFC0:
    return IplRom[(address - 0xFFC0).int]
  spc.ram[address]

proc write8(spc: var Spc, address: uint16, value: uint8) =
  ## Write one byte of APU RAM.
  if spc.writeHook != nil and (address and 0xFFF0) == 0x00F0:
    if spc.writeHook(address, value):
      return
  spc.ram[address] = value

proc setFlag(spc: var Spc, flag: uint8, on: bool) =
  ## Set or clear one PSW bit.
  if on:
    spc.psw = spc.psw or flag
  else:
    spc.psw = spc.psw and not flag

proc getFlag(spc: Spc, flag: uint8): bool =
  ## Test one PSW bit.
  (spc.psw and flag) != 0

proc setNZ(spc: var Spc, value: uint8) =
  ## Set N and Z from an 8-bit result.
  spc.setFlag(PswZ, value == 0)
  spc.setFlag(PswN, (value and 0x80) != 0)

proc setNZ16(spc: var Spc, value: uint16) =
  ## Set N and Z from a 16-bit result.
  spc.setFlag(PswZ, value == 0)
  spc.setFlag(PswN, (value and 0x8000) != 0)

proc dpBase(spc: Spc): uint16 =
  ## Direct page base selected by the P flag.
  if spc.getFlag(PswP): 0x0100'u16 else: 0x0000'u16

proc fetch8(spc: var Spc): uint8 =
  ## Fetch the next program byte.
  result = spc.read8(spc.pc)
  spc.pc = spc.pc + 1

proc fetch16(spc: var Spc): uint16 =
  ## Fetch a little-endian program word.
  result = spc.fetch8().uint16
  result = result or (spc.fetch8().uint16 shl 8)

proc push8(spc: var Spc, value: uint8) =
  ## Push to the page-1 stack.
  spc.write8(0x0100'u16 or spc.sp.uint16, value)
  spc.sp = spc.sp - 1

proc pull8(spc: var Spc): uint8 =
  ## Pull from the page-1 stack.
  spc.sp = spc.sp + 1
  result = spc.read8(0x0100'u16 or spc.sp.uint16)

proc push16(spc: var Spc, value: uint16) =
  ## Push a word, high byte first.
  spc.push8((value shr 8).uint8)
  spc.push8((value and 0xFF).uint8)

proc pull16(spc: var Spc): uint16 =
  ## Pull a word, low byte first.
  result = spc.pull8().uint16
  result = result or (spc.pull8().uint16 shl 8)

proc adc(spc: var Spc, a: uint8, b: uint8): uint8 =
  ## Add with carry: sets N, V, H, Z, C.
  let carryIn = if spc.getFlag(PswC): 1'u16 else: 0'u16
  let r = a.uint16 + b.uint16 + carryIn
  spc.setFlag(PswC, r > 0xFF)
  spc.setFlag(PswH, ((a and 0x0F) + (b and 0x0F) + carryIn.uint8) > 0x0F)
  spc.setFlag(PswV, ((not (a xor b)) and (a xor (r and 0xFF).uint8) and 0x80) != 0)
  result = (r and 0xFF).uint8
  spc.setNZ(result)

proc sbc(spc: var Spc, a: uint8, b: uint8): uint8 =
  ## Subtract with borrow via inverted-operand add.
  spc.adc(a, b xor 0xFF)

proc compare(spc: var Spc, a: uint8, b: uint8) =
  ## Compare: sets N, Z, C only.
  let r = a.int - b.int
  spc.setFlag(PswC, r >= 0)
  spc.setNZ((r and 0xFF).uint8)

proc branch(spc: var Spc, taken: bool) =
  ## Fetch a displacement and branch when taken.
  let disp = cast[int8](spc.fetch8())
  if taken:
    spc.pc = (spc.pc.int32 + disp.int32).uint16

proc dpAddr(spc: var Spc, index: uint8 = 0): uint16 =
  ## Fetch a direct-page operand; wraps within the selected page.
  spc.dpBase or ((spc.fetch8() + index) and 0xFF).uint16

proc absBit(spc: var Spc): tuple[address: uint16, bit: int] =
  ## Fetch the 13-bit address + 3-bit bit-number form used by bit ops.
  let operand = spc.fetch16()
  (address: operand and 0x1FFF, bit: (operand shr 13).int)

proc step*(spc: var Spc) =
  ## Execute one instruction.
  if spc.stopped:
    return
  spc.cycles += 4
  let opcode = spc.fetch8()

  # The regular ALU grid: rows 0x00-0xB0 in pairs, columns 4-9 share
  # addressing shapes across OR/AND/EOR/CMP/ADC/SBC.
  template aluOp(op: untyped) =
    ## Column dispatch for A-target ALU rows (x4..x9 and 1x4..1x9).
    discard

  case opcode:
  of 0x00: discard  # NOP.
  # TCALL n: vector at 0xFFDE - 2n.
  of 0x01, 0x11, 0x21, 0x31, 0x41, 0x51, 0x61, 0x71,
     0x81, 0x91, 0xA1, 0xB1, 0xC1, 0xD1, 0xE1, 0xF1:
    let n = (opcode shr 4).uint16
    spc.push16(spc.pc)
    spc.pc = spc.read8(0xFFDE - 2 * n).uint16 or
      (spc.read8(0xFFDF - 2 * n).uint16 shl 8)
  # SET1/CLR1 dp.bit.
  of 0x02, 0x22, 0x42, 0x62, 0x82, 0xA2, 0xC2, 0xE2:
    let address = spc.dpAddr()
    let bit = (opcode shr 5).int
    spc.write8(address, spc.read8(address) or (1'u8 shl bit))
  of 0x12, 0x32, 0x52, 0x72, 0x92, 0xB2, 0xD2, 0xF2:
    let address = spc.dpAddr()
    let bit = (opcode shr 5).int
    spc.write8(address, spc.read8(address) and not (1'u8 shl bit))
  # BBS/BBC dp.bit, rel.
  of 0x03, 0x23, 0x43, 0x63, 0x83, 0xA3, 0xC3, 0xE3:
    let value = spc.read8(spc.dpAddr())
    let bit = (opcode shr 5).int
    spc.branch(((value shr bit) and 1) != 0)
  of 0x13, 0x33, 0x53, 0x73, 0x93, 0xB3, 0xD3, 0xF3:
    let value = spc.read8(spc.dpAddr())
    let bit = (opcode shr 5).int
    spc.branch(((value shr bit) and 1) == 0)

  # OR.
  of 0x04: spc.a = spc.a or spc.read8(spc.dpAddr()); spc.setNZ(spc.a)
  of 0x05: spc.a = spc.a or spc.read8(spc.fetch16()); spc.setNZ(spc.a)
  of 0x06: spc.a = spc.a or spc.read8(spc.dpBase or spc.x.uint16); spc.setNZ(spc.a)
  of 0x07:
    let base = spc.dpAddr(spc.x)
    let target = spc.read8(base).uint16 or
      (spc.read8(spc.dpBase or ((base + 1) and 0xFF)).uint16 shl 8)
    spc.a = spc.a or spc.read8(target)
    spc.setNZ(spc.a)
  of 0x08: spc.a = spc.a or spc.fetch8(); spc.setNZ(spc.a)
  of 0x09:
    let src = spc.read8(spc.dpAddr())
    let dstAddr = spc.dpAddr()
    let r = spc.read8(dstAddr) or src
    spc.write8(dstAddr, r)
    spc.setNZ(r)
  of 0x14: spc.a = spc.a or spc.read8(spc.dpAddr(spc.x)); spc.setNZ(spc.a)
  of 0x15: spc.a = spc.a or spc.read8(spc.fetch16() + spc.x.uint16); spc.setNZ(spc.a)
  of 0x16: spc.a = spc.a or spc.read8(spc.fetch16() + spc.y.uint16); spc.setNZ(spc.a)
  of 0x17:
    let base = spc.dpAddr()
    let target = (spc.read8(base).uint16 or
      (spc.read8(spc.dpBase or ((base + 1) and 0xFF)).uint16 shl 8)) + spc.y.uint16
    spc.a = spc.a or spc.read8(target)
    spc.setNZ(spc.a)
  of 0x18:
    let value = spc.fetch8()
    let address = spc.dpAddr()
    let r = spc.read8(address) or value
    spc.write8(address, r)
    spc.setNZ(r)
  of 0x19:
    let r = spc.read8(spc.dpBase or spc.x.uint16) or
      spc.read8(spc.dpBase or spc.y.uint16)
    spc.write8(spc.dpBase or spc.x.uint16, r)
    spc.setNZ(r)

  # Branches and flag ops in the x0 column.
  of 0x10: spc.branch(not spc.getFlag(PswN))
  of 0x30: spc.branch(spc.getFlag(PswN))
  of 0x50: spc.branch(not spc.getFlag(PswV))
  of 0x70: spc.branch(spc.getFlag(PswV))
  of 0x90: spc.branch(not spc.getFlag(PswC))
  of 0xB0: spc.branch(spc.getFlag(PswC))
  of 0xD0: spc.branch(not spc.getFlag(PswZ))
  of 0xF0: spc.branch(spc.getFlag(PswZ))
  of 0x2F: spc.branch(true)
  of 0x20: spc.setFlag(PswP, false)
  of 0x40: spc.setFlag(PswP, true)
  of 0x60: spc.setFlag(PswC, false)
  of 0x80: spc.setFlag(PswC, true)
  of 0xA0: spc.setFlag(PswI, true)
  of 0xC0: spc.setFlag(PswI, false)
  of 0xE0:
    spc.setFlag(PswV, false)
    spc.setFlag(PswH, false)
  of 0xED: spc.setFlag(PswC, not spc.getFlag(PswC))

  # AND.
  of 0x24: spc.a = spc.a and spc.read8(spc.dpAddr()); spc.setNZ(spc.a)
  of 0x25: spc.a = spc.a and spc.read8(spc.fetch16()); spc.setNZ(spc.a)
  of 0x26: spc.a = spc.a and spc.read8(spc.dpBase or spc.x.uint16); spc.setNZ(spc.a)
  of 0x27:
    let base = spc.dpAddr(spc.x)
    let target = spc.read8(base).uint16 or
      (spc.read8(spc.dpBase or ((base + 1) and 0xFF)).uint16 shl 8)
    spc.a = spc.a and spc.read8(target)
    spc.setNZ(spc.a)
  of 0x28: spc.a = spc.a and spc.fetch8(); spc.setNZ(spc.a)
  of 0x29:
    let src = spc.read8(spc.dpAddr())
    let dstAddr = spc.dpAddr()
    let r = spc.read8(dstAddr) and src
    spc.write8(dstAddr, r)
    spc.setNZ(r)
  of 0x34: spc.a = spc.a and spc.read8(spc.dpAddr(spc.x)); spc.setNZ(spc.a)
  of 0x35: spc.a = spc.a and spc.read8(spc.fetch16() + spc.x.uint16); spc.setNZ(spc.a)
  of 0x36: spc.a = spc.a and spc.read8(spc.fetch16() + spc.y.uint16); spc.setNZ(spc.a)
  of 0x37:
    let base = spc.dpAddr()
    let target = (spc.read8(base).uint16 or
      (spc.read8(spc.dpBase or ((base + 1) and 0xFF)).uint16 shl 8)) + spc.y.uint16
    spc.a = spc.a and spc.read8(target)
    spc.setNZ(spc.a)
  of 0x38:
    let value = spc.fetch8()
    let address = spc.dpAddr()
    let r = spc.read8(address) and value
    spc.write8(address, r)
    spc.setNZ(r)
  of 0x39:
    let r = spc.read8(spc.dpBase or spc.x.uint16) and
      spc.read8(spc.dpBase or spc.y.uint16)
    spc.write8(spc.dpBase or spc.x.uint16, r)
    spc.setNZ(r)

  # EOR.
  of 0x44: spc.a = spc.a xor spc.read8(spc.dpAddr()); spc.setNZ(spc.a)
  of 0x45: spc.a = spc.a xor spc.read8(spc.fetch16()); spc.setNZ(spc.a)
  of 0x46: spc.a = spc.a xor spc.read8(spc.dpBase or spc.x.uint16); spc.setNZ(spc.a)
  of 0x47:
    let base = spc.dpAddr(spc.x)
    let target = spc.read8(base).uint16 or
      (spc.read8(spc.dpBase or ((base + 1) and 0xFF)).uint16 shl 8)
    spc.a = spc.a xor spc.read8(target)
    spc.setNZ(spc.a)
  of 0x48: spc.a = spc.a xor spc.fetch8(); spc.setNZ(spc.a)
  of 0x49:
    let src = spc.read8(spc.dpAddr())
    let dstAddr = spc.dpAddr()
    let r = spc.read8(dstAddr) xor src
    spc.write8(dstAddr, r)
    spc.setNZ(r)
  of 0x54: spc.a = spc.a xor spc.read8(spc.dpAddr(spc.x)); spc.setNZ(spc.a)
  of 0x55: spc.a = spc.a xor spc.read8(spc.fetch16() + spc.x.uint16); spc.setNZ(spc.a)
  of 0x56: spc.a = spc.a xor spc.read8(spc.fetch16() + spc.y.uint16); spc.setNZ(spc.a)
  of 0x57:
    let base = spc.dpAddr()
    let target = (spc.read8(base).uint16 or
      (spc.read8(spc.dpBase or ((base + 1) and 0xFF)).uint16 shl 8)) + spc.y.uint16
    spc.a = spc.a xor spc.read8(target)
    spc.setNZ(spc.a)
  of 0x58:
    let value = spc.fetch8()
    let address = spc.dpAddr()
    let r = spc.read8(address) xor value
    spc.write8(address, r)
    spc.setNZ(r)
  of 0x59:
    let r = spc.read8(spc.dpBase or spc.x.uint16) xor
      spc.read8(spc.dpBase or spc.y.uint16)
    spc.write8(spc.dpBase or spc.x.uint16, r)
    spc.setNZ(r)

  # CMP A.
  of 0x64: spc.compare(spc.a, spc.read8(spc.dpAddr()))
  of 0x65: spc.compare(spc.a, spc.read8(spc.fetch16()))
  of 0x66: spc.compare(spc.a, spc.read8(spc.dpBase or spc.x.uint16))
  of 0x67:
    let base = spc.dpAddr(spc.x)
    let target = spc.read8(base).uint16 or
      (spc.read8(spc.dpBase or ((base + 1) and 0xFF)).uint16 shl 8)
    spc.compare(spc.a, spc.read8(target))
  of 0x68: spc.compare(spc.a, spc.fetch8())
  of 0x69:
    let src = spc.read8(spc.dpAddr())
    let dst = spc.read8(spc.dpAddr())
    spc.compare(dst, src)
  of 0x74: spc.compare(spc.a, spc.read8(spc.dpAddr(spc.x)))
  of 0x75: spc.compare(spc.a, spc.read8(spc.fetch16() + spc.x.uint16))
  of 0x76: spc.compare(spc.a, spc.read8(spc.fetch16() + spc.y.uint16))
  of 0x77:
    let base = spc.dpAddr()
    let target = (spc.read8(base).uint16 or
      (spc.read8(spc.dpBase or ((base + 1) and 0xFF)).uint16 shl 8)) + spc.y.uint16
    spc.compare(spc.a, spc.read8(target))
  of 0x78:
    let value = spc.fetch8()
    let address = spc.dpAddr()
    spc.compare(spc.read8(address), value)
  of 0x79:
    spc.compare(spc.read8(spc.dpBase or spc.x.uint16),
                spc.read8(spc.dpBase or spc.y.uint16))

  # ADC.
  of 0x84: spc.a = spc.adc(spc.a, spc.read8(spc.dpAddr()))
  of 0x85: spc.a = spc.adc(spc.a, spc.read8(spc.fetch16()))
  of 0x86: spc.a = spc.adc(spc.a, spc.read8(spc.dpBase or spc.x.uint16))
  of 0x87:
    let base = spc.dpAddr(spc.x)
    let target = spc.read8(base).uint16 or
      (spc.read8(spc.dpBase or ((base + 1) and 0xFF)).uint16 shl 8)
    spc.a = spc.adc(spc.a, spc.read8(target))
  of 0x88: spc.a = spc.adc(spc.a, spc.fetch8())
  of 0x89:
    let src = spc.read8(spc.dpAddr())
    let dstAddr = spc.dpAddr()
    spc.write8(dstAddr, spc.adc(spc.read8(dstAddr), src))
  of 0x94: spc.a = spc.adc(spc.a, spc.read8(spc.dpAddr(spc.x)))
  of 0x95: spc.a = spc.adc(spc.a, spc.read8(spc.fetch16() + spc.x.uint16))
  of 0x96: spc.a = spc.adc(spc.a, spc.read8(spc.fetch16() + spc.y.uint16))
  of 0x97:
    let base = spc.dpAddr()
    let target = (spc.read8(base).uint16 or
      (spc.read8(spc.dpBase or ((base + 1) and 0xFF)).uint16 shl 8)) + spc.y.uint16
    spc.a = spc.adc(spc.a, spc.read8(target))
  of 0x98:
    let value = spc.fetch8()
    let address = spc.dpAddr()
    spc.write8(address, spc.adc(spc.read8(address), value))
  of 0x99:
    let r = spc.adc(spc.read8(spc.dpBase or spc.x.uint16),
                    spc.read8(spc.dpBase or spc.y.uint16))
    spc.write8(spc.dpBase or spc.x.uint16, r)

  # SBC.
  of 0xA4: spc.a = spc.sbc(spc.a, spc.read8(spc.dpAddr()))
  of 0xA5: spc.a = spc.sbc(spc.a, spc.read8(spc.fetch16()))
  of 0xA6: spc.a = spc.sbc(spc.a, spc.read8(spc.dpBase or spc.x.uint16))
  of 0xA7:
    let base = spc.dpAddr(spc.x)
    let target = spc.read8(base).uint16 or
      (spc.read8(spc.dpBase or ((base + 1) and 0xFF)).uint16 shl 8)
    spc.a = spc.sbc(spc.a, spc.read8(target))
  of 0xA8: spc.a = spc.sbc(spc.a, spc.fetch8())
  of 0xA9:
    let src = spc.read8(spc.dpAddr())
    let dstAddr = spc.dpAddr()
    spc.write8(dstAddr, spc.sbc(spc.read8(dstAddr), src))
  of 0xB4: spc.a = spc.sbc(spc.a, spc.read8(spc.dpAddr(spc.x)))
  of 0xB5: spc.a = spc.sbc(spc.a, spc.read8(spc.fetch16() + spc.x.uint16))
  of 0xB6: spc.a = spc.sbc(spc.a, spc.read8(spc.fetch16() + spc.y.uint16))
  of 0xB7:
    let base = spc.dpAddr()
    let target = (spc.read8(base).uint16 or
      (spc.read8(spc.dpBase or ((base + 1) and 0xFF)).uint16 shl 8)) + spc.y.uint16
    spc.a = spc.sbc(spc.a, spc.read8(target))
  of 0xB8:
    let value = spc.fetch8()
    let address = spc.dpAddr()
    spc.write8(address, spc.sbc(spc.read8(address), value))
  of 0xB9:
    let r = spc.sbc(spc.read8(spc.dpBase or spc.x.uint16),
                    spc.read8(spc.dpBase or spc.y.uint16))
    spc.write8(spc.dpBase or spc.x.uint16, r)

  # Bit-carry ops.
  of 0x0A:
    let (address, bit) = spc.absBit()
    spc.setFlag(PswC, spc.getFlag(PswC) or
      (((spc.read8(address) shr bit) and 1) != 0))
  of 0x2A:
    let (address, bit) = spc.absBit()
    spc.setFlag(PswC, spc.getFlag(PswC) or
      (((spc.read8(address) shr bit) and 1) == 0))
  of 0x4A:
    let (address, bit) = spc.absBit()
    spc.setFlag(PswC, spc.getFlag(PswC) and
      (((spc.read8(address) shr bit) and 1) != 0))
  of 0x6A:
    let (address, bit) = spc.absBit()
    spc.setFlag(PswC, spc.getFlag(PswC) and
      (((spc.read8(address) shr bit) and 1) == 0))
  of 0x8A:
    let (address, bit) = spc.absBit()
    spc.setFlag(PswC, spc.getFlag(PswC) xor
      (((spc.read8(address) shr bit) and 1) != 0))
  of 0xAA:
    let (address, bit) = spc.absBit()
    spc.setFlag(PswC, ((spc.read8(address) shr bit) and 1) != 0)
  of 0xCA:
    let (address, bit) = spc.absBit()
    let value = spc.read8(address)
    if spc.getFlag(PswC):
      spc.write8(address, value or (1'u8 shl bit))
    else:
      spc.write8(address, value and not (1'u8 shl bit))
  of 0xEA:
    let (address, bit) = spc.absBit()
    spc.write8(address, spc.read8(address) xor (1'u8 shl bit))

  # Shifts and rotates.
  of 0x0B, 0x0C, 0x1B, 0x1C, 0x2B, 0x2C, 0x3B, 0x3C,
     0x4B, 0x4C, 0x5B, 0x5C, 0x6B, 0x6C, 0x7B, 0x7C:
    var address: uint16
    var value: uint8
    # Rows pair up: even-high-nibble x0B = dp, x0C = !abs; odd-high-nibble
    # x1B = dp+X, x1C = A.
    let oddRow = ((opcode shr 4) and 1) == 1
    let onA = (opcode and 0x0F) == 0x0C and oddRow
    if onA:
      value = spc.a
    else:
      if (opcode and 0x0F) == 0x0B:
        address = if oddRow: spc.dpAddr(spc.x) else: spc.dpAddr()
      else:
        address = spc.fetch16()
      value = spc.read8(address)
    var r: uint8
    let carryIn = if spc.getFlag(PswC): 1'u8 else: 0'u8
    case opcode shr 5:
    of 0:  # ASL.
      spc.setFlag(PswC, (value and 0x80) != 0)
      r = value shl 1
    of 1:  # ROL.
      spc.setFlag(PswC, (value and 0x80) != 0)
      r = (value shl 1) or carryIn
    of 2:  # LSR.
      spc.setFlag(PswC, (value and 1) != 0)
      r = value shr 1
    else:  # ROR.
      spc.setFlag(PswC, (value and 1) != 0)
      r = (value shr 1) or (carryIn shl 7)
    spc.setNZ(r)
    if onA:
      spc.a = r
    else:
      spc.write8(address, r)

  # INC/DEC memory and registers.
  of 0x8B: (let a = spc.dpAddr(); let r = spc.read8(a) - 1; spc.write8(a, r); spc.setNZ(r))
  of 0x8C: (let a = spc.fetch16(); let r = spc.read8(a) - 1; spc.write8(a, r); spc.setNZ(r))
  of 0x9B: (let a = spc.dpAddr(spc.x); let r = spc.read8(a) - 1; spc.write8(a, r); spc.setNZ(r))
  of 0x9C: spc.a = spc.a - 1; spc.setNZ(spc.a)
  of 0x1D: spc.x = spc.x - 1; spc.setNZ(spc.x)
  of 0xDC: spc.y = spc.y - 1; spc.setNZ(spc.y)
  of 0xAB: (let a = spc.dpAddr(); let r = spc.read8(a) + 1; spc.write8(a, r); spc.setNZ(r))
  of 0xAC: (let a = spc.fetch16(); let r = spc.read8(a) + 1; spc.write8(a, r); spc.setNZ(r))
  of 0xBB: (let a = spc.dpAddr(spc.x); let r = spc.read8(a) + 1; spc.write8(a, r); spc.setNZ(r))
  of 0xBC: spc.a = spc.a + 1; spc.setNZ(spc.a)
  of 0x3D: spc.x = spc.x + 1; spc.setNZ(spc.x)
  of 0xFC: spc.y = spc.y + 1; spc.setNZ(spc.y)

  # 16-bit word ops on direct page.
  of 0x1A:  # DECW.
    let address = spc.dpAddr()
    let hiAddr = spc.dpBase or ((address + 1) and 0xFF)
    var w = spc.read8(address).uint16 or (spc.read8(hiAddr).uint16 shl 8)
    w = w - 1
    spc.write8(address, (w and 0xFF).uint8)
    spc.write8(hiAddr, (w shr 8).uint8)
    spc.setNZ16(w)
  of 0x3A:  # INCW.
    let address = spc.dpAddr()
    let hiAddr = spc.dpBase or ((address + 1) and 0xFF)
    var w = spc.read8(address).uint16 or (spc.read8(hiAddr).uint16 shl 8)
    w = w + 1
    spc.write8(address, (w and 0xFF).uint8)
    spc.write8(hiAddr, (w shr 8).uint8)
    spc.setNZ16(w)
  of 0x5A:  # CMPW YA, dp.
    let address = spc.dpAddr()
    let hiAddr = spc.dpBase or ((address + 1) and 0xFF)
    let w = spc.read8(address).uint16 or (spc.read8(hiAddr).uint16 shl 8)
    let ya = spc.a.uint16 or (spc.y.uint16 shl 8)
    let r = ya.int - w.int
    spc.setFlag(PswC, r >= 0)
    spc.setNZ16((r and 0xFFFF).uint16)
  of 0x7A:  # ADDW YA, dp.
    let address = spc.dpAddr()
    let hiAddr = spc.dpBase or ((address + 1) and 0xFF)
    let w = spc.read8(address).uint16 or (spc.read8(hiAddr).uint16 shl 8)
    let ya = spc.a.uint16 or (spc.y.uint16 shl 8)
    let r = ya.uint32 + w.uint32
    spc.setFlag(PswC, r > 0xFFFF)
    spc.setFlag(PswH, ((ya and 0x0FFF) + (w and 0x0FFF)) > 0x0FFF)
    spc.setFlag(PswV, ((not (ya xor w)) and (ya xor (r and 0xFFFF).uint16) and 0x8000) != 0)
    spc.a = (r and 0xFF).uint8
    spc.y = ((r shr 8) and 0xFF).uint8
    spc.setNZ16((r and 0xFFFF).uint16)
  of 0x9A:  # SUBW YA, dp.
    let address = spc.dpAddr()
    let hiAddr = spc.dpBase or ((address + 1) and 0xFF)
    let w = spc.read8(address).uint16 or (spc.read8(hiAddr).uint16 shl 8)
    let ya = spc.a.uint16 or (spc.y.uint16 shl 8)
    let inverted = w xor 0xFFFF
    let r = ya.uint32 + inverted.uint32 + 1
    spc.setFlag(PswC, r > 0xFFFF)
    spc.setFlag(PswH, ((ya and 0x0FFF) + (inverted and 0x0FFF) + 1) > 0x0FFF)
    spc.setFlag(PswV, ((not (ya xor inverted)) and (ya xor (r and 0xFFFF).uint16) and 0x8000) != 0)
    spc.a = (r and 0xFF).uint8
    spc.y = ((r shr 8) and 0xFF).uint8
    spc.setNZ16((r and 0xFFFF).uint16)
  of 0xBA:  # MOVW YA, dp.
    let address = spc.dpAddr()
    let hiAddr = spc.dpBase or ((address + 1) and 0xFF)
    spc.a = spc.read8(address)
    spc.y = spc.read8(hiAddr)
    spc.setNZ16(spc.a.uint16 or (spc.y.uint16 shl 8))
  of 0xDA:  # MOVW dp, YA.
    let address = spc.dpAddr()
    let hiAddr = spc.dpBase or ((address + 1) and 0xFF)
    spc.write8(address, spc.a)
    spc.write8(hiAddr, spc.y)

  # CMP X / CMP Y.
  of 0x1E: spc.compare(spc.x, spc.read8(spc.fetch16()))
  of 0x3E: spc.compare(spc.x, spc.read8(spc.dpAddr()))
  of 0xC8: spc.compare(spc.x, spc.fetch8())
  of 0x5E: spc.compare(spc.y, spc.read8(spc.fetch16()))
  of 0x7E: spc.compare(spc.y, spc.read8(spc.dpAddr()))
  of 0xAD: spc.compare(spc.y, spc.fetch8())

  # Stack.
  of 0x0D: spc.push8(spc.psw)
  of 0x2D: spc.push8(spc.a)
  of 0x4D: spc.push8(spc.x)
  of 0x6D: spc.push8(spc.y)
  of 0x8E: spc.psw = spc.pull8()
  of 0xAE: spc.a = spc.pull8()
  of 0xCE: spc.x = spc.pull8()
  of 0xEE: spc.y = spc.pull8()

  # Calls, returns, jumps.
  of 0x3F:
    let target = spc.fetch16()
    spc.push16(spc.pc)
    spc.pc = target
  of 0x4F:
    let target = spc.fetch8()
    spc.push16(spc.pc)
    spc.pc = 0xFF00'u16 or target.uint16
  of 0x5F: spc.pc = spc.fetch16()
  of 0x1F:
    let base = spc.fetch16() + spc.x.uint16
    spc.pc = spc.read8(base).uint16 or (spc.read8(base + 1).uint16 shl 8)
  of 0x6F: spc.pc = spc.pull16()
  of 0x7F:
    spc.psw = spc.pull8()
    spc.pc = spc.pull16()
  of 0x0F:  # BRK.
    spc.push16(spc.pc)
    spc.push8(spc.psw)
    spc.setFlag(PswB, true)
    spc.setFlag(PswI, false)
    spc.pc = spc.read8(0xFFDE).uint16 or (spc.read8(0xFFDF).uint16 shl 8)

  # Conditional loop branches.
  of 0x2E:
    let value = spc.read8(spc.dpAddr())
    spc.branch(spc.a != value)
  of 0xDE:
    let value = spc.read8(spc.dpAddr(spc.x))
    spc.branch(spc.a != value)
  of 0x6E:
    let address = spc.dpAddr()
    let r = spc.read8(address) - 1
    spc.write8(address, r)
    spc.branch(r != 0)
  of 0xFE:
    spc.y = spc.y - 1
    spc.branch(spc.y != 0)

  # TSET1/TCLR1.
  of 0x0E:
    let address = spc.fetch16()
    let value = spc.read8(address)
    spc.setNZ(spc.a - value)
    spc.write8(address, value or spc.a)
  of 0x4E:
    let address = spc.fetch16()
    let value = spc.read8(address)
    spc.setNZ(spc.a - value)
    spc.write8(address, value and not spc.a)

  # MOV stores (no flags).
  of 0xC4: spc.write8(spc.dpAddr(), spc.a)
  of 0xC5: spc.write8(spc.fetch16(), spc.a)
  of 0xC6: spc.write8(spc.dpBase or spc.x.uint16, spc.a)
  of 0xC7:
    let base = spc.dpAddr(spc.x)
    let target = spc.read8(base).uint16 or
      (spc.read8(spc.dpBase or ((base + 1) and 0xFF)).uint16 shl 8)
    spc.write8(target, spc.a)
  of 0xC9: spc.write8(spc.fetch16(), spc.x)
  of 0xCB: spc.write8(spc.dpAddr(), spc.y)
  of 0xCC: spc.write8(spc.fetch16(), spc.y)
  of 0xD4: spc.write8(spc.dpAddr(spc.x), spc.a)
  of 0xD5: spc.write8(spc.fetch16() + spc.x.uint16, spc.a)
  of 0xD6: spc.write8(spc.fetch16() + spc.y.uint16, spc.a)
  of 0xD7:
    let base = spc.dpAddr()
    let target = (spc.read8(base).uint16 or
      (spc.read8(spc.dpBase or ((base + 1) and 0xFF)).uint16 shl 8)) + spc.y.uint16
    spc.write8(target, spc.a)
  of 0xD8: spc.write8(spc.dpAddr(), spc.x)
  of 0xD9: spc.write8(spc.dpAddr(spc.y), spc.x)
  of 0xDB: spc.write8(spc.dpAddr(spc.x), spc.y)
  of 0xAF:
    spc.write8(spc.dpBase or spc.x.uint16, spc.a)
    spc.x = spc.x + 1
  of 0xFA:
    let src = spc.read8(spc.dpAddr())
    spc.write8(spc.dpAddr(), src)
  of 0x8F:
    let value = spc.fetch8()
    spc.write8(spc.dpAddr(), value)

  # MOV loads (set NZ).
  of 0xE4: spc.a = spc.read8(spc.dpAddr()); spc.setNZ(spc.a)
  of 0xE5: spc.a = spc.read8(spc.fetch16()); spc.setNZ(spc.a)
  of 0xE6: spc.a = spc.read8(spc.dpBase or spc.x.uint16); spc.setNZ(spc.a)
  of 0xE7:
    let base = spc.dpAddr(spc.x)
    let target = spc.read8(base).uint16 or
      (spc.read8(spc.dpBase or ((base + 1) and 0xFF)).uint16 shl 8)
    spc.a = spc.read8(target)
    spc.setNZ(spc.a)
  of 0xE8: spc.a = spc.fetch8(); spc.setNZ(spc.a)
  of 0xE9: spc.x = spc.read8(spc.fetch16()); spc.setNZ(spc.x)
  of 0xEB: spc.y = spc.read8(spc.dpAddr()); spc.setNZ(spc.y)
  of 0xEC: spc.y = spc.read8(spc.fetch16()); spc.setNZ(spc.y)
  of 0xF4: spc.a = spc.read8(spc.dpAddr(spc.x)); spc.setNZ(spc.a)
  of 0xF5: spc.a = spc.read8(spc.fetch16() + spc.x.uint16); spc.setNZ(spc.a)
  of 0xF6: spc.a = spc.read8(spc.fetch16() + spc.y.uint16); spc.setNZ(spc.a)
  of 0xF7:
    let base = spc.dpAddr()
    let target = (spc.read8(base).uint16 or
      (spc.read8(spc.dpBase or ((base + 1) and 0xFF)).uint16 shl 8)) + spc.y.uint16
    spc.a = spc.read8(target)
    spc.setNZ(spc.a)
  of 0xF8: spc.x = spc.read8(spc.dpAddr()); spc.setNZ(spc.x)
  of 0xF9: spc.x = spc.read8(spc.dpAddr(spc.y)); spc.setNZ(spc.x)
  of 0xFB: spc.y = spc.read8(spc.dpAddr(spc.x)); spc.setNZ(spc.y)
  of 0xBF:
    spc.a = spc.read8(spc.dpBase or spc.x.uint16)
    spc.x = spc.x + 1
    spc.setNZ(spc.a)
  of 0xCD: spc.x = spc.fetch8(); spc.setNZ(spc.x)
  of 0x8D: spc.y = spc.fetch8(); spc.setNZ(spc.y)

  # Register moves.
  of 0x5D: spc.x = spc.a; spc.setNZ(spc.x)
  of 0x7D: spc.a = spc.x; spc.setNZ(spc.a)
  of 0x9D: spc.x = spc.sp; spc.setNZ(spc.x)
  of 0xBD: spc.sp = spc.x
  of 0xDD: spc.a = spc.y; spc.setNZ(spc.a)
  of 0xFD: spc.y = spc.a; spc.setNZ(spc.y)

  # Arithmetic specials.
  of 0xCF:  # MUL YA.
    let r = spc.y.uint16 * spc.a.uint16
    spc.a = (r and 0xFF).uint8
    spc.y = (r shr 8).uint8
    spc.setNZ(spc.y)
  of 0x9E:  # DIV YA, X.
    let ya = spc.a.uint32 or (spc.y.uint32 shl 8)
    spc.setFlag(PswH, (spc.x and 0x0F) <= (spc.y and 0x0F))
    spc.setFlag(PswV, spc.y >= spc.x)
    if spc.y.uint32 < (spc.x.uint32 shl 1):
      spc.a = ((ya div spc.x.uint32) and 0xFF).uint8
      spc.y = ((ya mod spc.x.uint32) and 0xFF).uint8
    else:
      spc.a = (255 - (ya - (spc.x.uint32 shl 9)) div (256 - spc.x.uint32)).uint8
      spc.y = (spc.x.uint32 + (ya - (spc.x.uint32 shl 9)) mod (256 - spc.x.uint32)).uint8
    spc.setNZ(spc.a)
  of 0xDF:  # DAA: high digit first, then low (silicon order).
    if spc.getFlag(PswC) or spc.a > 0x99:
      spc.setFlag(PswC, true)
      spc.a = spc.a + 0x60
    if spc.getFlag(PswH) or (spc.a and 0x0F) > 9:
      spc.a = spc.a + 6
    spc.setNZ(spc.a)
  of 0xBE:  # DAS: high digit first, then low.
    if not spc.getFlag(PswC) or spc.a > 0x99:
      spc.setFlag(PswC, false)
      spc.a = spc.a - 0x60
    if not spc.getFlag(PswH) or (spc.a and 0x0F) > 9:
      spc.a = spc.a - 6
    spc.setNZ(spc.a)
  of 0x9F:  # XCN.
    spc.a = (spc.a shr 4) or (spc.a shl 4)
    spc.setNZ(spc.a)

  of 0xEF: spc.stopped = true  # SLEEP.
  of 0xFF: spc.stopped = true  # STOP.

  else:
    doAssert false, "unhandled opcode: " & $opcode
