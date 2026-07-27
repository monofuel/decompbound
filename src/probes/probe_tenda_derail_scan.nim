## Per-frame derail scan of session B TAS (and optional A).
import
  std/[os, strformat, strutils],
  pixie,
  ../decompbound/[cpu, policy, ppu, replay, save_state, snesbus, apu]

const
  RomPath = "bin/Earthbound (U) [!].smc"
  Cases = [
    "bin/sessions/20260726-202718/20260726-202722.tas",
    "bin/sessions/20260726-202440/20260726-202452.tas",
  ]

proc badPc(pbr: uint8, pc: uint16): bool =
  ## Same as test_apu_handshake_derail.
  let bank = pbr.int
  if bank >= 0xC0: return false
  if bank >= 0x40 and bank <= 0x7D: return false
  if (bank <= 0x3F) or (bank >= 0x80 and bank <= 0xBF): return pc < 0x8000
  if bank == 0x7E or bank == 0x7F: return false
  true

proc isBrkSink(pbr: uint8, pc: uint16): bool =
  pbr == 0 and pc == 0x5FFF

proc main() =
  var rom = cast[seq[uint8]](readFile(RomPath))
  if rom.len mod 1024 == 512: rom = rom[512..^1]
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  for tasPath in Cases:
    if not fileExists(tasPath):
      echo "skip missing ", tasPath
      continue
    let (hdr, deltas) = parseReplay(tasPath)
    if not fileExists(hdr.startStateRef):
      echo "skip no state ", hdr.startStateRef
      continue
    echo "==== ", tasPath, " ===="
    let snes = newSnesBus(rom)
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(hdr.startStateRef)), snes, c)
    let lastF = (if deltas.len > 0: deltas[^1].frame else: 0) + 300
    var firstBad = -1
    var firstBrk = -1
    type Snap = tuple[f: int, pbr: uint8, pc: uint16, s: uint16, pin0, pout0: uint8, spc: uint16]
    var prev: Snap = (0, c.pbr, c.pc, c.s, snes.apu.portsIn[0], snes.apu.portsOut[0], snes.apu.spc.pc)
    snes.recordMmioTrace = true
    for f in 0 .. lastF:
      snes.joy1 = joyAtFrame(deltas, f)
      snes.mmioReads.setLen(0)
      # Detect mid-frame: step manually like test, check each instr? expensive.
      # Check at frame boundaries first; if needed tighten.
      policy.stepOneFrame(snes, c, img)
      var polls = 0
      for a in snes.mmioReads:
        if a >= 0x2140 and a <= 0x2143: inc polls
      if badPc(c.pbr, c.pc) and firstBad < 0:
        firstBad = f
        echo &"  FIRST BAD f={f} cpu={c.pbr:02X}:{c.pc:04X} S={c.s:04X} " &
          &"prev={prev.pbr:02X}:{prev.pc:04X} polls={polls} " &
          &"pin=[{snes.apu.portsIn[0]:02X}{snes.apu.portsIn[1]:02X}{snes.apu.portsIn[2]:02X}{snes.apu.portsIn[3]:02X}] " &
          &"pout=[{snes.apu.portsOut[0]:02X}{snes.apu.portsOut[1]:02X}{snes.apu.portsOut[2]:02X}{snes.apu.portsOut[3]:02X}]"
      if isBrkSink(c.pbr, c.pc) and firstBrk < 0:
        firstBrk = f
        echo &"  FIRST BRK-SINK f={f} S={c.s:04X} prev={prev.pbr:02X}:{prev.pc:04X}"
      if f mod 500 == 0 or polls >= 100:
        echo &"  f={f:5d} cpu={c.pbr:02X}:{c.pc:04X} polls={polls} " &
          &"pin0={snes.apu.portsIn[0]:02X} pout0={snes.apu.portsOut[0]:02X} spc={snes.apu.spc.pc:04X}"
      prev = (f, c.pbr, c.pc, c.s, snes.apu.portsIn[0], snes.apu.portsOut[0], snes.apu.spc.pc)
    echo &"  done lastF={lastF} firstBad={firstBad} firstBrk={firstBrk} final={c.pbr:02X}:{c.pc:04X}"

main()
