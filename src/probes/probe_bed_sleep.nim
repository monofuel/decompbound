## Attempt bed sleep from pre_knock_bed; report window/flag changes + knock grade.
import
  std/[os, strformat, strutils, tables],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, policy],
  ../tools/[touch_grass, story_percents]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Pre = "bin/states/llm/pre_knock_bed.state"
  FlagLo = 0x9800
  FlagHi = 0x9BFF

proc r8(snes: SnesBus, off: int): int =
  touch_grass.readU8(snes, off)

proc snapFlags(snes: SnesBus): Table[int, int] =
  result = initTable[int, int]()
  for off in FlagLo .. FlagHi:
    result[off] = r8(snes, off)

proc main() =
  ## From pre_knock bed, try sleep inputs; dump flag/window changes.
  if not fileExists(Rom) or not fileExists(Pre):
    echo "SKIP"; quit(0)
  let snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Pre)), snes, cpu)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let base = snapFlags(snes)
  let bedX = 0x1FB8
  let bedY = 0x0450
  echo "START knock=", pokeyKnockPercent(snes), " tg=", touchGrassPercent(snes),
    " win0=", r8(snes, 0x8650).toHex(2), " win1=", r8(snes, 0x8654).toHex(2),
    " 9885=", r8(snes, 0x9885).toHex(2)
  var phase = 0
  var sawWin = false
  var text = ""
  for f in 0 ..< 3600:
    let pidx = PlayerSlot * SlotIndexStride
    let px = readU16(snes, WorldXBase + pidx)
    let py = readU16(snes, WorldYBase + pidx)
    # walk to bed first
    var joy: uint16 = 0
    if phase == 0:
      let dx = bedX - px
      let dy = bedY - py
      if abs(dx) + abs(dy) > 8:
        if abs(dx) > abs(dy):
          joy = if dx > 0: 0x0100'u16 else: 0x0200'u16  # R/L
        else:
          joy = if dy > 0: 0x0400'u16 else: 0x0800'u16  # D/U
      else:
        phase = 1
        echo "AT_BED f=", f, " pos=(", px.toHex(4), ",", py.toHex(4), ")"
    elif phase == 1:
      # Face up and pulse A every 16 frames; B occasionally to close menus
      if (f mod 16) < 6: joy = 0x0800'u16  # Up
      elif (f mod 16) < 10: joy = 0x0080'u16  # A
      elif (f mod 64) == 0: joy = 0x0040'u16  # B
    snes.joy1 = joy
    policy.stepOneFrame(snes, cpu, img)
    let w0 = r8(snes, 0x8650)
    let w1 = r8(snes, 0x8654)
    if w0 != 0xFF or w1 != 0xFF:
      if not sawWin:
        sawWin = true
        text = policy.getDialogueText(snes).strip().replace("\n", " ")
        echo "WINDOW f=", f, " w0=", w0.toHex(2), " w1=", w1.toHex(2),
          " text=[", text[0 ..< min(100, text.len)], "]"
      # mash A to advance
      snes.joy1 = 0x0080
      policy.stepOneFrame(snes, cpu, img)
    if f mod 600 == 0 and f > 0:
      echo "TICK f=", f, " knock=", pokeyKnockPercent(snes), " phase=", phase,
        " pos=(", readU16(snes, WorldXBase + pidx).toHex(4), ",",
        readU16(snes, WorldYBase + pidx).toHex(4), ")"
  let after = snapFlags(snes)
  var changes: seq[string]
  for off, av in base:
    let bv = after[off]
    if av != bv:
      changes.add fmt"7E:{off:04X} {av:02X}->{bv:02X}"
  echo "FLAG_CHANGES=", changes.len
  for i, c in changes:
    if i >= 40: break
    echo c
  echo "FINAL knock=", pokeyKnockPercent(snes), " saw_window=", sawWin,
    " text_len=", text.len

when isMainModule: main()
