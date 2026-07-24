## Smoke test: can the emulator ADVANCE a loaded healthy mid-battle state?
## Load battle_menu_healthy.state, mash A (select Bash / advance), log battle
## state evolution. If the turn executes / enemy HP drops / victory fires, the
## battle engine runs from a loaded state (winBattle is developable even though
## headless ENTRY aborts). Untracked dig tool.
import
  std/[os, strformat, strutils],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, policy],
  ./touch_grass

const
  Rom = "bin/Earthbound (U) [!].smc"
  State = "bin/states/battle_menu_healthy.state"

proc main() =
  let maxF = if paramCount() >= 1: parseInt(paramStr(1)) else: 1200
  let rom = policy.readRomFile(Rom)
  let snes = newSnesBus(rom)
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(State)), snes, c)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)

  # Baseline WRAM to measure whether ANYTHING changes (spin-hung vs looping-gated).
  var wram0: array[0x2000, int]
  for i in 0 ..< 0x2000: wram0[i] = readU8(snes, i)

  var lastTxt = ""
  for f in 0 ..< maxF:
    # Press A every 12 frames to select Bash / advance battle text.
    snes.joy1 = if (f mod 12) < 3: 0x0080'u16 else: 0'u16
    policy.stepOneFrame(snes, c, img)
    if f == 200:
      var changed = 0
      for i in 0 ..< 0x2000:
        if readU8(snes, i) != wram0[i]: inc changed
      echo &"[wram $0000-$2000 changed after 200f: {changed} bytes]  cpu.pc=${c.pbr:02X}:{c.pc:04X} A={c.a:04X}"
    let mode = snes.ppuRegs[0x05] and 0x7
    let b4dba = readU16(snes, 0x4DBA)
    let p98a5 = readU16(snes, 0x98A5)
    let txt = policy.getDialogueText(snes).strip()
    if f mod 60 == 0 or txt != lastTxt:
      let ts = if txt.len > 46: txt[0..45] else: txt
      echo &"f={f} mode={mode} 4DBA={b4dba:04X} 98A5={p98a5:04X} txt=[{ts}]"
      lastTxt = txt
    if c.stopped:
      echo &"f={f} CPU STOPPED"; break
  img.writeFile("bin/battle_advance_end.png")
  # Final party/enemy HP snapshot
  echo "-- final battler HP --"
  for p in 0 ..< 6:
    let bptr = readU16(snes, 0x4DC8 + p*2)
    if bptr == 0 or bptr == 0xFFFF: continue
    echo &"  battler {p}: ptr=${bptr:04X} HP={readU16(snes, bptr + 0x0A)}"

when isMainModule:
  main()
