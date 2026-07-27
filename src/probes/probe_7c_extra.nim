## Extra hang-state dumps for the $7C spray crash.

import
  std/[options, os, strformat],
  ../decompbound/[cpu, png_state, save_state, snesbus]

const
  RomPath = "bin/Earthbound (U) [!].smc"
  HangPng = "/home/monofuel/Pictures/Screenshots/earthbound_20260726-210013.png"

proc loadRom(): seq[uint8] =
  ## ROM without copier header.
  var d = cast[seq[uint8]](readFile(RomPath))
  if d.len mod 1024 == 512:
    d = d[512 .. ^1]
  d

proc main() =
  ## Dump WRAM pattern, stack, and register exceptions at hang.
  let raw = cast[seq[uint8]](readFile(HangPng))
  let st = extractState(raw)
  doAssert st.isSome
  let snes = newSnesBus(loadRom())
  var c = snes.resetCpu()
  deserializeState(st.get, snes, c)

  proc w(off: int): uint8 =
    snes.bus.mem[0x7E0000 + off]

  echo &"CPU {c.pbr:02X}:{c.pc:04X} A={c.a:04X} X={c.x:04X} Y={c.y:04X} S={c.s:04X} D={c.d:04X} DBR={c.dbr:02X} P={c.p:02X}"
  echo &"$001E (NMI shadow)={w(0x1E):02X} $001F (HDMAEN shadow)={w(0x1F):02X} $000D (INIDISP shadow)={w(0x0D):02X}"
  echo &"$0000={w(0):02X} $0001={w(1):02X}"

  var same7c59 = 0
  var other = 0
  var firstOther = -1
  for i in countup(0, 0x1FFE, 2):
    let lo = w(i)
    let hi = w(i + 1)
    if lo == 0x7C and hi == 0x59:
      inc same7c59
    else:
      inc other
      if firstOther < 0:
        firstOther = i
  echo &"low 8KB words: 7C59={same7c59} other={other} firstOther=${firstOther:04X}"
  if firstOther >= 0:
    echo &"  at firstOther: {w(firstOther):02X}{w(firstOther+1):02X}"

  var runEnd = 0
  for i in countup(0, 0x20000 - 2, 2):
    if w(i) == 0x7C and w(i + 1) == 0x59:
      runEnd = i + 2
    else:
      break
  echo &"contiguous 7C59 from $0000 to ${runEnd:04X} ({runEnd} bytes)"

  echo "stack:"
  for off in -16 .. 16:
    let a = (c.s.int + off) and 0xFFFF
    let mark = if off == 0: '>' else: ' '
    echo &"  {mark}${a:04X}: {w(a):02X}"

  var non7c: seq[string]
  for i in 0 ..< 0x100:
    if snes.ppuRegs[i] != 0x7C:
      non7c.add &"${0x2100 + i:04X}={snes.ppuRegs[i]:02X}"
  echo &"ppuRegs non-7C ({non7c.len}): {non7c[0 ..< min(25, non7c.len)]}"

  non7c.setLen(0)
  for i in 0 ..< 0x80:
    if snes.dmaRegs[i] != 0x7C:
      non7c.add &"${0x4300 + i:04X}={snes.dmaRegs[i]:02X}"
  echo &"dmaRegs non-7C ({non7c.len}): {non7c}"

  # BGMODE etc from hang auto-capture still had TM=01 — may be non-7C
  echo &"BGMODE ppu[5]={snes.ppuRegs[5]:02X} TM={snes.ppuRegs[0x2C]:02X} TS={snes.ppuRegs[0x2D]:02X}"

when isMainModule:
  main()
