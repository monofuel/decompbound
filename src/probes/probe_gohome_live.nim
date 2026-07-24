## Why goHome fails after live pokey100 vs pokey_done.
import std/[os, strformat, strutils], pixie
import ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy]
import ../tools/[touch_grass, story_percents, scene, llm_mock_policies]
const Rom = "bin/Earthbound (U) [!].smc"

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

proc setup(snes: SnesBus; img: Image): tuple[L: lua53.PState, ctx: policy.PolicyContext, skills: string] =
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox(); policy.setupPolicyApi(L, ctx)
  L.pushcfunction(sceneLua); L.setglobal("scene".cstring)
  L.pushcfunction(landmarkLua); L.setglobal("landmarkTarget".cstring)
  let skills = EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & AdvanceDialogueSkillLua & "\n" &
    NavSkillLua & "\n" & FollowTrailSkillLua & "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua & "\n" & WinBattleSkillLua
  loadChunk(L, skills, "sk")
  result = (L, ctx, skills)

proc runOutdoorToPokey(): tuple[snes: SnesBus, c: Cpu] =
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile("bin/states/llm/onett_start.state")), snes, c)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  var t = setup(snes, img)
  loadChunk(t.L, AgentOutdoorPolicy, "out")
  for f in 1 .. 5000:
    t.ctx.frameCount = f
    discard policy.runPolicyFrame(t.L, t.ctx)
    snes.joy1 = t.ctx.joy1
    policy.stepOneFrame(snes, c, img)
    if pokeyPercent(snes) >= 100:
      for e in 1 .. 150:
        t.ctx.frameCount = f+e
        discard policy.runPolicyFrame(t.L, t.ctx)
        snes.joy1 = t.ctx.joy1
        policy.stepOneFrame(snes, c, img)
      break
  result = (snes, c)

proc dumpScene(snes: SnesBus; tag: string) =
  let j = scene.sceneJson(snes)
  echo tag, " ", j[0 ..< min(500, j.len)]

proc main() =
  # 1) LIVE after outdoor: frame-by-frame goHome return + joy + pos
  block:
    var t = runOutdoorToPokey()
    let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
    var s = setup(t.snes, img)
    # instrument goHome
    loadChunk(s.L, """
local _gh_n = 0
local _orig = goHome
function goHome()
  _gh_n = _gh_n + 1
  local r = _orig and _orig()
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  if _gh_n <= 20 or _gh_n % 50 == 0 then
    print(string.format("goHome n=%d r=%s pos=%x,%x", _gh_n, tostring(r), px, py))
  end
  return r
end
local _fr_n = 0
local _ofr = followRoute
function followRoute(name)
  local r = _ofr(name)
  _fr_n = _fr_n + 1
  if _fr_n <= 15 or _fr_n % 100 == 0 then
    print(string.format("followRoute(%s)=%s n=%d", tostring(name), tostring(r), _fr_n))
  end
  return r
end
""", "wrap")
    loadChunk(s.L, AgentHomePolicy, "home")
    dumpScene(t.snes, "LIVE_start")
    let i = PlayerSlot * SlotIndexStride
    var maxK = pokeyKnockPercent(t.snes)
    var lastPos = ""
    for f in 1 .. 3000:
      s.ctx.frameCount = f
      discard policy.runPolicyFrame(s.L, s.ctx)
      t.snes.joy1 = s.ctx.joy1
      policy.stepOneFrame(t.snes, t.c, img)
      let px = readU16(t.snes, WorldXBase+i)
      let py = readU16(t.snes, WorldYBase+i)
      let k = pokeyKnockPercent(t.snes)
      if k > maxK: maxK = k
      if f <= 10 or f mod 250 == 0:
        echo fmt"f={f} joy=0x{s.ctx.joy1:04X} pos=(0x{px:04X},0x{py:04X}) knock={k} maxK={maxK}"
    echo "LIVE_home FINAL maxK=", maxK, " pos=", fmt"(0x{readU16(t.snes,WorldXBase+i):04X},0x{readU16(t.snes,WorldYBase+i):04X})"

  # 2) Fresh Lua from pokey_done
  block:
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile("bin/states/llm/pokey_done.state")), snes, c)
    let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
    var s = setup(snes, img)
    loadChunk(s.L, """
local _fr_n = 0
local _ofr = followRoute
function followRoute(name)
  local r = _ofr(name)
  _fr_n = _fr_n + 1
  if _fr_n <= 10 or _fr_n % 100 == 0 then
    print(string.format("FIX followRoute(%s)=%s n=%d", tostring(name), tostring(r), _fr_n))
  end
  return r
end
""", "wrap")
    loadChunk(s.L, AgentHomePolicy, "home")
    dumpScene(snes, "FIX_start")
    let i = PlayerSlot * SlotIndexStride
    var maxK = pokeyKnockPercent(snes)
    for f in 1 .. 3000:
      s.ctx.frameCount = f
      discard policy.runPolicyFrame(s.L, s.ctx)
      snes.joy1 = s.ctx.joy1
      policy.stepOneFrame(snes, c, img)
      let k = pokeyKnockPercent(snes)
      if k > maxK: maxK = k
      if f <= 10 or f mod 250 == 0:
        let px = readU16(snes, WorldXBase+i)
        let py = readU16(snes, WorldYBase+i)
        echo fmt"FIX f={f} joy=0x{s.ctx.joy1:04X} pos=(0x{px:04X},0x{py:04X}) knock={k} maxK={maxK}"
    echo "FIX_home FINAL maxK=", maxK

  # 3) LIVE but teleport to pokey_free pos? Or use pokey_free as continuous proxy
  if fileExists("bin/states/llm/pokey_free.state"):
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile("bin/states/llm/pokey_free.state")), snes, c)
    let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
    var s = setup(snes, img)
    loadChunk(s.L, AgentHomePolicy, "home")
    let i = PlayerSlot * SlotIndexStride
    echo fmt"pokey_free start pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) win1={readU8(snes,0x8654):#04x}"
    var maxK = pokeyKnockPercent(snes)
    for f in 1 .. 5000:
      s.ctx.frameCount = f
      discard policy.runPolicyFrame(s.L, s.ctx)
      snes.joy1 = s.ctx.joy1
      policy.stepOneFrame(snes, c, img)
      let k = pokeyKnockPercent(snes)
      if k > maxK: maxK = k
      if maxK >= 80: break
    echo "pokey_free AgentHome maxK=", maxK, " frames=", s.ctx.frameCount

  echo "OK probe_gohome_live"
main()
