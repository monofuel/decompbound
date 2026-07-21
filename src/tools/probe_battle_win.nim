## Referee: win a real fight from battle_menu_healthy.state via BattlePolicy / winBattle.
## Loads the healthy mid-battle fixture, runs the Lua battle policy, reports the
## frame at which the battle is WON (mode leaves 0 / overworld return).
## PASS only with a real win within a few thousand frames + printed evidence.
## Usage: nim r -d:release src/tools/probe_battle_win.nim [max_frames]
## Do not commit ROM/state/screenshots.

import
  std/[os, strformat, strutils],
  pixie,
  ../decompbound/[ppu, snesbus, save_state, lua53, policy],
  ./[touch_grass, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  HealthyState = "bin/states/battle_menu_healthy.state"
  DefaultMaxF = 4000
  ## Healthy A-mash leaves mode 0 around ~1155f; allow headroom.
  WinDeadline = 3000

proc loadChunk(L: lua53.PState, src, label: string) =
  ## Load and run a Lua chunk; raise on error.
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc u8(snes: SnesBus, o: int): int =
  ## WRAM u8 via touch_grass helper.
  readU8(snes, o)

proc u16(snes: SnesBus, o: int): int =
  ## WRAM u16 LE via touch_grass helper.
  readU16(snes, o)

proc partyHpLine(snes: SnesBus): string =
  ## HP from battler pointer table $4DC8.
  var parts: seq[string]
  for i in 0 ..< 6:
    let p = u16(snes, 0x4DC8 + i * 2)
    if p == 0 or p == 0xFFFF:
      continue
    parts.add &"[{i}]@{p:04X} HP={u16(snes, p + 0x0A)}"
  parts.join(" ")

proc main() =
  ## Run BattlePolicy on the healthy fixture; print winning frame + evidence.
  if not fileExists(HealthyState):
    echo "FAIL: missing ", HealthyState
    quit(1)
  let maxF = if paramCount() >= 1: parseInt(paramStr(1)) else: DefaultMaxF
  let snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  deserializeState(cast[seq[byte]](readFile(HealthyState)), snes, cpu)

  echo "=== load ", HealthyState, " ==="
  echo &"  mode={snes.ppuRegs[0x05] and 7} 4DBA={u8(snes, 0x4DBA):02X} " &
    &"inBattle={policy.isInBattle(snes)} 5D60={u16(snes, 0x5D60):04X}"
  echo &"  party {partyHpLine(snes)}"
  let bt0 = policy.getBattleText(snes)
  echo &"  battleText=[{bt0.replace(\"\\n\", \"|\")}]"
  if not policy.isInBattle(snes):
    echo "FAIL: fixture not in active battle (need mode 0 + $4DC8 HP)"
    quit(1)

  let ctx = policy.PolicyContext(
    snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  let skills = EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" &
    WinBattleSkillLua & "\n" & AdvanceDialogueSkillLua
  loadChunk(L, skills, "skills")
  loadChunk(L, BattlePolicy, "battle")

  var winF = -1
  var lastBt = ""
  var evidence: seq[string]
  var sawCmd = false

  for f in 0 ..< maxF:
    ctx.frameCount = f
    let err = policy.runPolicyFrame(L, ctx)
    if err.len > 0 and f mod 200 == 0:
      echo &"ERR f={f}: {err}"
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)

    let fighting = policy.isInBattle(snes)
    let bt = policy.getBattleText(snes)
    let mode = snes.ppuRegs[0x05] and 7
    let low = bt.toLowerAscii()
    if low.contains("bash") or low.contains("goods") or low.contains("shoot") or
        low.contains("defend") or low.contains("psi"):
      sawCmd = true
    if bt != lastBt and bt.len > 0:
      let clip = bt.replace("\n", "|")
      let line = &"f={f} mode={mode} battleText=[{clip}]"
      echo line
      evidence.add line
      lastBt = bt
    elif f mod 120 == 0:
      echo &"f={f} mode={mode} inBattle={fighting} joy=0x{ctx.joy1:04X} " &
        &"5D60={u16(snes, 0x5D60):04X}"

    if not fighting and f > 0:
      winF = f
      let clip = bt.replace("\n", "|")
      echo &"*** BATTLE WON f={f} mode={mode} 5D60={u16(snes, 0x5D60):04X} " &
        &"battleText=[{clip}] ***"
      echo &"  party {partyHpLine(snes)}"
      break

  if winF < 0:
    echo &"FAIL: still in battle after {maxF} frames mode={snes.ppuRegs[0x05] and 7}"
    echo &"  battleText=[{policy.getBattleText(snes).replace(\"\\n\", \"|\")}]"
    quit(1)
  if winF > WinDeadline:
    echo &"FAIL: won at f={winF} but past deadline {WinDeadline}"
    quit(1)
  if not sawCmd:
    echo "FAIL: never observed command-menu battleText (Bash/Goods/…)"
    quit(1)

  echo &"PASS win f={winF} (deadline {WinDeadline}) saw_command_menu={sawCmd}"
  echo &"WIN_FRAME={winF}"
  if evidence.len > 0:
    echo "EVIDENCE (battleText samples):"
    for e in evidence[0 ..< min(12, evidence.len)]:
      echo "  ", e

when isMainModule:
  main()
