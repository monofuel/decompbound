## LLM-writes-Lua policy player for milestone 2c.
## Two-clock loop: fast clock runs sandboxed Lua update() every frame (drives joy1);
## slow clock periodically asks LLM (or mock) for a fresh/updated Lua policy string
## based on a compact state summary, hot-reloads it, keeps running.
##
## Two modes for the slow clock while a provider request is in-flight:
##   --watch-async (default windowed): keep stepping frames with the *current* policy at
##     --speed pacing; poll + hot-swap when the result lands. True two-clock watch mode.
##   --sync-llm / --pause-llm (default headless): pause frame advance until the response
##     applies. Deterministic apply-at-snapshot for milestone / CI runs.
##
## Uses the exact same load->runPolicyFrame->stepOneFrame->joy1 path as llm_play
## (via shared policy module) so LLM-authored strings are proven equivalent.
## LLM call is swappable: default --mock uses a fixed canned policy for headless verify
## (no API key needed); real path uses direct HTTP when --no-mock.
## Usage: nim r src/tools/llm_ai.nim -- [--frames N] [--llm-interval K] [--png-every M]
##   [--speed N] [--watch-async|--sync-llm|--pause-llm] [--verbose] [--headless]
##   [--mock|--no-mock] [--load-state N] [--save-srm ...] [rom]
## Default is windowed (GL + windy) so you can watch the LLM play alongside `make play`.
## --headless preserves the old no-window behavior for CI. PNG dumps (when enabled)
## now go to bin/llm_frames/ only when --png-every is passed.
## The harness + API is our code; ROM and any dumps are user-supplied at runtime.

import
  std/[os, strutils, strformat, times, algorithm, options, monotimes, httpclient, json, osproc],
  pixie,
  windy,
  ../decompbound/[cpu, ppu, snesbus, lua53, policy, save_state],
  ./[glblit, touch_grass, llm_mock_policies, story_percents]

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
  PolicyModel = "qwen3.6-27b@q6_k"
    ## qwen3.6 reasoning model (exact server id from /v1/models; 27b@q6_k variant tested to accept chat + return reasoning_content). 256K-capable in principle; we keep sent context well under loaded n_ctx (~26k+) by trimming notes+last-policy. max_tokens set high enough for CoT + Lua output.
  SkillsFile = "bin/states/llm_skills.lua"
    ## Persistent skill library (walkTo etc). Loaded at boot into Lua BEFORE policy. Gitignored.
  NotesFile = "bin/states/llm_notes.txt"
    ## Persistent notes (agent knowledge). Loaded into prompt; -- NOTE: appends here. Gitignored.
  LlmStateDir = "bin/states/llm"
    ## LLM-only savestates. NEVER bin/states/slotN.state (human make-play slots).
  LlmBedroomState = "bin/states/llm/bedroom.state"
  LlmRollbackState = "bin/states/llm/rollback.state"
  LlmDefaultSram = "bin/states/llm_ai.srm"

# --- Background LLM provider (threads+channels) for non-blocking two-clock ---
# Main thread owns Lua + Snes exclusively (fast per-frame path never blocks).
# Worker thread only runs the (slow) provider call on (summary, currentLua) and
# returns the new policy string. Hot-swap happens on main when result arrives.
type
  PolicyProvider = proc(summary: string, currentLua: string): string
  ProviderWork = tuple[summary, currentLua, notesSnap: string]
  ProviderResult = tuple[policy: string, latencyMs: int]

# Forward decls (originals for main-thread use; *Snap versions for worker with snapshot to avoid race on persistentNotes).
proc mockProvider(summary: string, currentLua: string): string
proc realProvider(summary: string, currentLua: string): string
proc mockProviderSnap(summary: string, currentLua: string, notes: string): string
proc realProviderSnap(summary: string, currentLua: string, notes: string): string

proc trimForLlm(notes, lastPolicy: string): tuple[notesBlock, policyRef: string] =
  ## Truncate notes + LAST POLICY shown in the *sent* user message (and FULL log) so total
  ## prompt tokens stay safely inside the loaded model's n_ctx (avoids the 65k>26k 400).
  ## Rich STATE + HISTORY + screen text + instructions are kept; only the growing brain blobs trimmed.
  ## This keeps context within window while still giving qwen the prior policy to improve on.
  var n = notes
  if n.len > 6000:
    let ls = n.splitLines()
    if ls.len > 18:
      n = ls[^18 .. ^1].join("\n")
    else:
      n = n[ max(0, n.len-6000) ..< n.len ]
  let nb = if n.len > 0:
    "\n\nPERSISTENT NOTES (trimmed for ctx fit; full file in llm_notes.txt; your brain):\n" & n & "\n(end)\n"
  else:
    "\n\nPERSISTENT NOTES: (no notes yet — use -- NOTE: lines in policy output to build knowledge base)\n"
  var p = lastPolicy
  if p.len > 2400:
    let h = p[0 ..< min(700, p.len)]
    let t = if p.len > 700: p[ max(0, p.len-1600) ..< p.len ] else: ""
    p = h & "\n...[trimmed " & $(p.len - 700 - 1600) & " middle chars for 256K/ctx fit; see FULL log or file for prior]...\n" & t
  (nb, p)

var
  workChan: Channel[ProviderWork]
  resultChan: Channel[ProviderResult]
  workerThread: Thread[void]
  gUseMock: bool            # set at startup; worker dispatches without storing proc (GC-safety)
  gVerbose = false          # --verbose: dump full multi-KB prompts / request JSON
  pendingLlm = false        # true while a request is in flight (prevents duplicate queueing)
  framesDuringPending = 0   # frames advanced while a request was in-flight (async proof)

proc llmWorkerProc() {.thread.} =
  ## Worker: loops, receives work nonblockingly, executes the provider (HTTP or mock) using SNAPSHOT of notes.
  ## sends result back. Never touches L, ctx, snes, or frameImage. Snapshot prevents data race with main's appendNote.
  while true:
    let (hasWork, work) = workChan.tryRecv()
    if hasWork:
      let t0 = now()
      let policy =
        block:
          {.gcsafe.}:
            if gUseMock: mockProviderSnap(work.summary, work.currentLua, work.notesSnap) else: realProviderSnap(work.summary, work.currentLua, work.notesSnap)
      let dt = (now() - t0).inMilliseconds.int
      resultChan.send( (policy, dt) )
    sleep(1)

var
  persistentNotes = ""
    ## Loaded at boot from NotesFile; augmented on -- NOTE: parses; fed into realProvider prompt.
  recentHistory: seq[string] = @[]
    ## Last few slow-tick outcomes for LLM (frame, tg/room before->after, progress flag). Fed in rich context.
var
  prevTg = 0
  prevRoom = ""
    ## For detecting progress between LLM queries (tg% or room label changed?).
  lastMilestonePath = ""
  stuckCounter = 0
  prevMoney = 0
  prevPlayerX = 0
  prevPlayerY = 0
  prevPokey = 0
  lastLogSig = ""
    ## Last logged progress signature (tg/room/story-pcts). The per-tick status line only
    ## prints when this changes or on a periodic heartbeat — otherwise a 10k-frame run emits
    ## hundreds of identical lines.
    ## For higher-level stuck + auto rollback. We now also track live player world pos delta
    ## (tg/room plateaus at 75 inside house even while successfully walking toward the door)
    ## and story-percent gains (pokey_pct climbs while tg is pinned at 100 outside — without
    ## this the door-approach reads as "stuck" and rolls back to 0 forever).
  scenarioPolicy = llm_mock_policies.NavHousePolicy
    ## Selected by --load-state at startup (slot1 = battle per doc + strategy). Used by mock providers.

proc mockProvider(summary: string, currentLua: string): string =
  ## Delegates to scenarioPolicy selected at startup (battle for slot1, nav otherwise).
  ## Wraps with -- NOTE: on first use for brain. Pure selection keeps battle/nav decoupled.
  let includeNote = (persistentNotes.len == 0)
  if includeNote:
    result = "-- NOTE: (mock) scenario=" & (if scenarioPolicy.contains("winBattle()") and not scenarioPolicy.contains("walkTo"): "battle" else: "nav") & "\n" & scenarioPolicy
  else:
    result = scenarioPolicy

proc mockProviderSnap(summary: string, currentLua: string, notes: string): string =
  ## Snapshot version for worker (data race safe). Delegates to scenarioPolicy.
  let includeNote = (notes.len == 0)
  if includeNote:
    result = "-- NOTE: (mock) scenario=" & (if scenarioPolicy.contains("winBattle()") and not scenarioPolicy.contains("walkTo"): "battle" else: "nav") & "\n" & scenarioPolicy
  else:
    result = scenarioPolicy

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
  ## max_tokens=4096 (OUTPUT only; INPUT trimmed to fit loaded ctx; 256K window target).
  let t0 = now()
  const SystemPrompt = """You are an expert at writing compact Lua policies that play EarthBound (SNES decomp harness).

GOAL: Touch grass — walk bedroom → stairs → sitting room (south first) → east front door → outside Onett (tg 25→75→100). No battle on this path.
WAYPOINTS (pick next from live px/py; call walkTo every frame):
- bedroom (tg25 / x>=0x1F00 upstairs): walkTo(0x1F00,0x0450) then hall (0x1D40,0x03E8) then stair (0x1CC0,0x03E8)
- after stairs (downstairs): SOUTH first walkTo(0x1D30,0x0178) — do NOT pure-east along y=0x0140 (furniture)
- sitting: walkTo(0x1E70,0x0170) then door (0x1E80,0x0148) then push (0x1F40,0x0148) → outside ~0x0A60,0x0158
INPUT: d-pad only via walkTo. Never A while walking (opens menu). B / escapeMenu() if menu_open. winBattle ONLY if in_battle=yes.
PATTERN: if escapeMenu() then return end; then walkTo(nextWaypoint) based on pos/tg.

SANDBOX API (globals always available in update()):
- frame() -> int (current frame)
- mem.read(addr) -> byte (WRAM; player = party leader entity slot 24: world X at 0x0BBE/0x0BBF, Y at 0x0BFA/0x0BFB)
- pad.press("A") / pad.set("Right", true)  (buttons: A B X Y L R Up Down Left Right Start Select)
- screen.text() -> string  (current on-screen dialogue, menus, battle commands via getScreenText)
- sim.setSpeed(fps) / sim.fast() / sim.normal()  (0=unlimited fast-forward for corridors; 60 for menus/fights. Decoupled from your LLM tick.)

AVAILABLE LIBRARY SKILLS (preloaded from bin/states/llm_skills.lua into Lua globals; call them from your update()):
- escapeMenu(): detects overworld menus via screen.text() (Talk/Check/Equip/Status/Goods without battle keywords) and presses B to cancel. Auto-called by walkTo. Call early in update() for safety.
- walkTo(tx, ty): reactive navigation skill. Reads live player pos, presses d-pad ONLY to move toward target. Auto-detects stuck and wiggles; auto-escapes menus first. Stops when manhattan <=~12. NEVER presses A. Example: walkTo(0x1E00, 0x05C0) to head for stairs/door. Call repeatedly each frame from update().
- winBattle(): read-driven battle clearer. Uses screen.text() to detect command menu ("Bash"/"INPUT YOUR COMMAND"), targets, damage text, victory ("won"/"EXP"). Presses A appropriately. Exits on victory or pos out of battle box. Call winBattle() when in_battle=yes.
(Etc. More skills can be added to llm_skills.lua over runs; always safe to try calling known ones. If undefined the call is no-op.)

PERSISTENT BRAIN:
- Every time you return a policy, you can emit (anywhere):
  -- NOTE: <one concise fact e.g. "bedroom exit door approx (1E00,05C0)", "A opens command menu on overworld - use B to cancel", "sector FFFF indoors">
  The harness parses -- NOTE: and appends to bin/states/llm_notes.txt (full file reloaded into prompt every slow tick).
- Full llm_notes.txt is always included below so you remember discoveries across frames/runs.
- Recent history tells you if prior policy made tg%/room progress.

OUTPUT: Return ONLY valid Lua: starts exactly with 'function update()' , ends with 'end'. No markdown fences, no prose, no extra text outside the function. You may add -- NOTE: lines inside or before/after the function.

Use /no_think at end if supported.
"""
  # Use trimmed notes + policyRef for the sent prompt (ctx safety) while preserving critical recent state.
  let (notesBlock, policyRef) = trimForLlm(persistentNotes, currentLua)
  let userPrompt = fmt"""RICH STATE + RECENT HISTORY + ON-SCREEN TEXT:
{summary}
{notesBlock}
LAST POLICY (reference; you may incrementally improve or replace the update body):
{policyRef}

Return ONLY the 'function update() ... end' block (nothing else). Call escapeMenu() / walkTo() / winBattle() / screen.text() etc as needed (A opens menus, B cancels). /no_think"""

  # Log FULL context only with --verbose (multi-KB dump is slow and noisy for watch mode).
  let fullContextForLog = "SYSTEM:\n" & SystemPrompt & "\n\nUSER:\n" & userPrompt
  let ctxChars = fullContextForLog.len
  let approxTokens = ctxChars div 4
  if gVerbose:
    echo "=== FULL LLM CONTEXT SENT (trimmed for ctx; rich state kept) ==="
    echo fullContextForLog
    echo "=== END CONTEXT (chars=", ctxChars, " approx_tokens~", approxTokens, " << 256K; max_tokens=4096 OUTPUT only) ==="
  else:
    echo fmt"LLM_REQUEST: chars={ctxChars} approx_tokens~{approxTokens} (pass --verbose for full prompt dump)"

  var raw: string
  var reas: string
  var finishReason = ""
  let url = AzemBaseUrl & "/chat/completions"
  let body = %* {
    "model": PolicyModel,
    "max_tokens": 4096,
    "temperature": 0.2,
    "messages": [
      {"role": "system", "content": SystemPrompt},
      {"role": "user", "content": userPrompt}
    ]
  }
  if gVerbose:
    echo "=== ACTUAL REQUEST JSON ==="
    echo $body
    echo "=== END REQUEST JSON (endpoint=", url, ") ==="
  try:
    let client = newHttpClient()
    client.headers = newHttpHeaders({
      "Content-Type": "application/json",
      "Authorization": "Bearer " & AzemApiKey
    })
    let resp = client.post(url, $body)
    let respBody = resp.body
    client.close()
    if not resp.status.startsWith("200"):
      echo "=== AZEM ERROR RESPONSE BODY (status=", resp.status, ") ==="
      echo respBody
      echo "=== END ERROR BODY ==="
      echo "LLM ERROR: ", resp.status
      return currentLua
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
  echo fmt"LLM_LATENCY: latency_ms={dt} (direct http + max_tokens=4096 + /no_think + trimmed-ctx; finish={finishReason})"

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
  # Force a differing string (comment only) so qwen response always triggers distinct "policy applied"
  # reload branch for verify; the comment is inert and documents the landing.
  cleaned = cleaned & "\n-- qwen-applied " & $getTime().toUnix()
  if gVerbose:
    echo "LLM RETURNED POLICY (qwen):\n" & cleaned & "\n---END QWEN POLICY---"
  else:
    echo fmt"LLM RETURNED POLICY (qwen): len={cleaned.len} (pass --verbose for full dump)"
  result = cleaned

proc realProviderSnap(summary: string, currentLua: string, notes: string): string =
  ## Snapshot version for worker: uses passed notes snapshot instead of global persistentNotes.
  ## Prevents data race (main appendNote writes while worker reads during HTTP).
  let t0 = now()
  const SystemPrompt = """You are an expert at writing compact Lua policies that play EarthBound (SNES decomp harness).

GOAL: Touch grass — walk bedroom → stairs → sitting room (south first) → east front door → outside Onett (tg 25→75→100). No battle on this path.
WAYPOINTS (pick next from live px/py; call walkTo every frame):
- bedroom (tg25 / x>=0x1F00 upstairs): walkTo(0x1F00,0x0450) then hall (0x1D40,0x03E8) then stair (0x1CC0,0x03E8)
- after stairs (downstairs): SOUTH first walkTo(0x1D30,0x0178) — do NOT pure-east along y=0x0140 (furniture)
- sitting: walkTo(0x1E70,0x0170) then door (0x1E80,0x0148) then push (0x1F40,0x0148) → outside ~0x0A60,0x0158
INPUT: d-pad only via walkTo. Never A while walking (opens menu). B / escapeMenu() if menu_open. winBattle ONLY if in_battle=yes.
PATTERN: if escapeMenu() then return end; then walkTo(nextWaypoint) based on pos/tg.

SANDBOX API (globals always available in update()):
- frame() -> int (current frame)
- mem.read(addr) -> byte (WRAM; player = party leader entity slot 24: world X at 0x0BBE/0x0BBF, Y at 0x0BFA/0x0BFB)
- pad.press("A") / pad.set("Right", true)  (buttons: A B X Y L R Up Down Left Right Start Select)
- screen.text() -> string  (current on-screen dialogue, menus, battle commands via getScreenText)
- sim.setSpeed(fps) / sim.fast() / sim.normal()  (0=unlimited fast-forward for corridors; 60 for menus/fights. Decoupled from your LLM tick.)

AVAILABLE LIBRARY SKILLS (preloaded from bin/states/llm_skills.lua into Lua globals; call them from your update()):
- escapeMenu(): detects overworld menus via screen.text() (Talk/Check/Equip/Status/Goods without battle keywords) and presses B to cancel. Auto-called by walkTo. Call early in update() for safety.
- walkTo(tx, ty): reactive navigation skill. Reads live player pos, presses d-pad ONLY to move toward target. Auto-detects stuck and wiggles; auto-escapes menus first. Stops when manhattan <=~12. NEVER presses A. Example: walkTo(0x1E00, 0x05C0) to head for stairs/door. Call repeatedly each frame from update().
- winBattle(): read-driven battle clearer. Uses screen.text() to detect command menu ("Bash"/"INPUT YOUR COMMAND"), targets, damage text, victory ("won"/"EXP"). Presses A appropriately. Exits on victory or pos out of battle box. Call winBattle() when in_battle=yes.
(Etc. More skills can be added to llm_skills.lua over runs; always safe to try calling known ones. If undefined the call is no-op.)

PERSISTENT BRAIN:
- Every time you return a policy, you can emit (anywhere):
  -- NOTE: <one concise fact e.g. "bedroom exit door approx (1E00,05C0)", "A opens command menu on overworld - use B to cancel", "sector FFFF indoors">
  The harness parses -- NOTE: and appends to bin/states/llm_notes.txt (full file reloaded into prompt every slow tick).
- Full llm_notes.txt is always included below so you remember discoveries across frames/runs.
- Recent history tells you if prior policy made tg%/room progress.

OUTPUT: Return ONLY valid Lua: starts exactly with 'function update()' , ends with 'end'. No markdown fences, no prose, no extra text outside the function. You may add -- NOTE: lines inside or before/after the function.

Use /no_think at end if supported.
"""
  # Use trimmed notes + policyRef for the sent prompt (ctx safety) while preserving critical recent state.
  let (notesBlock, policyRef) = trimForLlm(notes, currentLua)
  let userPrompt = fmt"""RICH STATE + RECENT HISTORY + ON-SCREEN TEXT:
{summary}
{notesBlock}
LAST POLICY (reference; you may incrementally improve or replace the update body):
{policyRef}

Return ONLY the 'function update() ... end' block (nothing else). Call escapeMenu() / walkTo() / winBattle() / screen.text() etc as needed (A opens menus, B cancels). /no_think"""

  # Log FULL context only with --verbose (multi-KB dump is slow and noisy for watch mode).
  let fullContextForLog = "SYSTEM:\n" & SystemPrompt & "\n\nUSER:\n" & userPrompt
  let ctxChars = fullContextForLog.len
  let approxTokens = ctxChars div 4
  if gVerbose:
    echo "=== FULL LLM CONTEXT SENT (trimmed for ctx; rich state kept) ==="
    echo fullContextForLog
    echo "=== END CONTEXT (chars=", ctxChars, " approx_tokens~", approxTokens, " << 256K; max_tokens=4096 OUTPUT only) ==="
  else:
    echo fmt"LLM_REQUEST: chars={ctxChars} approx_tokens~{approxTokens} (pass --verbose for full prompt dump)"

  var raw: string
  var reas: string
  var finishReason = ""
  let url = AzemBaseUrl & "/chat/completions"
  let body = %* {
    "model": PolicyModel,
    "max_tokens": 4096,
    "temperature": 0.2,
    "messages": [
      {"role": "system", "content": SystemPrompt},
      {"role": "user", "content": userPrompt}
    ]
  }
  if gVerbose:
    echo "=== ACTUAL REQUEST JSON ==="
    echo $body
    echo "=== END REQUEST JSON (endpoint=", url, ") ==="
  try:
    let client = newHttpClient()
    client.headers = newHttpHeaders({
      "Content-Type": "application/json",
      "Authorization": "Bearer " & AzemApiKey
    })
    let resp = client.post(url, $body)
    let respBody = resp.body
    client.close()
    if not resp.status.startsWith("200"):
      echo "=== AZEM ERROR RESPONSE BODY (status=", resp.status, ") ==="
      echo respBody
      echo "=== END ERROR BODY ==="
      echo "LLM ERROR: ", resp.status
      return currentLua
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
  echo fmt"LLM_LATENCY: latency_ms={dt} (direct http + max_tokens=4096 + /no_think + trimmed-ctx; finish={finishReason})"

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
  # Force a differing string (comment only) so qwen response always triggers distinct "policy applied"
  # reload branch for verify; the comment is inert and documents the landing.
  cleaned = cleaned & "\n-- qwen-applied " & $getTime().toUnix()
  if gVerbose:
    echo "LLM RETURNED POLICY (qwen):\n" & cleaned & "\n---END QWEN POLICY---"
  else:
    echo fmt"LLM RETURNED POLICY (qwen): len={cleaned.len} (pass --verbose for full dump)"
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
  # Dedup: mock/seed policies carry the same -- NOTE: every tick. Skip re-recording
  # (and re-echoing) a note we already hold — kills the per-tick "NOTE recorded" spam
  # and stops the notes file bloating with identical lines.
  if text in persistentNotes: return
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

proc extractNotes(src: string): string =
  ## Extract -- NOTE: lines without appending (for reports and snapshots).
  if src.len == 0: return ""
  var collected: seq[string] = @[]
  for raw in src.splitLines():
    let line = raw.strip()
    if line.startsWith("-- NOTE:") or line.startsWith("--NOTE:"):
      let p = line.find(':')
      if p >= 0:
        let text = line[p+1 .. ^1].strip()
        if text.len > 0: collected.add(text)
  collected.join("\n")

proc buildStateSummary(ctx: policy.PolicyContext): string =
  ## Rich FULL LABELED state for qwen 256K context (do NOT trim). Restores + expands all detail:
  ## touch_grass_pct, current_room, HP/PP, money, party_roster (from SRAM/WRAM), player pos,
  ## sector, in_battle, menu_open + which_menu + frame.
  ## Uses touch_grass + policy.getScreenText for robust menu detection (fixes menu-blindness).
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

  let hpCur = safeR16(HpCurOff)
  let hpMax = safeR16(HpMaxOff)
  let ppCur = safeR16(PpCurOff)
  let ppMax = safeR16(PpMaxOff)
  let sector = safeR16(SectorOff)
  let inBattle = if safeR8(BattleOff) != 0: "yes" else: "no"
  let tgPct = touch_grass.touchGrassPercent(ctx.snes)
  let roomLabel = touch_grass.currentRoomLabel(ctx.snes)
  let pokeyPct = story_percents.pokeyPercent(ctx.snes)
  let pokeyKnockPct = story_percents.pokeyKnockPercent(ctx.snes)
  let buzzBuzzPct = story_percents.buzzBuzzPercent(ctx.snes)
  let sunrisePct = story_percents.sunrisePercent(ctx.snes)

  # MENU DETECTION (robust for menu-blindness fix): prefer getScreenText (visible items) over old flag.
  # Detects overworld (Talk/Check/..) vs battle (Bash/..) vs submenus; sets menu_open + which_menu.
  # via getScreenText per task spec (or WRAM fallback).
  let screenForMenu = policy.getScreenText(ctx.snes)
  let lowM = screenForMenu.toLowerAscii()
  var menuOpen = "no"
  var whichMenu = "none"
  let owKeys = ["talk to", "check", "equip", "status"]
  let batKeys = ["bash", "psi", "defend", "input your command"]
  let subKeys = ["use", "give", "info", "trash", "who", "which"]
  if lowM.len > 0:
    for k in owKeys:
      if k in lowM:
        menuOpen = "yes"
        whichMenu = "overworld_command"
        break
    if menuOpen == "no":
      for k in batKeys:
        if k in lowM:
          menuOpen = "yes"
          whichMenu = "battle_command"
          break
    if menuOpen == "no":
      for k in subKeys:
        if k in lowM:
          menuOpen = "yes"
          whichMenu = "submenu"
          break
  if menuOpen == "no":
    # legacy WRAM flag fallback (may be nonzero in non-menu; text is authoritative)
    if safeR8(0x0024) != 0 and lowM.len == 0:
      menuOpen = "maybe"
      whichMenu = "unknown_flag"

  # Ground truth player world pos: $0BBE / $0BFA (party leader, slot 24). NOT the legacy 0xB4.
  let pidx = touch_grass.PlayerSlot * touch_grass.SlotIndexStride
  let playerX = touch_grass.readU16(ctx.snes, touch_grass.WorldXBase + pidx)
  let playerY = touch_grass.readU16(ctx.snes, touch_grass.WorldYBase + pidx)

  # Expanded progress surface (from SRAM/WRAM per sram_info offsets + live RAM mirrors).
  # money at ~0x9831, party roster at 0x988B+ (1-based ids, 0=empty).
  let money = safeR16(0x9831)
  let pr0 = safeR8(0x988B)
  let pr1 = safeR8(0x988C)
  let pr2 = safeR8(0x988D)
  let partyRoster = fmt"{pr0} {pr1} {pr2}".strip()

  result = fmt"""RICH LABELED STATE:
touch_grass_pct: {tgPct}
pokey_pct: {pokeyPct}
pokey_knock_pct: {pokeyKnockPct}
buzzbuzz_pct: {buzzBuzzPct}
sunrise_pct: {sunrisePct}
current_room: {roomLabel}
HP: {hpCur}/{hpMax}
PP: {ppCur}/{ppMax}
money: {money}
party_roster: {partyRoster}
player_pos_$0BBE_$0BFA: X=0x{playerX:04X} ({playerX}), Y=0x{playerY:04X} ({playerY})
sector: {sector} (0x{sector:04X})
in_battle: {inBattle}
menu_open: {menuOpen}
which_menu: {whichMenu}
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

proc pollAndApplyResult(L: lua53.PState, currentPolicy: var string, status: var string, frame: int): bool =
  ## Non-blocking poll for background provider result. Hot-swap policy if arrived.
  ## Empty, short, unchanged, or load-failed Lua never clobbers a working policy string
  ## (seed NavHouse / explore / prior qwen stay live). Returns true if a result was consumed.
  let (got, res) = resultChan.tryRecv()
  if got:
    let (newP, lat) = res
    extractAndAppendNotes(newP)
    if newP.len <= 10 or newP == currentPolicy:
      # Unchanged (the common case for mock/seed every tick) — stay silent to cut spam.
      status = "running"
    elif loadPolicyChunk(L, newP, fmt"frame_{frame}"):
      currentPolicy = newP
      echo fmt"BACKGROUND: policy reloaded (latency_ms={lat}) at frame {frame}"
      status = "reloaded"
    else:
      echo fmt"  policy load FAILED; kept prior working policy at frame {frame}"
      discard loadPolicyChunk(L, currentPolicy, fmt"frame_{frame}_restore")
      status = "running"
    pendingLlm = false
    return true
  return false

proc getGitHash(): string =
  ## Short git commit for pinning reports to exact harness version (load-bearing for diffing runs).
  try:
    let (outp, code) = execCmdEx("git rev-parse --short HEAD")
    if code == 0: return outp.strip()
  except CatchableError:
    discard
  "unknown"

proc writeMilestoneReport(milestone: string, frame: int, tgFrom, tgTo: int, roomFrom, roomTo: string, px, py: int, policyAtCross: string) =
  ## Emit the structured milestone report exactly as specified in docs/llm-plays.md .
  ## Includes any -- NOTE: lines present in the policy at crossing time.
  createDir("bin/llm_reports")
  let h = getGitHash()
  let ts = now().format("yyyy-MM-dd'T'HH:mm:ss")
  let fname = fmt"bin/llm_reports/{milestone}_{h}.md"
  let notesInPolicy = extractNotes(policyAtCross)
  let notesSection = if notesInPolicy.len > 0: notesInPolicy else: "(none this tick)"
  let body = fmt"""# Milestone report: {milestone}

frame: {frame}
wall_clock: {ts}
tg_pct: {tgFrom} -> {tgTo}
player_pos_$0BBE_$0BFA: 0x{px:04X},{py} ({px},{py})
room: {roomFrom} -> {roomTo}
git_commit: {h}

## Active policy at crossing
```lua
{policyAtCross}
```

## -- NOTE: lines at crossing
{notesSection}

"""
  writeFile(fname, body)
  echo fmt"  MILESTONE_REPORT written: {fname}"

proc llmSlotPath(slot: int): string =
  ## LLM-namespace numbered slot (not make-play bin/states/slotN.state).
  LlmStateDir / &"slot{slot}.state"

proc ensureLlmStateDir() =
  createDir(LlmStateDir)

proc writeStateFile(path: string, snes: SnesBus, cpu: Cpu) =
  ## Write savestate to an arbitrary path (LLM namespace only by convention).
  let dir = path.splitFile.dir
  if dir.len > 0: createDir(dir)
  writeFile(path, cast[string](serializeState(snes, cpu)))

proc readStateFile(path: string, snes: SnesBus, cpu: var Cpu) =
  if not fileExists(path):
    raise newException(IOError, &"state file not found: {path}")
  deserializeState(cast[seq[byte]](readFile(path)), snes, cpu)

proc seedLlmBedroomIfMissing() =
  ensureLlmStateDir()
  if fileExists(LlmBedroomState): return
  const seed = "bin/states/game_start.state"
  if fileExists(seed):
    copyFile(seed, LlmBedroomState)
    echo fmt"LLM state: seeded {LlmBedroomState} from {seed}"
  else:
    echo fmt"LLM state: missing {LlmBedroomState} and {seed} — capture a bedroom state under {LlmStateDir}/"

proc isHumanPlaySlotPath(path: string): bool =
  for hs in 1..4:
    if path == statePathForSlot(hs): return true
  false

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
  var loadStatePath = ""
  var policyFile = ""
  var saveStateSlot = -1
  var targetSpeed = DefaultSpeed
    ## emulation fps target: 0=unlimited (headless default), 60=realtime, 120=2x etc.
    ## wired for pacing; LLM tick (interval) remains on frameCount, decoupled.
  var watchAsync = false
    ## true: keep stepping while LLM in-flight (true two-clock). false: pause-for-consistency.
  var clockModeSet = false
    ## true if user passed --watch-async / --sync-llm / --pause-llm (else default by headless).
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
    elif a == "--watch-async":
      watchAsync = true
      clockModeSet = true
    elif a == "--sync-llm" or a == "--pause-llm":
      watchAsync = false
      clockModeSet = true
    elif a == "--verbose" or a == "-v":
      gVerbose = true
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
    elif a == "--load-state-path" and i < paramCount():
      inc i
      loadStatePath = paramStr(i)
    elif a.startsWith("--load-state-path="):
      loadStatePath = a[18..^1]
    elif a == "--policy-file" and i < paramCount():
      inc i
      policyFile = paramStr(i)
    elif a.startsWith("--policy-file="):
      policyFile = a[14..^1]
    elif a == "--save-state-slot" and i < paramCount():
      inc i
      saveStateSlot = parseInt(paramStr(i))
    elif a == "--speed" and i < paramCount():
      inc i
      targetSpeed = parseInt(paramStr(i))
    elif a.startsWith("--speed="):
      targetSpeed = parseInt(a[8..^1])
    elif a == "--help" or a == "-h":
      echo "usage: nim r src/tools/llm_ai.nim -- [--frames N] [--llm-interval K] [--png-every M] [--speed N] [--watch-async|--sync-llm|--pause-llm] [--verbose] [--headless] [--mock|--no-mock] [--save-srm | --save-srm=PATH] [--load-state N | --load-state=N] [--load-state-path PATH] [rom]"
      echo "  defaults: --frames 60 --llm-interval 20 --speed 0 ROM=bin/Earthbound (U) [!].smc"
      echo "  windowed by default (opens GL window titled 'EarthBound - LLM (qwen)' for watching)"
      echo "  --headless: no window (for CI / batch); --png-every only dumps when flag is passed"
      echo "  --speed N: pace emulated frames to N fps (0=unlimited/as-fast, 60=realtime)"
      echo "  --watch-async: keep stepping frames while LLM is in-flight (current policy at --speed);"
      echo "                 poll + hot-swap when result lands. DEFAULT for windowed/watch mode."
      echo "  --sync-llm / --pause-llm: pause frame advance until policy applies (deterministic"
      echo "                 apply-at-snapshot). DEFAULT for --headless milestone/CI runs."
      echo "  Tradeoff: async = smooth 60fps watch, policy may land after game state has moved;"
      echo "            sync = freeze while qwen thinks, policy applies at the summary snapshot."
      echo "  --verbose / -v: dump full multi-KB LLM prompts + request JSON (quiet by default)"
      echo "  --mock (default): use canned policy string, no key needed (near-instant)"
      echo "  --no-mock: call real LLM (qwen on azem)"
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
      echo "  To run live: nim r src/tools/llm_ai.nim -- --no-mock --frames 120 --speed 60"
      quit(0)
    elif romPath.len == 0 and not a.startsWith("--"):
      romPath = a
    inc i
  if romPath.len == 0:
    romPath = "bin/Earthbound (U) [!].smc"

  # Default clock mode: windowed/watch -> async (smooth 60fps); headless -> pause-for-consistency.
  if not clockModeSet:
    watchAsync = not useHeadless

  if saveSramEnabled:
    if saveSramPath.len == 0:
      saveSramPath = LlmDefaultSram
    let romSrm = romPath.changeFileExt("srm")
    if saveSramPath == romSrm:
      echo fmt"ERROR: --save-srm path must never resolve to the ROM's .srm: {romSrm} (would touch the user's real save). Refusing."
      quit(1)
    let sdir = saveSramPath.splitFile.dir
    if sdir.len > 0:
      createDir(sdir)
    else:
      createDir("bin")

  ensureLlmStateDir()
  seedLlmBedroomIfMissing()

  let saveStr = if saveSramEnabled: saveSramPath else: "(ephemeral)"
  let loadStr =
    if loadStatePath.len > 0: loadStatePath
    elif loadStateSlot >= 0: llmSlotPath(loadStateSlot)
    else: "none"
  let clockStr = if watchAsync: "watch-async" else: "sync-llm"
  echo fmt"llm_ai: ROM={romPath} frames={maxFrames} llmInterval={llmInterval} pngEvery={pngEvery} (set={pngEverySet}) speed={targetSpeed} mock={useMock} headless={useHeadless} clock={clockStr} verbose={gVerbose} loadState={loadStr} saveSram={saveStr}"
  echo fmt"llm_ai: state namespace = {LlmStateDir}/ (human play slots bin/states/slotN.state never written by default)"
  scenarioPolicy = llm_mock_policies.selectMockPolicy(loadStateSlot)
  if policyFile.len > 0:
    scenarioPolicy = readFile(policyFile)
    echo "POLICY: initial policy from ", policyFile, " (len=", scenarioPolicy.len, ") — overrides mock/nav default"
  createDir("bin")
  createDir("bin/states")
  ensureLlmStateDir()
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
  if loadStatePath.len > 0:
    if isHumanPlaySlotPath(loadStatePath):
      echo fmt"ERROR: refusing human play slot path {loadStatePath}. Use {LlmStateDir}/ fixtures only."
      quit(1)
    if not fileExists(loadStatePath):
      echo fmt"ERROR: --load-state-path {loadStatePath} not found"
      quit(1)
    readStateFile(loadStatePath, snes, cpu)
    echo "loaded start state from path ", loadStatePath
    if "battle" in loadStatePath.toLowerAscii:
      scenarioPolicy = llm_mock_policies.BattlePolicy
    if scenarioPolicy == llm_mock_policies.BattlePolicy:
      let (ok, d) = touch_grass.battleFixtureOk(snes)
      if not ok:
        echo "BATTLE FIXTURE INVALID: ", d
        quit(1)
  elif loadStateSlot >= 0:
    let path = llmSlotPath(loadStateSlot)
    if not fileExists(path):
      echo fmt"ERROR: --load-state {loadStateSlot} is LLM namespace only: missing {path}"
      echo fmt"  Human play: bin/states/slotN.state | LLM: {LlmStateDir}/"
      quit(1)
    readStateFile(path, snes, cpu)
    echo "loaded start state from LLM slot ", loadStateSlot, " <- ", path
    if loadStateSlot == 1:
      scenarioPolicy = llm_mock_policies.BattlePolicy
  else:
    snes.initHdma()

  # Initialize progress trackers from whatever start state we have (fresh boot or loaded).
  # This gives the first slow-tick a sane baseline for pos-delta and tg checks.
  block:
    let pidx = touch_grass.PlayerSlot * touch_grass.SlotIndexStride
    prevPlayerX = touch_grass.readU16(snes, touch_grass.WorldXBase + pidx)
    prevPlayerY = touch_grass.readU16(snes, touch_grass.WorldYBase + pidx)
    prevTg = touch_grass.touchGrassPercent(snes)
    prevRoom = touch_grass.currentRoomLabel(snes)
    prevMoney = touch_grass.readU16(snes, 0x9831)
    # Smoke: prologue story percents (stubs until RE; see docs/llm-sequence.md).
    echo fmt"story_pcts smoke: tg={prevTg} pokey={story_percents.pokeyPercent(snes)} pokey_knock={story_percents.pokeyKnockPercent(snes)} buzzbuzz={story_percents.buzzBuzzPercent(snes)} sunrise={story_percents.sunrisePercent(snes)} room={prevRoom}"

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
  # If absent, SEED by writing Escape+WalkTo+Intro+Win (so escapeMenu/walkTo/winBattle etc in scope).
  # This happens once at boot; skills become globals callable from update().
  # (touch_grass provides the strings; only edit allowed files.)
  if fileExists(SkillsFile):
    let skillSrc = readFile(SkillsFile)
    if loadPolicyChunk(L, skillSrc, "persistent_skills"):
      echo "SKILL_LIBRARY: loaded ", SkillsFile, " (len=", skillSrc.len, ") into sandbox BEFORE policy"
    else:
      echo "SKILL_LIBRARY: WARNING: loadPolicyChunk failed for ", SkillsFile, " (continuing without)"
  else:
    let seedSrc = touch_grass.EscapeMenuSkillLua & "\n\n" & touch_grass.WalkToSkillLua & "\n\n" &
      touch_grass.IntroSkillLua & "\n\n" & touch_grass.WinBattleSkillLua & "\n\n" &
      touch_grass.AdvanceDialogueSkillLua
    writeFile(SkillsFile, seedSrc)
    echo "SKILL_LIBRARY: absent; seeded ", SkillsFile, " (len=", seedSrc.len, ") with Escape+WalkTo+Intro+Win+AdvanceDialogue"
    discard loadPolicyChunk(L, seedSrc, "seeded_skills")
  # Confirm walkTo is callable (from WalkTo seed or prior skills) for verify logs.
  L.getglobal("walkTo".cstring)
  let walkIsFn = (L.getType(-1) == lua53.TFUNCTION)
  L.pop(1)
  if walkIsFn:
    echo "SKILL_LIBRARY: walkTo is callable in the Lua sandbox (confirmed)"
  else:
    echo "SKILL_LIBRARY: walkTo not present as function (policy may still define later)"

  discard getProvider(useMock)  # provider selection now via gUseMock for thread dispatch
  gUseMock = useMock
  workChan.open()
  resultChan.open()
  createThread(workerThread, llmWorkerProc)
  if watchAsync:
    echo "BACKGROUND: worker thread started; --watch-async: frames keep stepping while LLM in-flight; hot-swap on result"
  else:
    echo "BACKGROUND: worker thread started; --sync-llm: pause frames until policy applies (apply-at-snapshot)"

  var currentPolicy: string
  if loadStateSlot >= 0 or loadStatePath.len > 0:
    # loaded state IS the start. Use scenarioPolicy set above (battle for fixture/slot1, nav otherwise).
    # Replaced at first slow tick if needed. Decouples battle win verif from nav.
    currentPolicy = scenarioPolicy
    let kind = if scenarioPolicy == llm_mock_policies.BattlePolicy: "battle" else: "nav"
    echo "initial policy seeded from scenarioPolicy (", kind, ", len=", currentPolicy.len, ")"
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

  let clockDesc = if watchAsync:
    "async: keep stepping current policy while LLM thinks"
  else:
    "sync: pause frames until policy applies"
  echo "starting two-clock loop (fast: per-frame update; slow: LLM every ", llmInterval, " frames; ", clockDesc, ")"
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
  # 0 = unlimited. --speed paces running segments. --sync-llm pauses while pending; --watch-async does not.
  var nextDeadline = getMonoTime()

  # Main loop: policy + step + (optional) GL present. Emulation paced by --speed during run segments.
  # --watch-async: keep stepping with current policy while LLM in-flight; poll+hot-swap each frame.
  # --sync-llm: pause frame advance until policy applies (apply-at-snapshot).
  while ctx.frameCount < maxFrames:
    if (not useHeadless) and blit.window.closeRequested:
      break
    if not useHeadless:
      pollEvents()

    let wasPending = pendingLlm

    let err = policy.runPolicyFrame(L, ctx)
    if err.len > 0:
      echo fmt"policy runtime error frame {ctx.frameCount}: {err}"
      status = "err"

    snes.joy1 = ctx.joy1
    if (ctx.joy1 and policy.BtnRight) != 0:
      echo fmt"  joy1 has RIGHT bit (0x{ctx.joy1:04x}) frame {ctx.frameCount}"

    policy.stepOneFrame(snes, cpu, frameImage)
    ctx.frameCount += 1
    if wasPending:
      framesDuringPending += 1

    # Poll background result every frame (non-blocking). Hot-swap when ready.
    # Async watch path relies on this every-frame poll; sync path also uses it inside pause-wait.
    discard pollAndApplyResult(L, currentPolicy, status, ctx.frameCount)

    # WIRE --speed / AI fps control: pace to target (only when we do advance a frame).
    # After frame, compute next deadline = prev + (1s/fps), sleep remainder to it.
    # If behind by >4 frames worth, reset deadline (clamp backlog, resume without catchup burst/sleep debt).
    # fps=0: skip, run full speed (near-instant for --speed 0).
    # ctx.targetFps read after policy run, so sim.setSpeed(fps) in update() takes effect immediately for next iter.
    # --sync-llm pause-wait bypasses this; --watch-async keeps pacing while thinking.
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
      let pokeyPct = story_percents.pokeyPercent(snes)
      let pokeyKnockPct = story_percents.pokeyKnockPercent(snes)
      let buzzBuzzPct = story_percents.buzzBuzzPercent(snes)
      let sunrisePct = story_percents.sunrisePercent(snes)
      let oldTg = prevTg
      let oldRoom = prevRoom
      if tg > maxTouchGrass:
        maxTouchGrass = tg
      # Only log when progress actually changed, or every ~300 frames as a heartbeat.
      let logSig = fmt"{tg}|{room}|{pokeyPct}|{pokeyKnockPct}|{buzzBuzzPct}|{sunrisePct}"
      if logSig != lastLogSig or (ctx.frameCount mod 300 == 0):
        logTg(fmt"{now()} frame={ctx.frameCount} touch_grass_pct={tg} max={maxTouchGrass} room={room} pokey_pct={pokeyPct} pokey_knock_pct={pokeyKnockPct} buzzbuzz_pct={buzzBuzzPct} sunrise_pct={sunrisePct}")
        lastLogSig = logSig
      if oldTg < 100 and tg >= 100:
        logTg(fmt"TOUCH GRASS ACHIEVED at frame {ctx.frameCount}")
        echo "TOUCH GRASS ACHIEVED!"
        # Campaign handoff: outside → Pokey % seed (docs/llm-sequence.md). ExploreOnett
        # remains available via selectMockPolicyByName for display-only experiments.
        if scenarioPolicy == llm_mock_policies.NavHousePolicy or
            currentPolicy == llm_mock_policies.NavHousePolicy:
          let pokey = llm_mock_policies.PokeyVisitPolicy
          if loadPolicyChunk(L, pokey, "pokey_visit_after_tg100"):
            scenarioPolicy = pokey
            currentPolicy = pokey
            echo "POLICY: tg>=100 — switched seed to PokeyVisitPolicy (Pokey % gate)"
            status = "pokey"
          else:
            echo "POLICY: PokeyVisitPolicy load failed; keeping prior"
      # Read live player pos for *fine-grained* progress (critical after tg plateaus at 75).
      # tg/room only flips on big milestones; inside the house we must detect "still walking toward exit".
      let pidx = touch_grass.PlayerSlot * touch_grass.SlotIndexStride
      let px = touch_grass.readU16(snes, touch_grass.WorldXBase + pidx)
      let py = touch_grass.readU16(snes, touch_grass.WorldYBase + pidx)
      let posDelta = abs(px - prevPlayerX) + abs(py - prevPlayerY)
      let madePosProgress = posDelta > 12   # meaningful world movement since last slow tick

      # Record recent history (last few actions + did tg%/room change since prior LLM tick?)
      # This lets qwen course-correct when stuck (no progress = try different skill/approach).
      let madePokeyProgress = pokeyPct > prevPokey
      let madeTgRoomProgress = (tg > oldTg) or (room != oldRoom) or madePokeyProgress
      let madeProgressForHist = madeTgRoomProgress or madePosProgress
      let progStr = if madeProgressForHist: "PROGRESS" else: "NO_CHANGE"
      let histEntry = fmt"[{ctx.frameCount}] tg {oldTg}->{tg} room {oldRoom}->{room} ({progStr})"
      recentHistory.add(histEntry)
      if recentHistory.len > 6:
        recentHistory = recentHistory[recentHistory.len - 6 .. ^1]

      # Milestone reports on crossing (per docs/llm-plays.md). Capture pos + active policy + git.
      if tg != oldTg or room != oldRoom:
        # px/py already read above for pos progress; reuse for report
        var mname = fmt"tg{oldTg}_to_{tg}_{oldRoom}_to_{room}"
        if oldTg == 25 and tg >= 75: mname = "exit_bedroom_to_house"
        elif oldTg < 100 and tg == 100: mname = "touch_grass_outside"
        elif oldTg == 0 and tg == 25: mname = "enter_bedroom"
        elif (oldTg == 75 or oldTg == 0) and tg == 50: mname = "enter_battle"
        writeMilestoneReport(mname, ctx.frameCount, oldTg, tg, oldRoom, room, px, py, currentPolicy)

        # On real progress (tg up), snapshot under LLM namespace only (never play slots).
        if tg > oldTg:
          try:
            writeStateFile(LlmRollbackState, snes, cpu)
            lastMilestonePath = LlmRollbackState
            stuckCounter = 0
            echo "  SAVED rollback milestone -> ", LlmRollbackState
          except CatchableError as e:
            echo "  save milestone failed: ", e.msg

      # Story-percent milestone: pokey_pct climbs while tg is pinned at 100 outside, so the
      # tg-gated save above never fires on the hill. Snapshot here so a later rollback lands at
      # the doorstep (60/90), not back at outside-start (0).
      if madePokeyProgress:
        try:
          writeStateFile(LlmRollbackState, snes, cpu)
          lastMilestonePath = LlmRollbackState
          stuckCounter = 0
          echo fmt"  SAVED pokey milestone (pokey_pct {prevPokey}->{pokeyPct}) -> {LlmRollbackState}"
        except CatchableError as e:
          echo "  save pokey milestone failed: ", e.msg

      # higher-level stuck detection + rollback using save/load (beyond per-skill wiggle)
      # Use *coarse* (tg/room) + *fine* (live pos delta) + money. This prevents false "stuck" while
      # the agent is successfully walking across house_interior (tg stays 75 until the door).
      let curMoney = touch_grass.readU16(snes, 0x9831)
      let moneyProg = curMoney != prevMoney
      let madeAnyProgress = madeTgRoomProgress or madePosProgress or moneyProg or madePokeyProgress
      if not madeAnyProgress:
        stuckCounter += 1
      else:
        stuckCounter = 0
      # Extra signal for oscillation/yo-yo at door thresholds (tg 25<->75 with bad fixed target policy).
      # Boosts counter so rollback + replan happens sooner instead of endless crossing.
      if tg < oldTg:
        stuckCounter = stuckCounter + 3
        echo "  REGRESSION detected (tg " & $oldTg & "->" & $tg & "); boosting stuck counter"
      prevMoney = curMoney
      prevPokey = pokeyPct
      prevPlayerX = px
      prevPlayerY = py
      if stuckCounter > 18 and lastMilestonePath.len > 0:
        echo fmt"STUCK_DETECTED (counter={stuckCounter}); rolling back to {lastMilestonePath}"
        try:
          readStateFile(lastMilestonePath, snes, cpu)
          snes.joy1 = 0
          ctx.joy1 = 0
          # Reset prev* + pos trackers to post-load values.
          prevTg = touch_grass.touchGrassPercent(snes)
          prevRoom = touch_grass.currentRoomLabel(snes)
          prevMoney = touch_grass.readU16(snes, 0x9831)
          prevPokey = story_percents.pokeyPercent(snes)
          let pidxR = touch_grass.PlayerSlot * touch_grass.SlotIndexStride
          prevPlayerX = touch_grass.readU16(snes, touch_grass.WorldXBase + pidxR)
          prevPlayerY = touch_grass.readU16(snes, touch_grass.WorldYBase + pidxR)
          stuckCounter = 0
          pendingLlm = false
          currentPolicy = scenarioPolicy
          discard loadPolicyChunk(L, currentPolicy, "post_rollback_safe_nav")
          status = "rollback"
        except CatchableError as e:
          echo "rollback load failed: ", e.msg
          stuckCounter = 0

      prevTg = tg
      prevRoom = room

      let doLlmCall = useMock or (tg >= 25)
      if doLlmCall:
        if not pendingLlm:
          status = if watchAsync: "thinking-async" else: "thinking"
          if not useHeadless:
            # Keep last frame visible while we queue the (occasional) LLM call.
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
          # Pass snapshot of notes at send time so worker uses consistent view (no race with appendNote on main).
          workChan.send( (richSummary, currentPolicy, persistentNotes) )
          pendingLlm = true
          let modeLabel = if watchAsync: "async" else: "sync"
          echo fmt"LLM_QUEUED: frame={ctx.frameCount} mode={modeLabel}"
          if not useHeadless:
            blit.blit(frameImage)
            let thinkLabel = if watchAsync: "thinking (async)" else: "waiting policy..."
            blit.window.title = fmt"EarthBound - LLM (qwen) - frame {ctx.frameCount} [{thinkLabel}]"
          if not watchAsync:
            # --sync-llm / --pause-llm: freeze frames until policy applies (apply-at-snapshot).
            # The returned policy matches the summary state at send time — good for milestone CI.
            while pendingLlm:
              discard pollAndApplyResult(L, currentPolicy, status, ctx.frameCount)
              if not pendingLlm:
                break
              sleep(5)
              if not useHeadless:
                pollEvents()
                if blit.window.closeRequested:
                  break
                blit.blit(frameImage)
                blit.window.title = fmt"EarthBound - LLM (qwen) - frame {ctx.frameCount} [waiting policy...]"
          # else --watch-async: do nothing special; main loop keeps stepping current policy
          # and pollAndApplyResult hot-swaps when the worker result lands.
        # else: already pending (async path may still hit next llmInterval while in-flight — skip)
      else:
        # keep running the seeded IntroSkillLua; defer LLM until bedroom
        status = "intro"

    if cpu.stopped:
      echo "cpu stopped; ending run"
      break

  let finalTg = touch_grass.touchGrassPercent(snes)
  if finalTg > maxTouchGrass: maxTouchGrass = finalTg
  let finalPokey = story_percents.pokeyPercent(snes)
  let finalPokeyKnock = story_percents.pokeyKnockPercent(snes)
  let finalBuzz = story_percents.buzzBuzzPercent(snes)
  let finalSunrise = story_percents.sunrisePercent(snes)
  logTg(fmt"{now()} frame={ctx.frameCount} touch_grass_pct={finalTg} max={maxTouchGrass} pokey_pct={finalPokey} pokey_knock_pct={finalPokeyKnock} buzzbuzz_pct={finalBuzz} sunrise_pct={finalSunrise} (final)")
  echo fmt"done: ran {ctx.frameCount} frames. final joy1=0x{snes.joy1:04x} max_touch_grass={maxTouchGrass} pokey_pct={finalPokey} sunrise_pct={finalSunrise}"
  echo fmt"frames_during_pending={framesDuringPending} (frames advanced while LLM request in-flight; async proof when >0)"
  if saveStateSlot >= 0:
    let outPath = llmSlotPath(saveStateSlot)
    writeStateFile(outPath, snes, cpu)
    echo fmt"saved final state to LLM path {outPath} (px=0x{touch_grass.readU16(snes, 0x0BBE):04X} py=0x{touch_grass.readU16(snes, 0x0BFA):04X})"
  if saveSramEnabled and snes.sramDirty:
    saveSram(snes, saveSramPath)
  L.close()
  quit(0)

when isMainModule:
  main()
