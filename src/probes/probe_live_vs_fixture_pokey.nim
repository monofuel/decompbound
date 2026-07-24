## Diff WRAM after live AgentOutdoor pokey100 vs pokey_done fixture.
## Finds control-lock / dialogue / NPC state that blocks goHome.
import std/[os, strformat, strutils, tables], pixie
import ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy]
import ../tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  LiveStart = "bin/states/llm/onett_start.state"
  Fixture = "bin/states/llm/pokey_done.state"

proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc sceneLua(L: lua53.PState): cint {.cdecl.} =
  L.pushstring(scene.sceneJson(policy.getPolicyCtx(L).snes).cstring); 1
proc landmarkLua(L: lua53.PState): cint {.cdecl.} =
  let t = scene.landmarkTarget(policy.getPolicyCtx(L).snes, $L.toString(1))
  if not t.found: L.pushnil(); return 1
  L.pushinteger(t.x); L.pushinteger(t.y); 2

proc dumpKey(snes: SnesBus; tag: string) =
  let i = PlayerSlot * SlotIndexStride
  echo fmt"{tag}:"
  echo fmt"  pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) " &
    fmt"pokey={pokeyPercent(snes)} knock={pokeyKnockPercent(snes)} room={currentRoomLabel(snes)}"
  echo fmt"  win0={readU8(snes,0x8650):#04x} win1={readU8(snes,0x8654):#04x} focus={readU8(snes,0x8958):#04x}"
  echo fmt"  arm$9885={readU8(snes,0x9885):#04x} $9887={readU8(snes,0x9887):#04x} $99F2={readU8(snes,0x99F2):#04x}"
  # Common control / overworld mode candidates
  for off in [0x5D98, 0x5D9A, 0x5DA0, 0x9670, 0x9671, 0x9870, 0x9871, 0x4A00, 0x4A01, 0x4DBA]:
    echo fmt"  ${off:04X}={readU8(snes,off):#04x}"
  # Player entity state bytes near slot
  echo fmt"  entity_dir? $0BE0+={readU8(snes,0x0BE0):#04x} $0C00={readU8(snes,0x0C00):#04x}"
  echo "  scene_head=", scene.sceneJson(snes)[0 ..< min(400, scene.sceneJson(snes).len)]

proc runToPokey(): SnesBus =
  result = newSnesBus(policy.readRomFile(Rom))
  var c = result.resetCpu()
  deserializeState(cast[seq[byte]](readFile(LiveStart)), result, c)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: result, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox(); policy.setupPolicyApi(L, ctx)
  L.pushcfunction(sceneLua); L.setglobal("scene".cstring)
  L.pushcfunction(landmarkLua); L.setglobal("landmarkTarget".cstring)
  let skills = EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & AdvanceDialogueSkillLua & "\n" &
    NavSkillLua & "\n" & FollowTrailSkillLua & "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua & "\n" & WinBattleSkillLua
  loadChunk(L, skills, "sk")
  loadChunk(L, AgentOutdoorPolicy, "out")
  for f in 1 .. 5000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    result.joy1 = ctx.joy1
    policy.stepOneFrame(result, c, img)
    if pokeyPercent(result) >= 100:
      # drain dialogue a bit
      for _ in 1 .. 120:
        ctx.frameCount = f
        discard policy.runPolicyFrame(L, ctx)
        result.joy1 = ctx.joy1
        policy.stepOneFrame(result, c, img)
        if readU8(result, 0x8650) == 0xFF and readU8(result, 0x8654) == 0xFF:
          break
      break

proc main() =
  doAssert fileExists(Rom) and fileExists(Fixture) and fileExists(LiveStart)
  let live = runToPokey()
  dumpKey(live, "LIVE")
  let fix = newSnesBus(policy.readRomFile(Rom))
  var fc = fix.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Fixture)), fix, fc)
  dumpKey(fix, "FIXTURE")

  # Diff high-interest WRAM regions
  let ranges = [
    (0x0B00, 0x0D00),   # entity coords / state
    (0x4D00, 0x4E00),   # battle / mode
    (0x5D00, 0x5E00),   # control candidates
    (0x8600, 0x8700),   # windows
    (0x8900, 0x8A00),   # focus
    (0x9600, 0x9700),
    (0x9800, 0x9A00),   # story / party
    (0x9A00, 0x9C00),   # event flags
  ]
  var diffs = 0
  for (a, b) in ranges:
    for off in a ..< b:
      let lv = live.bus.mem[0x7E0000 + off]
      let fv = fix.bus.mem[0x7E0000 + off]
      if lv != fv:
        diffs.inc
        if diffs <= 80:
          echo fmt"DIFF ${off:04X} live={lv:#04x} fix={fv:#04x}"
  echo "total_diffs_in_ranges=", diffs
  echo "OK probe_live_vs_fixture_pokey"

main()
