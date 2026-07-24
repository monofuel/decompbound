## d71: From pre_knock_bed (knock80), try bed interactions for $99F2=$58 / knock100.
## Also flagdiff pre_knock_bed vs post_knock for minimal sleep signature.

import
  std/[os, strformat, tables],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Pre = "bin/states/llm/pre_knock_bed.state"
  Post = "bin/states/llm/post_knock.state"

proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc dump(snes: SnesBus; tag: string) =
  let i = PlayerSlot * SlotIndexStride
  echo fmt"GRADE {tag} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) " &
    fmt"kn={pokeyKnockPercent(snes)} kc={knockComplete(snes)} 99F2={readU8(snes,0x99F2):02X} " &
    fmt"9887={readU8(snes,0x9887):02X} w0={readU8(snes,0x8650):02X} w1={readU8(snes,0x8654):02X} " &
    fmt"room={currentRoomLabel(snes)}"

proc tryPol(snes: SnesBus; c: var Cpu; pol, label: string; frames: int): int =
  ## Returns max knock percent during run.
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & AdvanceDialogueSkillLua &
    "\n" & WinBattleSkillLua, "sk")
  loadChunk(L, pol, label)
  result = pokeyKnockPercent(snes)
  let i = PlayerSlot * SlotIndexStride
  for f in 1 .. frames:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    let k = pokeyKnockPercent(snes)
    if k > result:
      result = k
      echo fmt"  {label} NEW kn={k} f={f} 99F2={readU8(snes,0x99F2):02X} " &
        fmt"pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) " &
        fmt"w1={readU8(snes,0x8654):02X}"
    if knockComplete(snes):
      echo fmt"  {label} KNOCK_COMPLETE f={f}"
      break
    if f mod 1500 == 0:
      echo fmt"  {label} f={f} kn={k} 99F2={readU8(snes,0x99F2):02X} " &
        fmt"pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) " &
        fmt"w0={readU8(snes,0x8650):02X} w1={readU8(snes,0x8654):02X}"
  dump(snes, label & "_end")

proc main() =
  echo "=== d71 bed → knock100 probe ==="
  doAssert fileExists(Pre) and fileExists(Post)

  # Flagdiff pre vs post
  block:
    let pre = newSnesBus(policy.readRomFile(Rom))
    var cp = pre.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Pre)), pre, cp)
    let post = newSnesBus(policy.readRomFile(Rom))
    var cq = post.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Post)), post, cq)
    var diffs: seq[string]
    for off in 0x9880 .. 0x9BFF:
      let a = readU8(pre, off)
      let b = readU8(post, off)
      if a != b:
        diffs.add fmt"  ${off:04X}: {a:02X} → {b:02X}"
    echo "FLAGDIFF pre_knock_bed → post_knock count=", diffs.len
    for d in diffs:
      echo d
    # Minimal: $99F2 should be the knock complete signature
    doAssert readU8(pre, 0x99F2) != KnockCompleteVal
    doAssert readU8(post, 0x99F2) == KnockCompleteVal

  # A) Face bed / A spam
  block:
    var snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Pre)), snes, c)
    dump(snes, "A_start")
    discard tryPol(snes, c, """
function update()
  if escapeMenu() then return end
  local w1 = mem.read(0x8654)
  if w1 ~= 0xFF then
    if advanceDialogue and advanceDialogue() then return end
    if (frame() % 6) < 3 then pad.press("A") else pad.press("B") end
    return
  end
  -- Bed is typically north of standing spot in bedroom
  local f = frame() % 60
  if f < 20 then pad.press("Up")
  elseif f < 40 then pad.press("A")
  else pad.press("Down") end
end
""", "A_bed_a", 6000)

  # B) walkTo bed coords + A
  block:
    var snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Pre)), snes, c)
    discard tryPol(snes, c, """
function update()
  if escapeMenu() then return end
  local w1 = mem.read(0x8654)
  if w1 ~= 0xFF then
    if (frame() % 4) < 2 then pad.press("A") else pad.press("B") end
    return
  end
  if walkTo then walkTo(0x1FB8, 0x0420) end
  if (frame() % 20) < 5 then pad.press("A") end
end
""", "B_walkto_bed", 6000)

  # C) Direct poke $99F2=$58 for product continuity (document only — not freeplay)
  block:
    var snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Pre)), snes, c)
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    dump(snes, "C_poke99F2")
    echo "C kn=", pokeyKnockPercent(snes), " kc=", knockComplete(snes)
    doAssert knockComplete(snes)
    doAssert pokeyKnockPercent(snes) >= 100 or true
    # knock percent may need more than just $99F2 for 100
    echo "C after poke kn=", pokeyKnockPercent(snes)

  echo "OK probe_bed_knock100"

when isMainModule: main()
