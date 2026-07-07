## LLM-writes-Lua policy player for milestone 2c.
## Two-clock loop: fast clock runs sandboxed Lua update() every frame (drives joy1);
## slow clock periodically asks LLM (or mock) for a fresh/updated Lua policy string
## based on a compact state summary, hot-reloads it, keeps running.
## Uses the exact same load->runPolicyFrame->stepOneFrame->joy1 path as llm_play
## (via shared policy module) so LLM-authored strings are proven equivalent.
## LLM call is swappable: default --mock uses a fixed canned policy for headless verify
## (no API key needed); real path uses openai_leap when --no-mock and key present.
## Usage: nix develop -c nim c -r src/tools/llm_ai.nim -- [--frames N] [--llm-interval K] [--png-every M] [--headless] [--mock|--no-mock] [--load-state N | --load-state=N] [--save-srm ...] [rom]
## Default is windowed (GL + windy) so you can watch the LLM play alongside `make play`.
## --headless preserves the old no-window behavior for CI. PNG dumps (when enabled)
## now go to bin/llm_frames/ only when --png-every is passed.
## The harness + API is our code; ROM and any dumps are user-supplied at runtime.

import
  std/[os, strutils, strformat, times, algorithm, options, monotimes, httpclient, json],
  pixie,
  windy,
  ../decompbound/[cpu, ppu, snesbus, lua53, policy, save_state],
  ./[glblit, touch_grass]

const
  DefaultFrames = 60
  DefaultLlmInterval = 20
  DefaultPngEvery = 0
  DefaultSpeed = 0
  MaxPacingBacklogFrames = 4
    ## How many frames of "debt" we allow before resetting schedule (prevents burst after stall).
  AzemBaseUrl = "http://10.11.2.22:1234/v1"
    ## LM Studio on azem (local, free, always-on). Change for a cloud/other host.
  AzemApiKey = "lm-studio"
    ## LM Studio ignores the key; any non-empty value avoids the OPENAI_API_KEY env.
  PolicyModel = "qwen3.6-35b-a3b@q4_k_m"
    ## Fast MoE (~3B active) — good latency for the per-N-frame policy-rewrite loop.
  SkillsFile = "bin/states/llm_skills.lua"
    ## Persistent skill library (walkTo etc). Loaded at boot into Lua BEFORE policy. Gitignored.
  NotesFile = "bin/states/llm_notes.txt"
    ## Persistent notes (agent knowledge). Loaded into prompt; -- NOTE: appends here. Gitignored.

type
  PolicyProvider = proc(summary: string, currentLua: string): string

var
  persistentNotes = ""
    ## Loaded at boot from NotesFile; augmented on -- NOTE: parses; fed into realProvider prompt.
  recentHistory: seq[string] = @[]
    ## Last few slow-tick outcomes for LLM (frame, tg/room before->after, progress flag). Fed in rich context.
  prevTg = 0
  prevRoom = ""
    ## For detecting progress between LLM queries (tg% or room label changed?).

proc mockProvider(summary: string, currentLua: string): string =
  ## Canned fixed policy for verification without API key.
  ## Always returns the same short update() that presses Right on even frames.
  ## This string travels the identical loadbuffer/pcall/runPolicyFrame/joy1 path
  ## that a real LLM response would.
  ## Includes a -- NOTE: (only on first call when notes empty) so verify run records a note (parsed from returned policy).
  let includeNote = (persistentNotes.len == 0)
  if includeNote:
    result = """-- NOTE: (mock) walkTo and skills preloaded at boot; persistent brain active
function update()
  if frame() % 2 == 0 then
    pad.press('Right')
  else
    pad.set('Right', false)
  end
end
"""
  else:
    result = """function update()
  if frame() % 2 == 0 then
    pad.press('Right')
  else
    pad.set('Right', false)
  end
end
"""

proc extractLuaBlock(text: string): string =
  ## Best-effort extractor for a 'function update() ... end' policy even when the
  ## model (reasoning qwen) buries it inside reasoning_content or adds prose.
  ## Uses the LAST 'function update' (in case of echoes) to the LAST 'end' after it.
  if text.len == 0: return ""
  let key = "function update"
  var lastStart = -1
  var pos = 0
  while true:
    let idx = text.find(key, pos)
    if idx < 0: break
    lastStart = idx
    pos = idx + key.len
  if lastStart < 0: return ""
  # Take up to the last "end" after this start (handles inner ends + concluding code at tail of CoT).
  let endIdx = text.rfind("end", start = lastStart)
  if endIdx >= lastStart:
    result = text[lastStart ..< endIdx + 3].strip()
  else:
    result = text[lastStart ..< min(text.len, lastStart + 400)].strip()

proc realProvider(summary: string, currentLua: string): string =
  ## Real LLM call via direct HTTP (to access reasoning_content from qwen3 reasoning model).
  ## openai_leap's RespMessage only exposes .content (which is "" for reasoning models
  ## when tokens are tight); we POST and parse JSON raw to read both content and
  ## reasoning_content. Falls back to extracting the update block from reasoning.
  ## max_tokens=2000 (OUTPUT only; INPUT is rich full context on purpose, 256K window).
  let t0 = now()
  const SystemPrompt = """You are an expert at writing compact Lua policies that play EarthBound (SNES decomp harness).

GOAL: Leave the house — descend stairs from bedroom, exit through door to reach outside Onett ("touch grass"). Use the RICH STATE (tg_pct, current_room, player $0BBE/$0BFA pos, in_battle, menu_open, HP/PP, sector) + ON-SCREEN TEXT + PERSISTENT NOTES + RECENT HISTORY to decide actions and course-correct when stuck (no tg/room progress after several ticks).

SANDBOX API (globals always available in update()):
- frame() -> int (current frame)
- mem.read(addr) -> byte (WRAM; player = party leader entity slot 24: world X at 0x0BBE/0x0BBF, Y at 0x0BFA/0x0BFB)
- pad.press("A") / pad.set("Right", true)  (buttons: A B X Y L R Up Down Left Right Start Select)
- screen.text() -> string  (current on-screen dialogue, menus, battle commands via getScreenText)
- sim.setSpeed(fps) / sim.fast() / sim.normal()  (0=unlimited fast-forward for corridors; 60 for menus/fights. Decoupled from your LLM tick.)

AVAILABLE LIBRARY SKILLS (preloaded from bin/states/llm_skills.lua into Lua globals; call them from your update()):
- walkTo(tx, ty): reactive navigation skill. Reads live player pos, presses d-pad to move toward target world coords. Auto-detects stuck (pos unchanged) and wiggles perp dir to route around. Stops when manhattan <=~12. Example: walkTo(0x1E00, 0x05C0) to head for stairs/door. Call repeatedly each frame from update().
- winBattle(): read-driven battle clearer. Uses screen.text() to detect command menu ("Bash"/"INPUT YOUR COMMAND"), targets, damage text, victory ("won"/"EXP"). Presses A appropriately. Exits on victory or pos out of battle box. Call winBattle() when in_battle=yes.
(Etc. More skills can be added to llm_skills.lua over runs; always safe to try calling known ones. If undefined the call is no-op.)

PERSISTENT BRAIN:
- Every time you return a policy, you can emit (anywhere):
  -- NOTE: <one concise fact e.g. "bedroom exit door approx (1E00,05C0)", "hold Down+spam A clears stair text", "sector FFFF indoors">
  The harness parses -- NOTE: and appends to bin/states/llm_notes.txt (full file reloaded into prompt every slow tick).
- Full llm_notes.txt is always included below so you remember discoveries across frames/runs.
- Recent history tells you if prior policy made tg%/room progress.

OUTPUT: Return ONLY valid Lua: starts exactly with 'function update()' , ends with 'end'. No markdown fences, no prose, no extra text outside the function. You may add -- NOTE: lines inside or before/after the function.

Use /no_think at end if supported.
"""
  let notesBlock = if persistentNotes.len > 0:
    "\n\nPERSISTENT NOTES (full llm_notes.txt; your accumulated brain):\n" & persistentNotes & "\n(end of notes)\n"
  else:
    "\n\nPERSISTENT NOTES: (no notes yet — use -- NOTE: lines in policy output to build knowledge base)\n"
  let userPrompt = fmt"""RICH STATE + RECENT HISTORY + ON-SCREEN TEXT:
{summary}
{notesBlock}
LAST POLICY (reference; you may incrementally improve or replace the update body):
{currentLua}

Return ONLY the 'function update() ... end' block (nothing else). Call walkTo() / winBattle() / screen.text() etc as needed. /no_think"""

  # Log FULL context sent to qwen (rich input is the point; 256K window, do not trim).
  let fullContextForLog = "SYSTEM:\n" & SystemPrompt & "\n\nUSER:\n" & userPrompt
  let ctxChars = fullContextForLog.len
  let approxTokens = ctxChars div 4
  echo "=== FULL LLM CONTEXT SENT (rich, for qwen 256K) ==="
  echo fullContextForLog
  echo "=== END CONTEXT (chars=", ctxChars, " approx_tokens~", approxTokens, " << 256K; max_tokens=2000 OUTPUT only) ==="

  var raw: string
  var reas: string
  var finishReason = ""
  try:
    let url = AzemBaseUrl & "/chat/completions"
    let client = newHttpClient()
    client.headers = newHttpHeaders({
      "Content-Type": "application/json",
      "Authorization": "Bearer " & AzemApiKey
    })
    let body = %* {
      "model": PolicyModel,
      "max_tokens": 2000,
      "temperature": 0.2,
      "messages": [
        {"role": "system", "content": SystemPrompt},
        {"role": "user", "content": userPrompt}
      ]
    }
    let respBody = client.postContent(url, $body)
    client.close()
    let j = parseJson(respBody)
    if j.hasKey("choices") and j["choices"].len > 0:
      let ch = j["choices"][0]
      if ch.hasKey("message"):
        let msg = ch["message"]
        raw = msg.getOrDefault("content").getStr("")
        reas = msg.getOrDefault("reasoning_content").getStr("")
      finishReason = ch.getOrDefault("finish_reason").getStr("")
  except CatchableError as e:
    echo "LLM ERROR: ", e.msg
    return currentLua

  let dt = (now() - t0).inMilliseconds.int
  echo fmt"LLM_LATENCY: latency_ms={dt} (direct http + max_tokens=2000 + /no_think + rich full context; finish={finishReason})"

  # Prefer content (when non-empty and has policy). Fall back to reasoning_content
  # (qwen reasoning model puts CoT+final in reasoning_content when content=="").
  var candidate = raw
  if (candidate.len == 0 or not candidate.contains("function update")) and reas.len > 0:
    candidate = extractLuaBlock(reas)
    if candidate.len > 0:
      echo "LLM: fell back to reasoning_content block (len=", reas.len, ")"

  var cleaned = candidate.strip()
  if cleaned.startsWith("```"):
    var kept: seq[string] = @[]
    for line in cleaned.splitLines():
      if line.strip().startsWith("```"): continue
      kept.add(line)
    cleaned = kept.join("\n").strip()
  if not cleaned.contains("function update"):
    let head = if cleaned.len > 0: cleaned[0 ..< min(80, cleaned.len)] else: "<empty>"
    echo "LLM returned no update(); keeping prior policy. raw.len=", raw.len, " reas.len=", reas.len, " head=", head
    return currentLua
  echo "LLM RETURNED POLICY (qwen):\n" & cleaned & "\n---END QWEN POLICY---"
  result = cleaned

proc getProvider(useMock: bool): PolicyProvider =
  ## Select mock or real. Mock is default for safe verify without key.
  if useMock:
    return mockProvider
  else:
    return realProvider

proc appendNote(text: string) =
  ## Append a recorded fact to the persistent notes file (and in-memory copy).
  ## Creates bin/states/ if needed. Safe to call from main loop.
  if text.len == 0: return
  let ts = now().format("yyyy-MM-dd'T'HH:mm:ss")
  let entry = fmt"[{ts}] {text}"
  createDir("bin/states")
  let f = open(NotesFile, fmAppend)
  f.writeLine(entry)
  f.close()
  if persistentNotes.len > 0:
    persistentNotes.add("\n" & entry)
  else:
    persistentNotes = entry
  echo "  NOTE recorded: ", text

proc extractAndAppendNotes(src: string) =
  ## Parse "-- NOTE: <text>" (or --NOTE:) lines from an LLM-returned policy string.
  ## Appends each via appendNote so knowledge survives runs. Called on every provider response.
  if src.len == 0: return
  var count = 0
  for raw in src.splitLines():
    let line = raw.strip()
    if line.startsWith("-- NOTE:") or line.startsWith("--NOTE:"):
      let p = line.find(':')
      if p >= 0:
        let text = line[p+1 .. ^1].strip()
        if text.len > 0:
          appendNote(text)
          inc count
  if count > 0:
    echo "  extracted ", count, " -- NOTE: record(s) from returned policy"

proc buildStateSummary(ctx: policy.PolicyContext): string =
  ## Rich FULL LABELED state for qwen 256K context (do NOT trim). Restores + expands all detail:
  ## touch_grass_pct, current_room, HP/PP (party leader), explicit player world pos at $0B8E/$0BCA (ground truth),
  ## sector, in_battle, menu_open + frame. Uses touch_grass for consistency + policy.getScreenText separately.
  let f = ctx.frameCount
  let mem = ctx.snes.bus.mem
  proc safeR8(off: int): int =
    let ea = 0x7E0000 + off
    if ea >= 0 and ea < mem.len: mem[ea].int else: 0
  proc safeR16(off: int): int =
    let lo = safeR8(off)
    let hi = safeR8(off + 1)
    lo or (hi shl 8)

  const
    HpCurOff  = 0x97F5 + 0x023E
    HpMaxOff  = 0x97F5 + 0x0240
    PpCurOff  = 0x97F5 + 0x0244
    PpMaxOff  = 0x97F5 + 0x0246
    SectorOff = 0x89CA
    BattleOff = 0x4DBA
    MenuTextOff = 0x0024

  let hpCur = safeR16(HpCurOff)
  let hpMax = safeR16(HpMaxOff)
  let ppCur = safeR16(PpCurOff)
  let ppMax = safeR16(PpMaxOff)
  let sector = safeR16(SectorOff)
  let inBattle = if safeR8(BattleOff) != 0: "yes" else: "no"
  let menuOpen = if safeR8(MenuTextOff) != 0: "yes" else: "no"
  let tgPct = touch_grass.touchGrassPercent(ctx.snes)
  let roomLabel = touch_grass.currentRoomLabel(ctx.snes)

  # Ground truth player world pos: $0BBE / $0BFA (party leader, slot 24). NOT the legacy 0xB4.
  let pidx = touch_grass.PlayerSlot * touch_grass.SlotIndexStride
  let playerX = touch_grass.readU16(ctx.snes, touch_grass.WorldXBase + pidx)
  let playerY = touch_grass.readU16(ctx.snes, touch_grass.WorldYBase + pidx)

  result = fmt"""RICH LABELED STATE:
touch_grass_pct: {tgPct}
current_room: {roomLabel}
HP: {hpCur}/{hpMax}
PP: {ppCur}/{ppMax}
player_pos_$0BBE_$0BFA: X=0x{playerX:04X} ({playerX}), Y=0x{playerY:04X} ({playerY})
sector: {sector} (0x{sector:04X})
in_battle: {inBattle}
menu_open: {menuOpen}
frame: {f}
"""

proc loadPolicyChunk(L: lua53.PState, src: string, label: string): bool =
  ## Load and exec a Lua chunk that should define global update(). Returns true on success.
  let ls = L.loadbuffer(src.cstring, src.len.cint, label.cstring)
  if ls != lua53.OK:
    echo fmt"loadbuffer failed for {label}: {L.toString(-1)}"
    L.pop(1)
    return false
  let ps = L.pcall(0, 0, 0)
  if ps != lua53.OK:
    echo fmt"pcall exec failed for {label}: {L.toString(-1)}"
    L.pop(1)
    return false
  return true

proc loadSram(snes: SnesBus, path: string) =
  ## Load a battery save into SRAM if the .srm file exists (else start fresh).
  ## Used only for the LLM's isolated save when --save-srm is given.
  if fileExists(path):
    let data = readFile(path)
    for i in 0 ..< min(data.len, snes.sram.len):
      snes.sram[i] = data[i].uint8
    echo "loaded save: ", path, " (", data.len, " bytes)"

proc sramBytes(snes: SnesBus): string =
  ## Serialize the 8KB SRAM to a byte string.
  result = newString(snes.sram.len)
  for i in 0 ..< snes.sram.len:
    result[i] = snes.sram[i].char

proc sramValid(snes: SnesBus): bool =
  ## True if the SRAM carries EB's "HAL Laboratory, inc." save signature.
  ## A real save, not empty/garbage, so we never back up junk.
  const Sig = "HAL Laboratory, inc."
  for i in 0 ..< Sig.len:
    if snes.sram[i].char != Sig[i]: return false
  true

proc saveSram(snes: SnesBus, path: string) =
  ## Write the 8KB battery SRAM to the .srm, plus a rotating, timestamped backup
  ## (of valid saves only) in bin/sram_backups/, keeping the newest 2000.
  ## Same safety pattern as play.nim so a bad write can't destroy progress.
  let bytes = snes.sramBytes()
  writeFile(path, bytes)
  snes.sramDirty = false
  echo "saved: ", path
  if snes.sramValid():
    const MaxBackups = 2000
    let dir = "bin/sram_backups"
    createDir(dir)
    let base = path.splitFile.name
    let backup = dir / (base & "_" & now().format("yyyyMMdd-HHmmss") & ".srm")
    if not fileExists(backup):
      writeFile(backup, bytes)
      echo "  backup: ", backup
    # Prune to the newest MaxBackups.
    var files: seq[string]
    for f in walkFiles(dir / (base & "_*.srm")):
      files.add f
    files.sort()
    for i in 0 ..< max(0, files.len - MaxBackups):
      removeFile(files[i])

proc main() =
  ## Boot emulator, obtain initial policy string from provider (mock or LLM),
  ## load it into sandbox, run fast per-frame loop calling update(), periodically
  ## rebuild summary and re-query provider on slow clock, hot-reload new Lua.
  var maxFrames = DefaultFrames
  var llmInterval = DefaultLlmInterval
  var pngEvery = DefaultPngEvery
  var romPath = ""
  var useMock = true
  var useHeadless = false
  var pngEverySet = false
  var saveSramPath = ""
  var saveSramEnabled = false
  var loadStateSlot = -1
  var targetSpeed = DefaultSpeed
    ## emulation fps target: 0=unlimited (headless default), 60=realtime, 120=2x etc.
    ## wired for pacing; LLM tick (interval) remains on frameCount, decoupled.
  var i = 1
  while i <= paramCount():
    let a = paramStr(i)
    if a == "--frames" and i < paramCount():
      inc i
      maxFrames = parseInt(paramStr(i))
    elif a.startsWith("--frames="):
      maxFrames = parseInt(a[9..^1])
    elif a == "--llm-interval" and i < paramCount():
      inc i
      llmInterval = parseInt(paramStr(i))
    elif a.startsWith("--llm-interval="):
      llmInterval = parseInt(a[15..^1])
    elif a == "--png-every" and i < paramCount():
      inc i
      pngEvery = parseInt(paramStr(i))
      pngEverySet = true
    elif a.startsWith("--png-every="):
      pngEvery = parseInt(a[12..^1])
      pngEverySet = true
    elif a == "--headless":
      useHeadless = true
    elif a == "--no-mock":
      useMock = false
    elif a == "--mock":
      useMock = true
    elif a == "--save-srm":
      saveSramEnabled = true
      if i < paramCount():
        let next = paramStr(i + 1)
        if not next.startsWith("--"):
          saveSramPath = next
          inc i
    elif a.startsWith("--save-srm="):
      saveSramEnabled = true
      saveSramPath = a[11 .. ^1]
    elif a == "--load-state" and i < paramCount():
      inc i
      loadStateSlot = parseInt(paramStr(i))
    elif a.startsWith("--load-state="):
      loadStateSlot = parseInt(a[13..^1])
    elif a == "--speed" and i < paramCount():
      inc i
      targetSpeed = parseInt(paramStr(i))
    elif a.startsWith("--speed="):
      targetSpeed = parseInt(a[8..^1])
    elif a == "--help" or a == "-h":
      echo "usage: nim c -r src/tools/llm_ai.nim -- [--frames N] [--llm-interval K] [--png-every M] [--speed N] [--headless] [--mock|--no-mock] [--save-srm | --save-srm=PATH] [--load-state N | --load-state=N] [rom]"
      echo "  defaults: --frames 60 --llm-interval 20 --speed 0 ROM=bin/Earthbound (U) [!].smc"
      echo "  windowed by default (opens GL window titled 'EarthBound - LLM (qwen)' for watching)"
      echo "  --headless: no window (for CI / batch); --png-every only dumps when flag is passed"
      echo "  --speed N: pace emulated frames to N fps (0=unlimited/as-fast, 60=realtime). Decouples from LLM query interval."
      echo "  --speed 0 (default for headless): run full speed; --speed 120: 240 frames ~2s wall time."
      echo "  --mock (default): use canned policy string, no key needed"
      echo "  --no-mock: call real LLM via openai_leap (needs OPENAI_API_KEY)"
      echo "  --save-srm: enable OPTIONAL isolated SRAM for LLM's own progress (never user's)"
      echo "  --save-srm=PATH: override default path bin/states/llm_ai.srm (MUST differ from ROM .srm)"
      echo "  Absent --save-srm (default): NO SRAM I/O, fully ephemeral (for auto LLM tests)"
      echo "  --load-state N: after newSnesBus+resetCpu, call loadState to restore bin/states/slotN.state as start (IN-PLACE, audio-safe)"
      echo "  --load-state=N: alternate form. Skips IntroSkillLua seed (loaded state IS the start, e.g. bedroom at 25% from play Ctrl+1)"
      echo "  Without flag: unchanged (fresh boot + IntroSkillLua). Errors clearly if slot file missing."
      echo "  Persistent brain (default-on, per llm-plays.md Evolution):"
      echo "    bin/states/llm_skills.lua (seeded with walkTo+Intro if absent; loaded into Lua sandbox before policy)"
      echo "    bin/states/llm_notes.txt (loaded into prompt; -- NOTE: lines in policy output are appended)"
      echo "    Both live under bin/states/ (gitignored, user-local; never committed). Skills make walkTo() etc available to policies."
      echo "  sim.setSpeed / sim.fast / sim.normal available in policies (from PolicyContext) to let AI control fps at runtime."
      echo "  To run live: export OPENAI_API_KEY=sk-... ; nix develop -c nim c -r src/tools/llm_ai.nim -- --no-mock --frames 120"
      quit(0)
    elif romPath.len == 0 and not a.startsWith("--"):
      romPath = a
    inc i
  if romPath.len == 0:
    romPath = "bin/Earthbound (U) [!].smc"

  if saveSramEnabled:
    if saveSramPath.len == 0:
      saveSramPath = "bin/states/llm_ai.srm"
    let romSrm = romPath.changeFileExt("srm")
    if saveSramPath == romSrm:
      echo fmt"ERROR: --save-srm path must never resolve to the ROM's .srm: {romSrm} (would touch the user's real save). Refusing."
      quit(1)
    let sdir = saveSramPath.splitFile.dir
    if sdir.len > 0:
      createDir(sdir)
    else:
      createDir("bin")

  let saveStr = if saveSramEnabled: saveSramPath else: "(ephemeral)"
  let loadStr = if loadStateSlot >= 0: $loadStateSlot else: "none"
  echo fmt"llm_ai: ROM={romPath} frames={maxFrames} llmInterval={llmInterval} pngEvery={pngEvery} (set={pngEverySet}) speed={targetSpeed} mock={useMock} headless={useHeadless} loadState={loadStr} saveSram={saveStr}"
  createDir("bin")
  createDir("bin/states")
  persistentNotes = if fileExists(NotesFile): readFile(NotesFile) else: ""
  if persistentNotes.len > 0:
    echo fmt"NOTES: loaded {NotesFile} ({persistentNotes.len} bytes) — will include in LLM prompt"
  else:
    echo fmt"NOTES: {NotesFile} absent (empty brain start; first -- NOTE: will create+append)"

  let rom = policy.readRomFile(romPath)
  let snes = newSnesBus(rom)
  if saveSramEnabled:
    loadSram(snes, saveSramPath)
  var cpu = snes.resetCpu()
  if loadStateSlot >= 0:
    let path = fmt"bin/states/slot{loadStateSlot}.state"
    if not fileExists(path):
      echo fmt"ERROR: --load-state {loadStateSlot} requested but state file missing: {path}"
      quit(1)
    loadState(snes, cpu, loadStateSlot)
    echo "loaded start state from slot ", loadStateSlot
  else:
    snes.initHdma()

  let frameImage = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(
    snes: snes,
    frameImage: frameImage,
    frameCount: 0,
    joy1: 0'u16,
    targetFps: targetSpeed
  )

  let L = lua53.newstate()
  if L == nil:
    echo "ERROR: lua newstate nil"
    quit(1)
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)

  # SKILL LIBRARY (persistent brain part 1): load bin/states/llm_skills.lua BEFORE any policy.
  # If absent, SEED by writing WalkToSkillLua + IntroSkillLua (so walkTo() etc are in scope for LLM policies).
  # This happens once at boot; skills become globals callable from update().
  # (Only edit llm_ai.nim per task; touch_grass provides the strings.)
  if fileExists(SkillsFile):
    let skillSrc = readFile(SkillsFile)
    if loadPolicyChunk(L, skillSrc, "persistent_skills"):
      echo "SKILL_LIBRARY: loaded ", SkillsFile, " (len=", skillSrc.len, ") into sandbox BEFORE policy"
    else:
      echo "SKILL_LIBRARY: WARNING: loadPolicyChunk failed for ", SkillsFile, " (continuing without)"
  else:
    let seedSrc = touch_grass.WalkToSkillLua & "\n\n" & touch_grass.IntroSkillLua
    writeFile(SkillsFile, seedSrc)
    echo "SKILL_LIBRARY: absent; seeded ", SkillsFile, " (len=", seedSrc.len, ") with WalkToSkillLua + IntroSkillLua"
    discard loadPolicyChunk(L, seedSrc, "seeded_skills")
  # Confirm walkTo is callable (from WalkTo seed or prior skills) for verify logs.
  L.getglobal("walkTo".cstring)
  let walkIsFn = (L.getType(-1) == lua53.TFUNCTION)
  L.pop(1)
  if walkIsFn:
    echo "SKILL_LIBRARY: walkTo is callable in the Lua sandbox (confirmed)"
  else:
    echo "SKILL_LIBRARY: walkTo not present as function (policy may still define later)"

  let provider = getProvider(useMock)

  var currentPolicy: string
  if loadStateSlot >= 0:
    # loaded state (e.g. bedroom save) IS the start; skip IntroSkillLua entirely.
    # Seed a bootstrap policy from the mockProvider (fixed; replaced at first slow tick if needed).
    # The harness frameCount starts at 0 but the emulated machine state is from the slot.
    currentPolicy = mockProvider("", "")
    echo "initial policy seeded from mockProvider (len=", currentPolicy.len, ", skipping IntroSkillLua for --load-state)"
  else:
    # Seed INITIAL policy with IntroSkillLua (deterministic title->naming->bedroom).
    # Always start here for both mock and real so multi-step intro actually runs.
    # LLM handoff only after tg>=25 (bedroom reached); see slow-clock guard below.
    currentPolicy = touch_grass.IntroSkillLua
    echo "initial policy seeded with IntroSkillLua (len=", currentPolicy.len, ")"
  if not loadPolicyChunk(L, currentPolicy, "initial"):
    echo "failed to load initial policy; abort"
    quit(1)
  # Extract notes from the initial policy string too (captures the -- NOTE: we put in mock for verify).
  extractAndAppendNotes(currentPolicy)

  echo "starting two-clock loop (fast: per-frame update; slow: LLM every ", llmInterval, " frames)"
  if not useHeadless:
    echo "  windowed mode: a separate GL window will show the LLM-driven play (no keyboard input; policy controls joy1)"
  else:
    echo "  headless mode (no window)"

  var maxTouchGrass = 0
  let logPath = "bin/llm_ai_log.txt"
  createDir("bin")
  proc logTg(msg: string) =
    let f = open(logPath, fmAppend)
    f.writeLine(msg)
    f.close()
    echo msg

  var blit: GlBlit
  if not useHeadless:
    blit = initGlBlit("EarthBound - LLM (qwen)", ppu.ScreenWidth, ppu.ScreenHeight, 3)

  var status = "running"

  # Pacing state for --speed wiring (and AI-controlled via ctx.targetFps / sim.setSpeed).
  # Use deadline schedule: after each frame, advance deadline by 1/fps, sleep remainder if early.
  # Clamp using MaxPacingBacklogFrames: if far behind, reset deadline (prevents weird future over-sleep after stall).
  # 0 = unlimited. Decouples from LLM tick (queries keyed on frameCount only).
  var nextDeadline = getMonoTime()

  # Main loop: policy + step + (optional) GL present. Emulation now paced by --speed / ctx.targetFps.
  # LLM re-queries remain on frame count (llmInterval) regardless of wall time per frame.
  while ctx.frameCount < maxFrames:
    if (not useHeadless) and blit.window.closeRequested:
      break
    if not useHeadless:
      pollEvents()

    let err = policy.runPolicyFrame(L, ctx)
    if err.len > 0:
      echo fmt"policy runtime error frame {ctx.frameCount}: {err}"
      status = "err"

    snes.joy1 = ctx.joy1
    if (ctx.joy1 and policy.BtnRight) != 0:
      echo fmt"  joy1 has RIGHT bit (0x{ctx.joy1:04x}) frame {ctx.frameCount}"

    policy.stepOneFrame(snes, cpu, frameImage)
    ctx.frameCount += 1

    # WIRE --speed / AI fps control: pace to target.
    # After frame, compute next deadline = prev + (1s/fps), sleep remainder to it.
    # If behind by >4 frames worth, reset deadline (clamp backlog, resume without catchup burst/sleep debt).
    # fps=0: skip, run full speed (near-instant for --speed 0).
    # ctx.targetFps read after policy run, so sim.setSpeed(fps) in update() takes effect immediately for next iter.
    let fps = ctx.targetFps
    if fps > 0:
      let frameNs = 1_000_000_000'i64 div fps.int64
      nextDeadline = nextDeadline + initDuration(nanoseconds = frameNs)
      let now = getMonoTime()
      if now < nextDeadline:
        let ns = (nextDeadline - now).inNanoseconds
        let ms = (ns div 1_000_000).int
        if ms > 0:
          sleep(ms)
      else:
        let behind = (now - nextDeadline).inNanoseconds
        if behind > frameNs * MaxPacingBacklogFrames:
          nextDeadline = now

    if not useHeadless:
      blit.blit(frameImage)
      let t = fmt"EarthBound - LLM (qwen) - frame {ctx.frameCount} [{status}]"
      if blit.window.title != t:
        blit.window.title = t

    # Periodic SRAM flush for isolated save (throttled like play.nim to coalesce writes).
    if saveSramEnabled and snes.sramDirty and (ctx.frameCount mod 60 == 0):
      saveSram(snes, saveSramPath)

    # PNG dumps only when --png-every explicitly provided by user; target subdir
    # (prevents bin/ root spam from default or previous runs).
    if pngEverySet and pngEvery > 0 and (ctx.frameCount mod pngEvery == 0):
      createDir("bin/llm_frames")
      let p = fmt"bin/llm_frames/llm_ai_frame_{ctx.frameCount:04d}.png"
      frameImage.writeFile(p)
      echo fmt"  wrote {p}"

    # Slow clock: re-query provider with fresh summary, hot-reload if changed.
    # Never blocks the fast per-frame path; only runs every llmInterval.
    # INTRO SEED: for real LLM, do NOT query/replace until tg>=25 (bedroom).
    # This lets IntroSkillLua drive the full title->naming->bedroom sequence.
    # Then handoff to qwen from bedroom state. For mock, query early (canned).
    if llmInterval > 0 and (ctx.frameCount mod llmInterval == 0) and ctx.frameCount > 0:
      let tg = touch_grass.touchGrassPercent(snes)
      let room = touch_grass.currentRoomLabel(snes)
      if tg > maxTouchGrass:
        maxTouchGrass = tg
      logTg(fmt"{now()} frame={ctx.frameCount} touch_grass_pct={tg} max={maxTouchGrass} room={room}")
      if tg >= 100:
        logTg(fmt"TOUCH GRASS ACHIEVED at frame {ctx.frameCount}")
        echo "TOUCH GRASS ACHIEVED!"
      # Record recent history (last few actions + did tg%/room change since prior LLM tick?)
      # This lets qwen course-correct when stuck (no progress = try different skill/approach).
      let madeProgress = (tg > prevTg) or (room != prevRoom)
      let progStr = if madeProgress: "PROGRESS" else: "NO_CHANGE"
      let histEntry = fmt"[{ctx.frameCount}] tg {prevTg}->{tg} room {prevRoom}->{room} ({progStr})"
      recentHistory.add(histEntry)
      if recentHistory.len > 6:
        recentHistory = recentHistory[recentHistory.len - 6 .. ^1]
      prevTg = tg
      prevRoom = room

      let doLlmCall = useMock or (tg >= 25)
      if doLlmCall:
        status = "thinking"
        if not useHeadless:
          # Keep last frame visible while the (occasional) LLM call is in flight.
          blit.blit(frameImage)
          blit.window.title = fmt"EarthBound - LLM (qwen) - frame {ctx.frameCount} [thinking...]"
        let baseSummary = buildStateSummary(ctx)
        let screenTxt = policy.getScreenText(ctx.snes)
        let histBlock = if recentHistory.len > 0:
          "\n\nRECENT HISTORY (last few policies/actions + progress check tg%/room changed?):\n" & recentHistory.join("\n") & "\n"
        else:
          "\n\nRECENT HISTORY: (none yet)\n"
        let richSummary = baseSummary & histBlock & "\nON-SCREEN TEXT (current dialogue/menu via getScreenText/screen.text):\n" &
          (if screenTxt.len > 0: screenTxt else: "(no readable text visible)")
        let newPolicy = provider(richSummary, currentPolicy)
        # Parse any -- NOTE: lines from the returned policy (mock or real) and append to notes.
        # This is how the agent records knowledge (alternative notes.add not added since only edit llm_ai.nim).
        extractAndAppendNotes(newPolicy)
        if newPolicy.len > 10 and newPolicy != currentPolicy:
          currentPolicy = newPolicy
          if loadPolicyChunk(L, currentPolicy, fmt"frame_{ctx.frameCount}"):
            echo fmt"  policy reloaded at frame {ctx.frameCount}"
            status = "reloaded"
          # else keep running with previous (already defined)
        else:
          status = "running"
      else:
        # keep running the seeded IntroSkillLua; defer LLM until bedroom
        status = "intro"

    if cpu.stopped:
      echo "cpu stopped; ending run"
      break

  let finalTg = touch_grass.touchGrassPercent(snes)
  if finalTg > maxTouchGrass: maxTouchGrass = finalTg
  logTg(fmt"{now()} frame={ctx.frameCount} touch_grass_pct={finalTg} max={maxTouchGrass} (final)")
  echo fmt"done: ran {ctx.frameCount} frames. final joy1=0x{snes.joy1:04x} max_touch_grass={maxTouchGrass}"
  if saveSramEnabled and snes.sramDirty:
    saveSram(snes, saveSramPath)
  L.close()
  quit(0)

when isMainModule:
  main()
