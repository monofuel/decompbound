## Dump WRAM $0020 NMI indirect pointer from crash3 F12s + live trail.

import
  std/[options, strformat],
  pixie,
  ../decompbound/[cpu, png_state, policy, ppu, replay, save_state, snesbus]

const
  RomPath = "bin/Earthbound (U) [!].smc"
  SessionTas = "bin/sessions/20260726-212828/20260726-212832.tas"
  Align = 4500

proc loadRom(): seq[uint8] =
  ## ROM without header.
  var d = cast[seq[uint8]](readFile(RomPath))
  if d.len mod 1024 == 512:
    d = d[512 .. ^1]
  d

proc w16(snes: SnesBus, off: int): uint16 =
  ## LE word in WRAM.
  snes.bus.mem[0x7E0000 + off].uint16 or
    (snes.bus.mem[0x7E0000 + off + 1].uint16 shl 8)

proc dumpPng(path, label: string) =
  ## Print CPU + $0020 from an F12.
  let st = extractState(cast[seq[uint8]](readFile(path)))
  doAssert st.isSome
  let snes = newSnesBus(loadRom())
  var c = snes.resetCpu()
  deserializeState(st.get, snes, c)
  echo &"{label}: CPU {c.pbr:02X}:{c.pc:04X} S={c.s:04X} " &
    &"$0020={w16(snes,0x20):04X} $0022={w16(snes,0x22):04X} " &
    &"$00CA={snes.bus.mem[0x7E00CA]:02X} $00CB={snes.bus.mem[0x7E00CB]:02X}"

proc main() =
  ## Dump pointers then watch $0020 through ALIGN4500 derail.
  dumpPng("/home/monofuel/Pictures/Screenshots/earthbound_20260726-212924.png", "NEAR20")
  dumpPng("/home/monofuel/Pictures/Screenshots/earthbound_20260726-212944.png", "NEAR6")
  dumpPng("/home/monofuel/Pictures/Screenshots/earthbound_20260726-212954.png", "CRASH")

  let st = extractState(cast[seq[uint8]](readFile(
    "/home/monofuel/Pictures/Screenshots/earthbound_20260726-212944.png")))
  let (_, deltas) = parseReplay(SessionTas)
  let snes = newSnesBus(loadRom())
  var c = snes.resetCpu()
  deserializeState(st.get, snes, c)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  var prev20 = w16(snes, 0x20)
  echo &"ALIGN4500 start $0020={prev20:04X}"
  for f in 0 .. 60:
    snes.joy1 = joyAtFrame(deltas, Align + f)
    # instr-level only last frames
    if f < 48:
      policy.stepOneFrame(snes, c, img)
    else:
      var l = 0
      while l < 262:
        if l == 224 and (snes.nmitimen and 0x80) != 0:
          c.nmiPending = true
        for i in 0 ..< policy.InstrPerLine:
          let pc = c.pc
          let pbr = c.pbr
          # before step: detect JSR $8518 / JMP ($20)
          if pbr == 0xC0 and pc == 0x8365:
            echo &"  f={f} BEFORE JSR 8518 ptr={w16(snes,0x20):04X} " &
              &"S={c.s:04X} A={c.a:04X} X={c.x:04X} Y={c.y:04X}"
          if pbr == 0xC0 and pc == 0x8518:
            echo &"  f={f} BEFORE JMP (0020) ptr={w16(snes,0x20):04X} " &
              &"S={c.s:04X}"
          c.step(snes.bus)
          let now = w16(snes, 0x20)
          if now != prev20:
            echo &"  f={f} $0020 CHANGE {prev20:04X}->{now:04X} " &
              &"at PC={c.pbr:02X}:{c.pc:04X} S={c.s:04X}"
            prev20 = now
          if c.pbr == 0 and c.pc == 0x5FFF:
            echo &"  f={f} BRK_SINK S={c.s:04X} $0020={w16(snes,0x20):04X}"
            echo "done"
            return
        if l < 224:
          snes.runHdma()
        for k in 0 ..< 2:
          discard snes.tickApu()
        inc l
        if l >= 262:
          snes.initHdma()
          break
    let now = w16(snes, 0x20)
    if now != prev20:
      echo &"f={f} $0020 {prev20:04X}->{now:04X} cpu={c.pbr:02X}:{c.pc:04X}"
      prev20 = now
    if f mod 10 == 0:
      echo &"f={f} $0020={now:04X} cpu={c.pbr:02X}:{c.pc:04X} S={c.s:04X} nmi={snes.nmitimen:02X}"

when isMainModule:
  main()
