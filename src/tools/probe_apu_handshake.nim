## Ticket H: APU handshake RE — extract stuck state, scan SPC driver for $F4
## port poll/echo, dump S-CPU protocol context. Untracked dig; stdout only.

import
  std/[os, strformat, options, strutils, tables],
  ../decompbound/[cpu, snesbus, save_state, png_state, apu, spc700]

const
  DefaultRom = "bin/Earthbound (U) [!].smc"
  DefaultPng = "/home/monofuel/Pictures/Screenshots/earthbound_20260709-214129.png"

proc readRom(path: string): seq[uint8] =
  ## Load ROM, strip optional 512-byte header.
  var d = cast[seq[uint8]](readFile(path))
  if d.len mod 1024 == 512: d = d[512 .. ^1]
  d

# Minimal SPC700 disasm for annotation (common opcodes only).
proc disasmSpcAt(ram: openArray[uint8], pc0: int, nInstr: int): string =
  ## Disassemble nInstr instructions starting at pc0 (wrap in 64K).
  var pc = pc0 and 0xFFFF
  var lines: seq[string]
  for _ in 0 ..< nInstr:
    let op = ram[pc]
    var text = &"db ${op:02X}"
    var len = 1
    let b1 = ram[(pc + 1) and 0xFFFF]
    let b2 = ram[(pc + 2) and 0xFFFF]
    case op:
    of 0x00: text = "NOP"
    of 0x1F: text = &"JMP [{b1:02X}{b2:02X}+X]"; len = 3
    of 0x2F: text = &"BRA {cast[int8](b1).int:+d}"; len = 2
    of 0x3F: text = &"CALL ${b2:02X}{b1:02X}"; len = 3
    of 0x4F: text = &"PCALL ${b1:02X}"; len = 2
    of 0x5F: text = &"JMP ${b2:02X}{b1:02X}"; len = 3
    of 0x6F: text = "RET"
    of 0x7F: text = "RETI"
    of 0x8F: text = &"MOV ${b2:02X},#${b1:02X}"; len = 3
    of 0xCD: text = &"MOV X,#${b1:02X}"; len = 2
    of 0x8D: text = &"MOV Y,#${b1:02X}"; len = 2
    of 0xE8: text = &"MOV A,#${b1:02X}"; len = 2
    of 0xE4: text = &"MOV A,${b1:02X}"; len = 2
    of 0xE5: text = &"MOV A,!${b2:02X}{b1:02X}"; len = 3
    of 0xC4: text = &"MOV ${b1:02X},A"; len = 2
    of 0xC5: text = &"MOV !${b2:02X}{b1:02X},A"; len = 3
    of 0xC6: text = "MOV (X),A"
    of 0xD4: text = &"MOV ${b1:02X}+X,A"; len = 2
    of 0xD6: text = &"MOV !${b2:02X}{b1:02X}+Y,A"; len = 3
    of 0xD7: text = &"MOV [${b1:02X}]+Y,A"; len = 2
    of 0xD8: text = &"MOV ${b1:02X},X"; len = 2
    of 0xDB: text = &"MOV ${b1:02X}+X,Y"; len = 2
    of 0xCB: text = &"MOV ${b1:02X},Y"; len = 2
    of 0xC9: text = &"MOV !${b2:02X}{b1:02X},X"; len = 3
    of 0xF4: text = &"MOV A,${b1:02X}+X"; len = 2
    of 0xF5: text = &"MOV A,!${b2:02X}{b1:02X}+X"; len = 3
    of 0xF6: text = &"MOV A,!${b2:02X}{b1:02X}+Y"; len = 3
    of 0xF8: text = &"MOV X,${b1:02X}"; len = 2
    of 0xEB: text = &"MOV Y,${b1:02X}"; len = 2
    of 0xDD: text = "MOV A,Y"
    of 0xFD: text = "MOV Y,A"
    of 0x5D: text = "MOV X,A"
    of 0x7D: text = "MOV A,X"
    of 0x9D: text = "MOV X,SP"
    of 0xBD: text = "MOV SP,X"
    of 0xAF: text = "MOV (X)+,A"
    of 0xBF: text = "MOV A,(X)+"
    of 0xE6: text = "MOV A,(X)"
    of 0x64: text = &"CMP A,${b1:02X}"; len = 2
    of 0x68: text = &"CMP A,#${b1:02X}"; len = 2
    of 0x78: text = &"CMP ${b2:02X},#${b1:02X}"; len = 3
    of 0x7E: text = &"CMP Y,${b1:02X}"; len = 2
    of 0xAD: text = &"CMP Y,#${b1:02X}"; len = 2
    of 0xC8: text = &"CMP X,#${b1:02X}"; len = 2
    of 0xD0: text = &"BNE {cast[int8](b1).int:+d}"; len = 2
    of 0xF0: text = &"BEQ {cast[int8](b1).int:+d}"; len = 2
    of 0x10: text = &"BPL {cast[int8](b1).int:+d}"; len = 2
    of 0x30: text = &"BMI {cast[int8](b1).int:+d}"; len = 2
    of 0x50: text = &"BVC {cast[int8](b1).int:+d}"; len = 2
    of 0x70: text = &"BVS {cast[int8](b1).int:+d}"; len = 2
    of 0x90: text = &"BCC {cast[int8](b1).int:+d}"; len = 2
    of 0xB0: text = &"BCS {cast[int8](b1).int:+d}"; len = 2
    of 0x2D: text = "PUSH A"
    of 0x4D: text = "PUSH X"
    of 0x6D: text = "PUSH Y"
    of 0x0D: text = "PUSH PSW"
    of 0xAE: text = "POP A"
    of 0xCE: text = "POP X"
    of 0xEE: text = "POP Y"
    of 0x8E: text = "POP PSW"
    of 0xBC: text = "INC A"
    of 0x3D: text = "INC X"
    of 0xFC: text = "INC Y"
    of 0x9C: text = "DEC A"
    of 0x1D: text = "DEC X"
    of 0xDC: text = "DEC Y"
    of 0x60: text = "CLRC"
    of 0x80: text = "SETC"
    of 0xED: text = "NOTC"
    of 0x20: text = "CLRP"
    of 0x40: text = "SETP"
    of 0xE0: text = "CLRV"
    of 0xBA: text = &"MOVW YA,${b1:02X}"; len = 2
    of 0xDA: text = &"MOVW ${b1:02X},YA"; len = 2
    of 0x7A: text = &"ADDW YA,${b1:02X}"; len = 2
    of 0x9A: text = &"SUBW YA,${b1:02X}"; len = 2
    of 0x5A: text = &"CMPW YA,${b1:02X}"; len = 2
    of 0x3A: text = &"INCW ${b1:02X}"; len = 2
    of 0x1A: text = &"DECW ${b1:02X}"; len = 2
    of 0xFA: text = &"MOV ${b2:02X},${b1:02X}"; len = 3
    of 0xAB: text = &"INC ${b1:02X}"; len = 2
    of 0x8B: text = &"DEC ${b1:02X}"; len = 2
    of 0xBB: text = &"INC ${b1:02X}+X"; len = 2
    of 0x9B: text = &"DEC ${b1:02X}+X"; len = 2
    of 0x1C: text = "ASL A"
    of 0x5C: text = "LSR A"
    of 0x3C: text = "ROL A"
    of 0x7C: text = "ROR A"
    of 0x9F: text = "XCN A"
    of 0xDF: text = "DAA"
    of 0xBE: text = "DAS"
    of 0x04, 0x14, 0x24, 0x34, 0x44, 0x54, 0x74, 0x84, 0x94, 0xA4, 0xB4:
      text = &"op{op:02X} ${b1:02X}"; len = 2
    else:
      # bit ops
      if (op and 0x0F) == 0x02:
        text = &"SET1 ${b1:02X}.{(op shr 5)}"; len = 2
      elif (op and 0x0F) == 0x12:
        text = &"CLR1 ${b1:02X}.{(op shr 5)}"; len = 2
      elif (op and 0x0F) == 0x03:
        text = &"BBS ${b1:02X}.{(op shr 5)},{cast[int8](b2).int:+d}"; len = 3
      elif (op and 0x0F) == 0x13:
        text = &"BBC ${b1:02X}.{(op shr 5)},{cast[int8](b2).int:+d}"; len = 3
      else:
        text = &"db ${op:02X}"
    var bytes = ""
    for i in 0 ..< len:
      bytes.add &"{ram[(pc + i) and 0xFFFF]:02X} "
    lines.add &"  ${pc:04X}: {bytes:<12} {text}"
    pc = (pc + len) and 0xFFFF
  lines.join("\n")


proc scanPortRefs(ram: openArray[uint8], lo, hi: int): seq[int] =
  ## Find addresses in [lo,hi] that reference $F4-$F7 as direct-page operands.
  result = @[]
  var a = lo
  while a < hi and a < ram.len - 1:
    let op = ram[a]
    # 2-byte ops with dp operand: E4/C4/64/EB/CB/F8/D8/AB/8B/78 (3b)...
    # Look for byte F4-F7 as potential dp operand
    let b1 = ram[a+1]
    if b1 >= 0xF4 and b1 <= 0xF7:
      # Direct-page ops that can take $F4-$F7 as operand.
      if op in {0xE4'u8, 0xC4, 0x64, 0xEB, 0xCB, 0xF8, 0xD8, 0xAB, 0x8B,
                0x04, 0x14, 0x24, 0x34, 0x44, 0x54, 0x74, 0x84, 0x94, 0xA4, 0xB4,
                0xD4, 0xF4, 0x6E, 0x4E}:
        result.add a
      elif (op and 0x0F) in {0x4'u8, 0xB} or op in {0xFA'u8, 0x8F, 0x78, 0x69, 0x48}:
        result.add a
    # 3-byte: 8F ii dd / FA dd2 dd1 / 78 ii dd
    if a + 2 < ram.len:
      let b2 = ram[a+2]
      if b2 >= 0xF4 and b2 <= 0xF7 and op in {0x8F'u8, 0xFA, 0x78, 0x69, 0x48, 0x28, 0x08, 0x88, 0xA8}:
        result.add a
    a += 1

proc main() =
  ## Autopsy the battle-lock PNG for APU handshake protocol failure.
  let pngPath = if paramCount() >= 1: paramStr(1) else: DefaultPng
  let rom = readRom(DefaultRom)
  let extracted = extractState(cast[seq[uint8]](readFile(pngPath)))
  if extracted.isNone:
    echo "no ebSt"; quit(1)
  let snes = newSnesBus(rom)
  var c = snes.resetCpu()
  deserializeState(extracted.get, snes, c)

  let a = snes.apu
  let spc = a.spc
  let ram = spc.ram[]

  echo "=== LOADED (post resyncPortEchoAfterLoad) ==="
  echo &"CPU {c.pbr:02X}:{c.pc:04X} A={c.a:04X} X={c.x:04X} Y={c.y:04X} P={c.p:02X} S={c.s:04X}"
  echo &"INIDISP={snes.ppuRegs[0x00]:02X} NMITIMEN={snes.nmitimen:02X}"
  echo &"portsIn  = [{a.portsIn[0]:02X} {a.portsIn[1]:02X} {a.portsIn[2]:02X} {a.portsIn[3]:02X}]"
  echo &"portsOut = [{a.portsOut[0]:02X} {a.portsOut[1]:02X} {a.portsOut[2]:02X} {a.portsOut[3]:02X}]"
  echo &"SPC pc={spc.pc:04X} a={spc.a:02X} x={spc.x:02X} y={spc.y:02X} sp={spc.sp:02X} psw={spc.psw:02X} ipl={spc.iplEnabled} stop={spc.stopped}"
  let t0 = a.getTimerSnapshot(0)
  echo &"T0 en={t0.enabled} tgt={t0.target:02X} int={t0.internal:02X} ctr={t0.counter:02X} accum={t0.accum}"
  echo &"APU $F1 shadow via ram? ram[F1]={ram[0xF1]:02X} (may be stale; timers are hardware)"
  echo &"ram $00-$1F: " & (block:
    var s = ""
    for i in 0..0x1F: s.add &"{ram[i]:02X} "
    s)
  echo &"ram $50-$5F: " & (block:
    var s = ""
    for i in 0x50..0x5F: s.add &"{ram[i]:02X} "
    s)

  # IPL ROM disasm (for protocol reference)
  echo "\n=== IPL ROM ($FFC0) reference ==="
  var iplAsRam: array[0x10000, uint8]
  for i, b in IplRom:
    iplAsRam[0xFFC0 + i] = b
  echo disasmSpcAt(iplAsRam, 0xFFC0, 40)

  # Scan driver for $F4 refs in common ranges
  echo "\n=== SPC RAM $F4/$F5 refs in $0500-$1200 ==="
  let hits = scanPortRefs(ram, 0x0500, 0x1200)
  var seen: Table[int, bool]
  for h in hits:
    if h in seen: continue
    seen[h] = true
    let b0 = ram[h]
    let b1 = ram[h+1]
    let b2 = if h+2 < 0x10000: ram[h+2] else: 0
    echo &"  ${h:04X}: {b0:02X} {b1:02X} {b2:02X}"

  # Disasm around top hit clusters and known PC range
  echo "\n=== disasm around SPC PC and likely command loops ==="
  for base in [spc.pc.int - 16, 0x0500, 0x0540, 0x0570, 0x05A0, 0x0600, 0x0700, 0x0D00, 0x1100]:
    if base < 0: continue
    echo &"\n-- ${base:04X} --"
    echo disasmSpcAt(ram, base, 24)

  # Hex dump $0500-$0600 and around PC
  echo "\n=== hex $0500-$05FF ==="
  for row in 0..15:
    var s = &"${0x0500 + row*16:04X}:"
    for col in 0..15:
      s.add &" {ram[0x0500 + row*16 + col]:02X}"
    echo s

  # Without resync simulation: force mismatch and see if SPC ever echoes $1B
  echo "\n=== experiment: force in0=$1B out0=$00, run APU-only 200k samples ==="
  a.portsIn[0] = 0x1B
  a.portsOut[0] = 0x00
  # leave other ports
  var echoed = false
  var firstPc = spc.pc
  var maxPc = spc.pc
  var minPc = spc.pc
  for i in 0 ..< 200_000:
    discard a.runSample()
    if a.portsOut[0] == 0x1B:
      echo &"  ECHOED $1B after {i} samples (~{i.float*32/1024000.0*1000:.2f} ms) SPC={spc.pc:04X}"
      echoed = true
      break
    if spc.pc > maxPc: maxPc = spc.pc
    if spc.pc < minPc: minPc = spc.pc
  if not echoed:
    echo &"  NO ECHO in 200k samples. SPC range ${minPc:04X}-${maxPc:04X} last={spc.pc:04X} out0={a.portsOut[0]:02X}"

  # Try $FF reboot recognition
  echo "\n=== experiment: write in0=$FF (reboot), APU-only 50k samples ==="
  # reload state
  let snes2 = newSnesBus(rom)
  var c2 = snes2.resetCpu()
  deserializeState(extracted.get, snes2, c2)
  snes2.apu.portsIn[0] = 0xFF
  snes2.apu.portsOut[0] = 0x00
  var sawIpl = false
  var sawAa = false
  for i in 0 ..< 50_000:
    discard snes2.apu.runSample()
    if snes2.apu.spc.iplEnabled or snes2.apu.spc.pc >= 0xFFC0:
      echo &"  IPL-ish at sample {i} pc={snes2.apu.spc.pc:04X} ipl={snes2.apu.spc.iplEnabled}"
      sawIpl = true
      break
    if snes2.apu.portsOut[0] == 0xAA and snes2.apu.portsOut[1] == 0xBB:
      echo &"  AA/BB at sample {i} pc={snes2.apu.spc.pc:04X}"
      sawAa = true
      break
  if not sawIpl and not sawAa:
    echo &"  no IPL reboot; pc={snes2.apu.spc.pc:04X} out=[{snes2.apu.portsOut[0]:02X} {snes2.apu.portsOut[1]:02X}] ipl={snes2.apu.spc.iplEnabled}"

  # Coarse interleave stress: CPU spins CMP $2140 while APU ticks rarely
  echo "\n=== experiment: simulate coarse interleave (150 CPU / 2 APU) from forced mismatch ==="
  let snes3 = newSnesBus(rom)
  var c3 = snes3.resetCpu()
  deserializeState(extracted.get, snes3, c3)
  # Put CPU back at AB87 loop with A=$1B, ports mismatched
  c3.pc = 0xAB87
  c3.pbr = 0xC0
  c3.a = (c3.a and 0xFF00) or 0x1B  # low byte $1B, 8-bit mode for CMP
  # Ensure m=1 (8-bit A) for the wait loop
  c3.p = c3.p or 0x20  # set M
  snes3.apu.portsIn[0] = 0x1B
  snes3.apu.portsOut[0] = 0x00  # no echo yet
  var matched = false
  for line in 0 ..< 262*60:  # 60 frames
    for i in 0 ..< 150:
      c3.step(snes3.bus)
    for k in 0 ..< 2:
      discard snes3.tickApu()
    if snes3.apu.portsOut[0] == 0x1B:
      echo &"  echo matched after {line} lines; CPU={c3.pbr:02X}:{c3.pc:04X} SPC={snes3.apu.spc.pc:04X}"
      matched = true
      break
    if line mod 1000 == 0:
      echo &"  line={line} CPU={c3.pbr:02X}:{c3.pc:04X} SPC={snes3.apu.spc.pc:04X} out0={snes3.apu.portsOut[0]:02X}"
  if not matched:
    echo &"  never matched in 60 frames; CPU={c3.pbr:02X}:{c3.pc:04X} SPC={snes3.apu.spc.pc:04X} out0={snes3.apu.portsOut[0]:02X}"

  # Fine interleave: 1 CPU : many APU cycles (catch-up style)
  echo "\n=== experiment: 1 CPU instr then 20 APU samples (catch-up style) ==="
  let snes4 = newSnesBus(rom)
  var c4 = snes4.resetCpu()
  deserializeState(extracted.get, snes4, c4)
  c4.pc = 0xAB87
  c4.pbr = 0xC0
  c4.a = (c4.a and 0xFF00) or 0x1B
  c4.p = c4.p or 0x20
  snes4.apu.portsIn[0] = 0x1B
  snes4.apu.portsOut[0] = 0x00
  matched = false
  for i in 0 ..< 50_000:
    c4.step(snes4.bus)
    for k in 0 ..< 20:
      discard snes4.tickApu()
    if snes4.apu.portsOut[0] == 0x1B:
      echo &"  matched after {i} CPU steps; CPU={c4.pbr:02X}:{c4.pc:04X} SPC={snes4.apu.spc.pc:04X}"
      matched = true
      break
  if not matched:
    echo &"  never matched; CPU={c4.pbr:02X}:{c4.pc:04X} SPC={snes4.apu.spc.pc:04X} out0={snes4.apu.portsOut[0]:02X}"

when isMainModule:
  main()
