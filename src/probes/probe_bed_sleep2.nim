## Bed sleep: try Yes/No prompt handling (A, then Left+A, Down+A) after window.
import
  std/[os, strformat, strutils, tables],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, policy],
  ../tools/[touch_grass, story_percents]

proc r8(snes: SnesBus, off: int): int = touch_grass.readU8(snes, off)

proc main() =
  ## Exhaust bed-prompt sequences from pre_knock_bed / home_natural_entry.
  let rom = "bin/Earthbound (U) [!].smc"
  for pre in ["bin/states/llm/pre_knock_bed.state", "bin/states/llm/home_natural_entry.state",
              "bin/states/llm/in_bedroom.state"]:
    if not fileExists(pre): continue
    let snes = newSnesBus(policy.readRomFile(rom))
    var cpu = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(pre)), snes, cpu)
    let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
    echo "==== ", pre, " knock=", pokeyKnockPercent(snes), " 9885=", r8(snes,0x9885).toHex(2),
      " 9A0F=", r8(snes,0x9A0F).toHex(2), " 9A10=", r8(snes,0x9A10).toHex(2)
    var mode = 0  # 0 walk, 1 open prompt, 2 answer
    var ansPhase = 0
    for f in 0 ..< 2400:
      let pidx = PlayerSlot * SlotIndexStride
      let px = readU16(snes, WorldXBase + pidx)
      let py = readU16(snes, WorldYBase + pidx)
      var joy: uint16 = 0
      let w0 = r8(snes, 0x8650)
      let w1 = r8(snes, 0x8654)
      let open = w0 != 0xFF or w1 != 0xFF
      if not open and mode < 2:
        # approach bed and face/A
        let dx = 0x1FB8 - px
        let dy = 0x0450 - py
        if abs(dx) + abs(dy) > 6:
          if abs(dx) >= abs(dy): joy = if dx > 0: 0x0100 else: 0x0200
          else: joy = if dy > 0: 0x0400 else: 0x0800
        else:
          if (f mod 20) < 8: joy = 0x0800
          elif (f mod 20) < 14: joy = 0x0080
      else:
        mode = 2
        # Answer prompt cycles: A spam, Left+A, Right+A, Up+A, Down+A, Start
        let cyc = (f div 30) mod 6
        case cyc
        of 0:
          if (f mod 8) < 3: joy = 0x0080
        of 1:
          joy = if (f mod 8) < 4: 0x0200 else: 0x0080  # Left then A
        of 2:
          joy = if (f mod 8) < 4: 0x0100 else: 0x0080
        of 3:
          joy = if (f mod 8) < 4: 0x0800 else: 0x0080
        of 4:
          joy = if (f mod 8) < 4: 0x0400 else: 0x0080
        else:
          joy = 0x1000  # Start
        if open and ansPhase == 0:
          ansPhase = 1
          let t = policy.getDialogueText(snes).strip().replace("\n", " ")
          let t2 = policy.getScreenText(snes).strip().replace("\n", " ")
          echo "PROMPT f=", f, " w0=", w0.toHex(2), " w1=", w1.toHex(2),
            " dlg=[", t[0..min(80,t.len-1)], "] scr=[", t2[0..min(80,t2.len-1)], "]"
      snes.joy1 = joy
      policy.stepOneFrame(snes, cpu, img)
      # Detect room/pos jump (sleep warp)
      let px2 = readU16(snes, WorldXBase + pidx)
      let py2 = readU16(snes, WorldYBase + pidx)
      if abs(px2 - px) + abs(py2 - py) > 0x80:
        echo "TELEPORT f=", f, " (", px.toHex(4), ",", py.toHex(4), ")->(",
          px2.toHex(4), ",", py2.toHex(4), ") knock=", pokeyKnockPercent(snes),
          " room=", currentRoomLabel(snes)
      if f mod 800 == 799:
        echo "TICK f=", f, " knock=", pokeyKnockPercent(snes), " room=", currentRoomLabel(snes),
          " open=", open, " 9A0F=", r8(snes,0x9A0F).toHex(2)
    echo "FINAL knock=", pokeyKnockPercent(snes), " room=", currentRoomLabel(snes),
      " 9A0F=", r8(snes,0x9A0F).toHex(2), " 9A10=", r8(snes,0x9A10).toHex(2)

when isMainModule: main()
