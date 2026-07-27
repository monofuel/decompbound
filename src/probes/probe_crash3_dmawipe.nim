## Capture DMA channel + job queue at the moment $0020 is wiped.

import
  std/[options, strformat],
  pixie,
  ../decompbound/[cpu, png_state, policy, ppu, replay, save_state, snesbus]

const
  Align = 4500
  RomPath = "bin/Earthbound (U) [!].smc"
  PngNear6 = "/home/monofuel/Pictures/Screenshots/earthbound_20260726-212944.png"
  SessionTas = "bin/sessions/20260726-212828/20260726-212832.tas"

proc loadRom(): seq[uint8] =
  ## ROM without header.
  var d = cast[seq[uint8]](readFile(RomPath))
  if d.len mod 1024 == 512:
    d = d[512 .. ^1]
  d

proc w8(s: SnesBus, o: int): uint8 =
  ## WRAM byte.
  s.bus.mem[0x7E0000 + o]

proc w16(s: SnesBus, o: int): uint16 =
  ## WRAM word.
  w8(s, o).uint16 or (w8(s, o + 1).uint16 shl 8)

proc dumpJobs(snes: SnesBus) =
  ## Print queue pointers and first jobs.
  echo &"  $00={w8(snes,0):02X} $01={w8(snes,1):02X}"
  for j in 0 .. 3:
    let b = 0x400 + j * 8
    echo &"  job{j}: type={w8(snes,b):02X} size={w8(snes,b+2):02X}{w8(snes,b+1):02X} " &
      &"A1={w8(snes,b+5):02X}:{w8(snes,b+4):02X}{w8(snes,b+3):02X} " &
      &"vm={w8(snes,b+7):02X}{w8(snes,b+6):02X}"

proc dumpCh0(snes: SnesBus) =
  ## Print DMA channel 0 regs.
  let dmap = snes.dmaRegs[0]
  echo &"  ch0 DMAP={dmap:02X} toA={(dmap and 0x80) != 0} BBAD={snes.dmaRegs[1]:02X} " &
    &"A1={snes.dmaRegs[4]:02X}:{snes.dmaRegs[3]:02X}{snes.dmaRegs[2]:02X} " &
    &"DAS={snes.dmaRegs[6]:02X}{snes.dmaRegs[5]:02X}"

proc main() =
  ## Step to derail frame and log wipe cause.
  let st = extractState(cast[seq[uint8]](readFile(PngNear6)))
  let (_, deltas) = parseReplay(SessionTas)
  let snes = newSnesBus(loadRom())
  var c = snes.resetCpu()
  deserializeState(st.get, snes, c)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  for f in 0 .. 52:
    snes.joy1 = joyAtFrame(deltas, Align + f)
    if f < 52:
      policy.stepOneFrame(snes, c, img)
      continue
    var l = 0
    while l < 262:
      if l == 224 and (snes.nmitimen and 0x80) != 0:
        c.nmiPending = true
      for i in 0 ..< policy.InstrPerLine:
        let pc0 = c.pc
        let pbr0 = c.pbr
        let p20 = w16(snes, 0x20)
        if pbr0 == 0xC0 and pc0 == 0x826F:
          echo &"BEFORE STY 420B: $0020={p20:04X} X={c.x:04X}"
          dumpJobs(snes)
          dumpCh0(snes)
        c.step(snes.bus)
        let p20b = w16(snes, 0x20)
        if p20b != p20:
          echo &"WIPE $0020 {p20:04X}->{p20b:04X} after {pbr0:02X}:{pc0:04X} now {c.pbr:02X}:{c.pc:04X}"
          echo &"  A={c.a:04X} X={c.x:04X} Y={c.y:04X} S={c.s:04X} D={c.d:04X}"
          dumpJobs(snes)
          dumpCh0(snes)
          echo &"  dmaStorm={snes.dmaStorm} dmaTransfers={snes.dmaTransfers}"
          # sample a few low WRAM bytes
          echo &"  $0000..0F: ",
            &"{w8(snes,0):02X}{w8(snes,1):02X}{w8(snes,2):02X}{w8(snes,3):02X} " &
            &"{w8(snes,0x20):02X}{w8(snes,0x21):02X}"
          quit(0)
      if l < 224:
        snes.runHdma()
      for k in 0 .. 1:
        discard snes.tickApu()
      inc l
      if l >= 262:
        snes.initHdma()
        break
  echo "no wipe seen"

when isMainModule:
  main()
