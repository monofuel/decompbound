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
  ../decompbound/[cpu, ppu, snesbus, lua53, policy, save_state],
  ./[touch_grass, llm_mock_policies, story_percents, scene, vision_payload]

# windy/glblit only needed for the windowed main loop. Library importers
# (probe_memory_router etc.) skip them so they do not require libGL at load.
when isMainModule:
  import
    windy,
    ./glblit

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
  KnowledgeDir = "../decompbound_secret/knowledge"
    ## Markdown KB outside the public tree (dialogue/NPC facts are game-derived).
    ## -- LEARN routes here; scene names inject reads. Sibling of the repo root.
  KnowledgeBulletCharCap = 800
    ## Max chars of bullet facts injected per named entity KB file.
  KnowledgeMaxFiles = 3
    ## Cap how many named-entity KB files we inject into one summary.
  LearnSectionHeader = "## Learned (bot)"
    ## Section under which -- LEARN [bot] bullets are appended.
  LlmStateDir = "bin/states/llm"
    ## LLM-only savestates. NEVER bin/states/slotN.state (human make-play slots).
  LlmBedroomState = "bin/states/llm/bedroom.state"
  LlmPostKnockState = "bin/states/llm/post_knock.state"
    ## Knock-complete fixture (sleep unreproducible bot-side; signature $99F2=$58).
  LlmPostKnockOutdoorState = "bin/states/llm/post_knock_outdoor.state"
    ## Free outdoor + knock signature (synth_post_knock_outdoor.nim) — playable.
  LlmDefaultSram = "bin/states/llm_ai.srm"

var
  ## Per-process rollback path — concurrent llm_ai runs must not share one file
  ## (parallel day-1 + midgame clobbered each other via bin/states/llm/rollback.state).
  LlmRollbackState* = "bin/states/llm/rollback.state"

proc initLlmRollbackPath*() =
  ## Pin rollback file to this PID so parallel harnesses stay isolated.
  LlmRollbackState = LlmStateDir & "/rollback_" & $getCurrentProcessId() & ".state"

# --- Background LLM provider (threads+channels) for non-blocking two-clock ---
# Main thread owns Lua + Snes exclusively (fast per-frame path never blocks).
# Worker thread only runs the (slow) provider call on (summary, currentLua) and
# returns the new policy string. Hot-swap happens on main when result arrives.
type
  PolicyProvider = proc(summary: string, currentLua: string): string
  ## imageB64: empty = text-only; non-empty PNG base64 when --vision (main encodes frame).
  ProviderWork = tuple[summary, currentLua, notesSnap, imageB64: string]
  ProviderResult = tuple[policy: string, latencyMs: int]

# Forward decls (originals for main-thread use; *Snap versions for worker with snapshot to avoid race on persistentNotes).
proc mockProvider(summary: string, currentLua: string): string
proc realProvider(summary: string, currentLua: string): string
proc mockProviderSnap(summary: string, currentLua: string, notes: string): string
proc realProviderSnap(summary: string, currentLua: string, notes: string, imageB64: string): string

const
  ## Agent product system prompt (docs/grok_play_work.md): perception + intent first.
  ## Dense followRoute trails are Scripted·Turbo referees only — not Agent curriculum.
  AgentSystemPrompt* = """You are an expert at writing compact Lua policies that play EarthBound (SNES decomp harness).

SETTING: You are Ness. A meteor just crashed into the hills above Onett at night. FOLLOW >>> CURRENT_OBJECTIVE in RICH STATE — it advances when milestones complete (once pokey_pct=100, stop re-talking Pokey).

HOW TO PLAY (Agent path — docs/grok_play_work.md):
- PERCEIVE first: SCENE JSON (nearby entities dir/dist/name), screen.text(), optional screenshot when vision is on.
- ACT with intent skills: nearestEntity(), approach(slot|name|dir), talk(slot|name), goToward(landmark name), escapeMenu(), winBattle() if in_battle.
- Prefer talk("pokey") / talk(nearest) over walking hex coordinates.
- Do NOT make followRoute("onett_to_crater") your only outdoor locomotion — that is a Scripted referee trail. Use scene + navTo/goToward/talk; explore and recover when stuck.
- Never press A while walking (opens the command menu). B / escapeMenu() if menu_open.
- Read live dialogue; do not invent plot.

Story ladder (referees, not TAS scripts): tg_pct outside → pokey_pct talk at meteor → pokey_knock home → later checkpoints in checkpoint_spine (docs/checkpoints.md).

SANDBOX API:
- frame(), mem.read(addr), pad.press/set, screen.text(), scene() JSON, sim.setSpeed/fast/normal
- Skills (llm_skills.lua): escapeMenu, walkTo, navTo, followTrail/followRoute (referee/bootstrap only), nearestEntity, approach, talk, goToward, winBattle, advanceDialogue

PERSISTENT BRAIN: -- NOTE: facts; -- LEARN cat:slug fact → knowledge KB. Notes reload each tick.

OUTPUT: ONLY valid Lua starting with 'function update()' and ending with 'end'. No markdown fences.
"""

const
  # qwen3.6-27b is served at full 262144 ctx (~1M chars) — feed the rich brain,
  # don't squeeze it. These are generous backstops against pathological growth,
  # not the old ~26k-window trim. See docs/llm-play-overhaul.md + memory
  # qwen36-llm-play-model ("feed rich input, don't trim").
  NotesCharBudget = 80000     # ~20k tokens of notes/KB; keep last N lines if over
  NotesLineKeep = 400
  PolicyCharBudget = 24000    # ~6k tokens of prior policy

proc trimForLlm(notes, lastPolicy: string): tuple[notesBlock, policyRef: string] =
  ## Pass the notes + LAST POLICY through nearly untouched now that full context
  ## is served; only clamp if they grow pathologically large. Rich STATE +
  ## HISTORY + screen text + instructions are always kept in full.
  var n = notes
  if n.len > NotesCharBudget:
    let ls = n.splitLines()
    if ls.len > NotesLineKeep:
      n = ls[^NotesLineKeep .. ^1].join("\n")
    else:
      n = n[ max(0, n.len-NotesCharBudget) ..< n.len ]
  let nb = if n.len > 0:
    "\n\nPERSISTENT NOTES (full unless pathologically large; also in llm_notes.txt; your brain):\n" & n & "\n(end)\n"
  else:
    "\n\nPERSISTENT NOTES: (no notes yet — use -- NOTE: lines in policy output to build knowledge base)\n"
  var p = lastPolicy
  if p.len > PolicyCharBudget:
    let h = p[0 ..< min(4000, p.len)]
    let t = if p.len > 4000: p[ max(0, p.len-8000) ..< p.len ] else: ""
    p = h & "\n...[trimmed " & $(p.len - 4000 - 8000) & " middle chars; see FULL log or file]...\n" & t
  (nb, p)

proc sceneLua(L: lua53.PState): cint {.cdecl.} =
  ## Lua: scene() -> compact JSON of nearby entities (relative dir + tiles),
  ## player pos/room, and on-screen text. Lets policies branch on live
  ## perception instead of hardcoded coordinates. See src/tools/scene.nim.
  ## App-level binding (scene.nim is in tools and imports policy, so it can't
  ## live in policy.setupPolicyApi without a circular dep — registered here).
  let ctx = policy.getPolicyCtx(L)
  L.pushstring(scene.sceneJson(ctx.snes).cstring)
  return 1

proc landmarkTargetLua(L: lua53.PState): cint {.cdecl.} =
  ## Lua: landmarkTarget(name) -> x, y  (two ints) or nil if not a landmark of
  ## the current area. Powers coordinate-free travel: goToward(name) resolves the
  ## name here (engine map data) and navTo's it — no coord ever in the policy.
  let ctx = policy.getPolicyCtx(L)
  let t = scene.landmarkTarget(ctx.snes, $L.toString(1))
  if not t.found:
    L.pushnil()
    return 1
  L.pushinteger(t.x)
  L.pushinteger(t.y)
  return 2

var
  workChan: Channel[ProviderWork]
  resultChan: Channel[ProviderResult]
  workerThread: Thread[void]
  gUseMock: bool            # set at startup; worker dispatches without storing proc (GC-safety)
  gVerbose = false          # --verbose: dump full multi-KB prompts / request JSON
  gVision = false           # --vision: attach rendered frame PNG to each LLM request
  pendingLlm = false        # true while a request is in flight (prevents duplicate queueing)
  framesDuringPending = 0   # frames advanced while a request was in-flight (async proof)
  stuckThreshold = 18       # slow-ticks without progress before STUCK recovery
  stuckRecoveryCount = 0    # how many recoveries fired this run (probes assert >0)
  campaignFixtures = false  # --campaign-fixtures: load post_knock when sleep unreproducible

proc llmWorkerProc() {.thread.} =
  ## Worker: loops, receives work nonblockingly, executes the provider (HTTP or mock) using SNAPSHOT of notes.
  ## sends result back. Never touches L, ctx, snes, or frameImage. Snapshot prevents data race with main's appendNote.
  ## imageB64 is pre-encoded on main from frameImage when --vision is set.
  while true:
    let (hasWork, work) = workChan.tryRecv()
    if hasWork:
      let t0 = now()
      let policy =
        block:
          {.gcsafe.}:
            if gUseMock:
              mockProviderSnap(work.summary, work.currentLua, work.notesSnap)
            else:
              realProviderSnap(work.summary, work.currentLua, work.notesSnap, work.imageB64)
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
  # Milestone completion LATCHES — the story percents are live (position+flag)
  # gauges that UN-latch when Ness leaves (e.g. pokeyPercent drops below 100 the
  # moment he walks away from Pokey to head home). Latch each once seen complete
  # so the objective advances forward and never snaps back to a finished goal.
  tgDone = false
  pokeyDone = false
  # Once Pokey is talked (pokey_pct=100) the objective flips to HEAD HOME. In that
  # phase pokey_pct DROPS as Ness walks away (expected, not regression) and
  # progress is measured by pokey_knock_pct climbing instead. knockPhase re-points
  # the rollback anchor + stuck detector at the home leg so they stop dragging
  # Ness back to the crater.
  knockPhase = false
  prevKnock = 0
  prevFrank = 0
  prevCaptain = 0
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
  ## Thin wrapper: text-only call (no frame on main-thread sync path).
  ## Live path uses the worker + realProviderSnap with optional vision bytes.
  realProviderSnap(summary, currentLua, persistentNotes, "")

proc realProviderSnap(summary: string, currentLua: string, notes: string, imageB64: string): string =
  ## Real LLM call via direct HTTP (reasoning_content + optional vision frame).
  ## imageB64 non-empty: multimodal user content (OpenAI image_url data URL).
  ## max_tokens=4096 OUTPUT; vision uses AgentSystemPrompt (intent-first, no TAS trail).
  let t0 = now()
  let (notesBlock, policyRef) = trimForLlm(notes, currentLua)
  let userPrompt = fmt"""RICH STATE + RECENT HISTORY + ON-SCREEN TEXT:
{summary}
{notesBlock}
LAST POLICY (reference; you may incrementally improve or replace the update body):
{policyRef}

Return ONLY the 'function update() ... end' block (nothing else). Prefer scene/talk/approach/goToward over followRoute. Call escapeMenu/walkTo/winBattle as needed. /no_think"""

  let fullContextForLog = "SYSTEM:\n" & AgentSystemPrompt & "\n\nUSER:\n" & userPrompt
  let ctxChars = fullContextForLog.len
  let approxTokens = ctxChars div 4
  let visionStats = visionPayloadStats(imageB64)
  if gVerbose:
    echo "=== FULL LLM CONTEXT SENT (trimmed for ctx; rich state kept) ==="
    echo fullContextForLog
    echo "=== END CONTEXT (chars=", ctxChars, " approx_tokens~", approxTokens, " vision=", visionStats, ") ==="
  else:
    echo fmt"LLM_REQUEST: chars={ctxChars} approx_tokens~{approxTokens} vision={visionStats} (pass --verbose for full prompt dump)"

  var raw: string
  var reas: string
  var finishReason = ""
  let url = AzemBaseUrl & "/chat/completions"
  let messages = chatMessagesWithOptionalVision(AgentSystemPrompt, userPrompt, imageB64)
  let imageParts = countImageParts(messages)
  echo fmt"VISION_PAYLOAD: {visionStats} image_parts_in_messages={imageParts}"
  let body = %* {
    "model": PolicyModel,
    "max_tokens": 4096,
    "temperature": 0.2,
    "messages": messages
  }
  if gVerbose:
    # Full base64 would flood the log — print structure stats only.
    echo "=== REQUEST (vision base64 redacted) endpoint=", url, " image_parts=", imageParts, " ==="
    echo "system_chars=", AgentSystemPrompt.len, " user_chars=", userPrompt.len
  try:
    let client = newHttpClient(timeout = 600_000)
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
  echo fmt"LLM_LATENCY: latency_ms={dt} (direct http + max_tokens=4096 + vision_parts={imageParts}; finish={finishReason})"

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

proc learnCatDir(cat: string): string =
  ## Map LEARN category tokens to KB subdirs under KnowledgeDir (npc→npcs, …). Empty if unknown.
  case cat.toLowerAscii()
  of "npc": "npcs"
  of "enemy": "enemies"
  of "place": "places"
  of "mechanic": "mechanics"
  else: ""

proc appendLearnFact*(cat, slug, fact: string): bool =
  ## Append one [bot] fact under KnowledgeDir/<cat>s/<slug>.md (## Learned (bot)).
  ## Creates a minimal frontmatter file when missing. Skips identical [bot] bullets.
  ## Returns true when a new bullet was written.
  result = false
  let dir = learnCatDir(cat)
  if dir.len == 0 or slug.len == 0 or fact.len == 0: return
  let safeSlug = slug.toLowerAscii().strip()
  let kind = cat.toLowerAscii()
  let path = KnowledgeDir / dir / (safeSlug & ".md")
  let bullet = "- " & fact & " [bot]"
  createDir(KnowledgeDir / dir)
  if fileExists(path):
    let existing = readFile(path)
    # De-dup: identical [bot] bullet already present.
    for raw in existing.splitLines():
      if raw.strip() == bullet: return
    var body = existing
    if not body.endsWith("\n"):
      body.add("\n")
    if LearnSectionHeader notin body:
      body.add("\n" & LearnSectionHeader & "\n")
    body.add(bullet & "\n")
    writeFile(path, body)
  else:
    let content = &"""---
name: {safeSlug}
kind: {kind}
---
# {safeSlug}

{LearnSectionHeader}
{bullet}
"""
    writeFile(path, content)
  echo "  LEARN recorded: ", cat, ":", safeSlug, " → ", path, " :: ", fact
  result = true

proc extractAndAppendLearns*(src: string) =
  ## Parse `-- LEARN <cat>:<slug> <fact text>` lines and route into KnowledgeDir.
  ## Categories: npc, enemy, place, mechanic. Called alongside extractAndAppendNotes.
  if src.len == 0: return
  var count = 0
  for raw in src.splitLines():
    let line = raw.strip()
    # Accept "-- LEARN " or "--LEARN " (space after LEARN required before cat:slug).
    var rest = ""
    if line.startsWith("-- LEARN "):
      rest = line["-- LEARN ".len .. ^1].strip()
    elif line.startsWith("--LEARN "):
      rest = line["--LEARN ".len .. ^1].strip()
    else:
      continue
    # rest = "<cat>:<slug> <fact text>"
    let colon = rest.find(':')
    if colon <= 0: continue
    let cat = rest[0 ..< colon].strip()
    let after = rest[colon+1 .. ^1].strip()
    if after.len == 0: continue
    let sp = after.find(' ')
    if sp <= 0:
      continue
    let slug = after[0 ..< sp].strip()
    let fact = after[sp+1 .. ^1].strip()
    if slug.len == 0 or fact.len == 0: continue
    if learnCatDir(cat).len == 0: continue
    if appendLearnFact(cat, slug, fact):
      inc count
  if count > 0:
    echo "  extracted ", count, " -- LEARN record(s) into ", KnowledgeDir

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

proc kbBulletLines(path: string, maxChars: int): string =
  ## Collect markdown bullet facts from a KB file (with wrapped continuations), capped.
  if not fileExists(path): return ""
  var bullets: seq[string] = @[]
  var cur = ""
  for raw in readFile(path).splitLines():
    if raw.startsWith("- "):
      if cur.len > 0: bullets.add(cur)
      cur = raw.strip()
    elif cur.len > 0 and (raw.startsWith("  ") or raw.startsWith("\t")):
      # Continuation of a wrapped bullet — fold into one fact line.
      cur.add(" " & raw.strip())
    else:
      if cur.len > 0:
        bullets.add(cur)
        cur = ""
  if cur.len > 0: bullets.add(cur)
  var acc = ""
  for b in bullets:
    let next = if acc.len == 0: b else: acc & "\n" & b
    if next.len > maxChars:
      if acc.len == 0:
        # Single long bullet: hard-cap so one file cannot blow the budget.
        acc = b[0 ..< min(b.len, maxChars)]
      break
    acc = next
  acc

proc knowledgeInjection*(snes: SnesBus): string =
  ## Build the KNOWLEDGE prompt block for named entities currently in the scene.
  ## Looks up KnowledgeDir/npcs/<name>.md for each non-empty entity name (cap files + chars).
  let sc = scene.buildScene(snes)
  var seen: seq[string] = @[]
  var chunks: seq[string] = @[]
  for e in sc.ents:
    if e.name.len == 0: continue
    let key = e.name.toLowerAscii()
    if key in seen: continue
    seen.add(key)
    if chunks.len >= KnowledgeMaxFiles: break
    let path = KnowledgeDir / "npcs" / (key & ".md")
    let bullets = kbBulletLines(path, KnowledgeBulletCharCap)
    if bullets.len == 0: continue
    chunks.add(&"[{key}]\n{bullets}")
  if chunks.len == 0: return ""
  "KNOWLEDGE (what you know about who's nearby):\n" & chunks.join("\n\n") & "\n"

proc buildStateSummary*(ctx: policy.PolicyContext): string =
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

  # DYNAMIC OBJECTIVE — advances with latched milestones. Agent path: SCENE +
  # intent skills (docs/grok_play_work.md). Do NOT require followRoute trails.
  if tgPct >= 100: tgDone = true
  if pokeyPct >= 100: pokeyDone = true
  let objective =
    if not tgDone:
      "GET OUTSIDE. You're Ness in your bedroom after a meteor — use scene() + walkTo/navTo indoors, escapeMenu if needed, leave via the front door. Target tg_pct=100. No fights."
    elif not pokeyDone:
      "FIND POKEY AT THE METEOR. Use SCENE landmarks/entities (goToward names, approach/talk). Prefer talk('pokey') or talk(nearest) when he appears — READ screen.text(). Do NOT treat followRoute as the only way; explore with perception. Don't enter the Minch house as the goal. Target pokey_pct=100."
    elif pokeyKnockPct < 80:
      "HEAD HOME. Pokey sent you home — navigate by scene landmarks (ness_home_door) and talk('mom') at the door if present; then upstairs to bed. Target pokey_knock_pct=80."
    else:
      "AT BED (knock=80). Hold safely (escapeMenu); sleep→knock 100 not fully bot-triggerable yet."

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

  # Structured scene (perception channel #2) — what's around Ness in RELATIVE
  # terms (direction + tiles), so the bot navigates by intent, not coordinates.
  let sceneStr = scene.sceneJson(ctx.snes)
  # Relevant KB entries for named entities currently nearby (read half of memory).
  let kbBlock = knowledgeInjection(ctx.snes)
  let kbLine = if kbBlock.len > 0: "\n" & kbBlock else: ""

  let spine = story_percents.checkpointSpineLine(ctx.snes)
  result = fmt"""RICH LABELED STATE:
>>> CURRENT_OBJECTIVE: {objective}
SCENE (nearby entities are relative to you — head toward/away by direction, not raw coords): {sceneStr}{kbLine}
touch_grass_pct: {tgPct}
pokey_pct: {pokeyPct}
pokey_knock_pct: {pokeyKnockPct}
buzzbuzz_pct: {buzzBuzzPct}
sunrise_pct: {sunrisePct}
{spine}
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
  # Battle-relevant fields always present so fight arcs are not pure blind A-spam.
  # When not in battle, values are explicit zeros / empty (honest empty, not omitted).
  let battleFlag = safeR8(BattleOff)
  let battleTextRaw = if inBattle == "yes": screenForMenu.replace("\n", " ") else: ""
  let battleTextShow =
    if battleTextRaw.len == 0: "(none)"
    else: battleTextRaw[0 ..< min(120, battleTextRaw.len)]
  let battleCmd = if whichMenu == "battle_command": "yes" else: "no"
  result.add &"""
battle_flag_$4DBA: {battleFlag}
battle_command_menu: {battleCmd}
battle_screen_text: {battleTextShow}
party_hp_pp: {hpCur}/{hpMax} hp, {ppCur}/{ppMax} pp
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
    extractAndAppendLearns(newP)
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

when isMainModule:
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
    var scenarioName = ""
      ## Named seed scenario (--scenario nav|battle|explore|pokey); overrides slot mapping.
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
      # Track matrix (docs/llm-play-overhaul.md): --pilot PILOT --tempo TEMPO.
      # Convenience over the raw --mock/--headless/--speed flags below.
      elif (a == "--pilot" and i < paramCount()) or a.startsWith("--pilot="):
        let v = (if a == "--pilot": (inc i; paramStr(i)) else: a[8 .. ^1]).toLowerAscii()
        case v
        of "scripted", "tas": useMock = true        # deterministic seed Lua
        of "agent", "llm": useMock = false           # qwen writes Lua live
        else: echo "unknown --pilot '", v, "' (use scripted|agent)"
      elif (a == "--tempo" and i < paramCount()) or a.startsWith("--tempo="):
        let v = (if a == "--tempo": (inc i; paramStr(i)) else: a[8 .. ^1]).toLowerAscii()
        case v
        of "theater": useHeadless = false; targetSpeed = 60   # watch, ~60fps + window
        of "turbo": useHeadless = true; targetSpeed = 0        # headless, uncapped
        of "adaptive": useHeadless = false; targetSpeed = 60   # window; policy drives fps via sim.setSpeed
        else: echo "unknown --tempo '", v, "' (use theater|turbo|adaptive)"
      elif a == "--watch-async":
        watchAsync = true
        clockModeSet = true
      elif a == "--sync-llm" or a == "--pause-llm":
        watchAsync = false
        clockModeSet = true
      elif a == "--verbose" or a == "-v":
        gVerbose = true
      elif a == "--vision":
        gVision = true
      elif a == "--no-vision":
        gVision = false
      elif a == "--stuck-threshold" and i < paramCount():
        inc i
        stuckThreshold = parseInt(paramStr(i))
      elif a.startsWith("--stuck-threshold="):
        stuckThreshold = parseInt(a[18 .. ^1])
      elif a == "--campaign-fixtures":
        campaignFixtures = true
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
      elif a == "--scenario" and i < paramCount():
        inc i
        scenarioName = paramStr(i)
      elif a.startsWith("--scenario="):
        scenarioName = a[11..^1]
      elif a == "--save-state-slot" and i < paramCount():
        inc i
        saveStateSlot = parseInt(paramStr(i))
      elif a == "--speed" and i < paramCount():
        inc i
        targetSpeed = parseInt(paramStr(i))
      elif a.startsWith("--speed="):
        targetSpeed = parseInt(a[8..^1])
      elif a == "--help" or a == "-h":
        echo "usage: nim r src/tools/llm_ai.nim -- [--pilot scripted|agent] [--tempo theater|turbo|adaptive] [--frames N] [--llm-interval K] [--png-every M] [--speed N] [--watch-async|--sync-llm|--pause-llm] [--verbose] [--vision] [--headless] [--mock|--no-mock] [--save-srm | --save-srm=PATH] [--load-state N | --load-state=N] [--load-state-path PATH] [rom]"
        echo "  TRACK MATRIX: --pilot scripted (deterministic seed Lua) | agent (qwen live);  --tempo theater (60fps+window) | turbo (headless uncapped) | adaptive (policy-driven fps). See docs/llm-play-overhaul.md + docs/grok_play_work.md."
        echo "  defaults: --frames 60 --llm-interval 20 --speed 0 ROM=bin/Earthbound (U) [!].smc"
        echo "  windowed by default (opens GL window titled 'EarthBound - LLM (qwen)' for watching)"
        echo "  --vision: attach rendered frame PNG to each LLM request (qwen multimodal; slow — sparse use)"
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
    initLlmRollbackPath()

    let saveStr = if saveSramEnabled: saveSramPath else: "(ephemeral)"
    let loadStr =
      if loadStatePath.len > 0: loadStatePath
      elif loadStateSlot >= 0: llmSlotPath(loadStateSlot)
      else: "none"
    let clockStr = if watchAsync: "watch-async" else: "sync-llm"
    let pilotName = if useMock: "Scripted" else: "Agent"
    let tempoName = if useHeadless: "Turbo" elif targetSpeed == 0: "Turbo(win)" else: "Theater"
    echo fmt"llm_ai TRACK: {pilotName}·{tempoName}"
    echo fmt"llm_ai: ROM={romPath} frames={maxFrames} llmInterval={llmInterval} pngEvery={pngEvery} (set={pngEverySet}) speed={targetSpeed} mock={useMock} headless={useHeadless} clock={clockStr} verbose={gVerbose} vision={gVision} loadState={loadStr} saveSram={saveStr}"
    echo fmt"llm_ai: state namespace = {LlmStateDir}/ (human play slots bin/states/slotN.state never written by default)"
    echo "llm_ai: Agent path uses scene/intent skills (docs/grok_play_work.md); followRoute trails are Scripted referee-only"
    scenarioPolicy = llm_mock_policies.selectMockPolicy(loadStateSlot)
    if scenarioName.len > 0:
      # Named scenario seed (nav/battle/explore/pokey) — overrides slot mapping.
      scenarioPolicy = llm_mock_policies.selectMockPolicyByName(scenarioName)
      echo "POLICY: scenario=", scenarioName, " seed selected (len=", scenarioPolicy.len, ")"
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
      # Prefer spine seed that matches loaded fixture (before first walk drops soft py).
      # Free midgame+deep fo60 snaps north under midgame explore before slow-tick handoff.
      if scenarioName.len == 0 or scenarioName.toLowerAscii() in
          ["midgame", "agentmidgame", "winters", "belch", "desert", "fourside",
           "agentfourside", "fo60", "fourside60", "late", "agentlate", "poo"]:
        let fo0 = story_percents.foursidePercent(snes)
        let ma0 = story_percents.magicantPercent(snes)
        let w0 = story_percents.wintersPercent(snes)
        if fo0 >= 80 or ma0 >= 30:
          scenarioPolicy = llm_mock_policies.AgentLateGamePolicy
          echo "POLICY: load-state fo=", fo0, " ma=", ma0, " → AgentLateGamePolicy"
        elif fo0 >= 60 and w0 >= 50:
          scenarioPolicy = llm_mock_policies.AgentFoursideApproachPolicy
          echo "POLICY: load-state fo=", fo0, " winters=", w0, " → AgentFoursideApproachPolicy"
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
      prevFrank = story_percents.frankPercent(snes)
      prevCaptain = story_percents.captainStrongPercent(snes)
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
    # scene() — structured perception (nearby entities relative to Ness). Bound at
    # app level because scene.nim (tools) imports policy; see sceneLua above.
    L.pushcfunction(sceneLua)
    L.setglobal("scene".cstring)
    # landmarkTarget(name) -> x,y — resolves a named place to a nav target so
    # goToward(name) can travel coordinate-free (engine holds the map).
    L.pushcfunction(landmarkTargetLua)
    L.setglobal("landmarkTarget".cstring)

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
    extractAndAppendLearns(currentPolicy)

    let clockDesc = if watchAsync:
      "async: keep stepping current policy while LLM thinks"
    else:
      "sync: pause frames until policy applies"
    echo "starting two-clock loop (fast: per-frame update; slow: LLM every ", llmInterval, " frames; ", clockDesc, ")"
    if not useHeadless:
      echo "  windowed mode: a separate GL window will show the LLM-driven play (no keyboard input; policy controls joy1)"
    else:
      echo "  headless mode (no window)"

    # Arm stuck recovery from the start state so long campaigns always have a checkpoint.
    try:
      writeStateFile(LlmRollbackState, snes, cpu)
      lastMilestonePath = LlmRollbackState
      echo fmt"STUCK_ANCHOR: armed initial state -> {LlmRollbackState} (threshold={stuckThreshold} slow-ticks)"
    except CatchableError as e:
      echo "STUCK_ANCHOR failed: ", e.msg

    var maxTouchGrass = touch_grass.touchGrassPercent(snes)
    var maxPokey = story_percents.pokeyPercent(snes)
    var maxKnock = story_percents.pokeyKnockPercent(snes)
    # Latch soft-ceiling peaks at load (free walk can drop bitpop before first slow tick).
    var maxMagicant = story_percents.magicantPercent(snes)
    var maxGiygas = story_percents.giygasPercent(snes)
    var maxFourside = story_percents.foursidePercent(snes)
    var maxFrank = story_percents.frankPercent(snes)
    var maxGiant = story_percents.giantStepPercent(snes)
    var maxCaptain = story_percents.captainStrongPercent(snes)
    var pokeyAchievedFrame = -1
    if maxMagicant >= 95 or maxFourside >= 60 or maxCaptain >= 40:
      echo fmt"LATCH_START max_frank={maxFrank} max_giant={maxGiant} max_captain={maxCaptain} " &
        fmt"max_fourside={maxFourside} max_magicant={maxMagicant} max_giygas={maxGiygas}"
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
        if pokeyPct > maxPokey:
          maxPokey = pokeyPct
        if pokeyKnockPct > maxKnock:
          maxKnock = pokeyKnockPct
        let magLatch = story_percents.magicantPercent(snes)
        let giyLatch = story_percents.giygasPercent(snes)
        let foLatch = story_percents.foursidePercent(snes)
        let frLatch = story_percents.frankPercent(snes)
        let gsLatch = story_percents.giantStepPercent(snes)
        let csLatch = story_percents.captainStrongPercent(snes)
        if magLatch > maxMagicant: maxMagicant = magLatch
        if giyLatch > maxGiygas: maxGiygas = giyLatch
        if foLatch > maxFourside: maxFourside = foLatch
        if frLatch > maxFrank: maxFrank = frLatch
        if gsLatch > maxGiant: maxGiant = gsLatch
        if csLatch > maxCaptain: maxCaptain = csLatch
        # Campaign fixture handoff: bot cannot trigger sleep→knock from pre_knock
        # bedroom (verified). When knock latches at 80 and --campaign-fixtures is
        # on, advance via the verified post_knock state (signature → knock 100).
        if campaignFixtures and pokeyKnockPct >= 80 and pokeyKnockPct < 100 and
            not story_percents.knockComplete(snes):
          # Prefer free outdoor synth (playable); fall back to locked indoor post_knock.
          let segPath =
            if fileExists(LlmPostKnockOutdoorState): LlmPostKnockOutdoorState
            elif fileExists(LlmPostKnockState): LlmPostKnockState
            else: ""
          if segPath.len > 0:
            echo "CAMPAIGN_SEGMENT: sleep→knock unreproducible bot-side; loading ",
              segPath, " (knock-complete signature)"
            try:
              readStateFile(segPath, snes, cpu)
              snes.joy1 = 0
              ctx.joy1 = 0
              let kn = story_percents.pokeyKnockPercent(snes)
              let tgSeg = touch_grass.touchGrassPercent(snes)
              echo fmt"CAMPAIGN_SEGMENT: after load knock={kn} complete={story_percents.knockComplete(snes)} tg={tgSeg}"
              if kn >= 100:
                maxKnock = kn
                knockPhase = true
                # Story order (llm-sequence): knock → Buzz/meteor → sunrise → day-1 Frank.
                # Outdoor free → AgentBuzzBuzz first; indoor locked → Buzz exit attempt.
                let nextPol = llm_mock_policies.AgentBuzzBuzzPolicy
                if loadPolicyChunk(L, nextPol, "agent_buzz_after_knock100"):
                  scenarioPolicy = nextPol
                  currentPolicy = nextPol
                  echo "POLICY: knock=100 — AgentBuzzBuzzPolicy (meteor/Buzz before Frank)"
                stuckCounter = 0
                writeStateFile(LlmRollbackState, snes, cpu)
                lastMilestonePath = LlmRollbackState
            except CatchableError as e:
              echo "CAMPAIGN_SEGMENT load failed: ", e.msg
        # Latch the Pokey achievement: reaching Pokey and talking is a milestone;
        # the post-talk scene moves the player so pokey_pct falls back — don't let
        # that read as regression / trigger a rollback that undoes the win.
        if pokeyPct >= 100 and pokeyAchievedFrame < 0:
          pokeyAchievedFrame = ctx.frameCount
          logTg(fmt"POKEY ACHIEVED at frame {ctx.frameCount} (talked to Pokey at the meteor)")
          echo "POKEY ACHIEVED!"
          # Campaign handoff: Pokey talked → HEAD HOME seed (the missing leg that
          # left the bot mashing talk at the crater forever — there was no route
          # away). Switch to PokeyKnockPolicy, which rides followRoute("crater_to_
          # onett") back to the door. Only auto-advance from the Pokey seed so a
          # human-chosen scenario / qwen policy isn't clobbered.
          # Scripted referee: PokeyVisit → PokeyKnock trail seeds.
          # Agent product: intent-only AgentOutdoorPolicy (no followRoute handoff).
          if useMock and scenarioPolicy == llm_mock_policies.PokeyVisitPolicy:
            let knock = llm_mock_policies.PokeyKnockPolicy
            if loadPolicyChunk(L, knock, "pokey_knock_after_pokey100"):
              scenarioPolicy = knock
              currentPolicy = knock
              knockPhase = true
              lastMilestonePath = ""
              prevKnock = pokeyKnockPct
              stuckCounter = 0
              echo "POLICY: pokey_pct>=100 — Scripted seed PokeyKnockPolicy (HEAD HOME referee)"
              status = "knock"
            else:
              echo "POLICY: PokeyKnockPolicy load failed; keeping prior"
          elif (not useMock) or scenarioPolicy == llm_mock_policies.AgentOutdoorPolicy:
            # Agent product (live or mock agent outdoor): hand off to HEAD HOME seed.
            knockPhase = true
            let agentHome = llm_mock_policies.AgentHomePolicy
            if loadPolicyChunk(L, agentHome, "agent_home_after_pokey100"):
              scenarioPolicy = agentHome
              currentPolicy = agentHome
              lastMilestonePath = ""
              prevKnock = pokeyKnockPct
              stuckCounter = 0
              echo "POLICY: pokey_pct>=100 — AgentHomePolicy (goHome/talk; no followRoute)"
              status = "knock"
        # Buzz site progress → Frank. Prefer door south peel if already mid-town
        # (campaign Buzz path often hits frank 50–60 before handoff; FromMeteor then
        # homes north and undoes it — d41 campaign stuck frank50/pokey80 for 8k frames).
        let buzzPctNow = story_percents.buzzBuzzPercent(snes)
        if buzzPctNow >= 80 and
            (scenarioPolicy == llm_mock_policies.AgentBuzzBuzzPolicy or
              currentPolicy == llm_mock_policies.AgentBuzzBuzzPolicy):
          let frNow = story_percents.frankPercent(snes)
          # Campaign: free walk from live meteor/west wall rarely re-hits frank 80;
          # load proven downtown corridor (same class as fo40→fo60 fixture wall).
          const LlmFrankDowntown = "bin/states/llm/frank_downtown.state"
          if campaignFixtures and fileExists(LlmFrankDowntown) and maxFrank < 80:
            echo "CAMPAIGN_SEGMENT: buzz done; loading ", LlmFrankDowntown, " (frank deep south)"
            try:
              readStateFile(LlmFrankDowntown, snes, cpu)
              snes.joy1 = 0
              ctx.joy1 = 0
              let frSeg = story_percents.frankPercent(snes)
              echo "CAMPAIGN_SEGMENT: after load frank=", frSeg
              if frSeg > maxFrank: maxFrank = frSeg
              stuckCounter = 0
            except CatchableError as e:
              echo "CAMPAIGN_SEGMENT frank load failed: ", e.msg
          let frankPol =
            if frNow >= 50 or campaignFixtures: llm_mock_policies.AgentFrankPolicy
            else: llm_mock_policies.AgentFrankFromMeteorPolicy
          let frankLabel =
            if frankPol == llm_mock_policies.AgentFrankPolicy: "agent_frank_door_after_buzz80"
            else: "agent_frank_from_meteor_after_buzz80"
          if loadPolicyChunk(L, frankPol, frankLabel):
            scenarioPolicy = frankPol
            currentPolicy = frankPol
            stuckCounter = 0
            if frankPol == llm_mock_policies.AgentFrankPolicy:
              echo "POLICY: buzz>=80 — AgentFrankPolicy (south peel / campaign downtown)"
            else:
              echo "POLICY: buzz>=80 frank=", frNow, " — AgentFrankFromMeteorPolicy (home then south)"
            status = "frank"
        # Day-1 → Giant Step when Frank hits deep south (frank>=80). Handoff at 60
        # aborted frankmeteor deep peel before cs 60 (d41 max_frank=60 max_cs=50).
        let frankPctNow = story_percents.frankPercent(snes)
        if frankPctNow >= 80 and
            (scenarioPolicy == llm_mock_policies.AgentFrankPolicy or
              currentPolicy == llm_mock_policies.AgentFrankPolicy or
              scenarioPolicy == llm_mock_policies.AgentFrankFromMeteorPolicy or
              currentPolicy == llm_mock_policies.AgentFrankFromMeteorPolicy):
          let giantPol = llm_mock_policies.AgentGiantStepPolicy
          if loadPolicyChunk(L, giantPol, "agent_giant_after_frank80"):
            scenarioPolicy = giantPol
            currentPolicy = giantPol
            stuckCounter = 0
            echo "POLICY: frank>=80 — AgentGiantStepPolicy (next checkpoints.md referee)"
            status = "giant_step"
        # Giant approach → Captain Strong west/south police-edge soft ladder.
        let giantPctNow = story_percents.giantStepPercent(snes)
        if giantPctNow >= 50 and
            (scenarioPolicy == llm_mock_policies.AgentGiantStepPolicy or
              currentPolicy == llm_mock_policies.AgentGiantStepPolicy):
          let capPol = llm_mock_policies.AgentCaptainStrongPolicy
          if loadPolicyChunk(L, capPol, "agent_captain_after_giant50"):
            scenarioPolicy = capPol
            currentPolicy = capPol
            stuckCounter = 0
            echo "POLICY: giant_step>=50 — AgentCaptainStrongPolicy (police/exit soft)"
            status = "captain_strong"
        # Captain south commercial (cs 60 = py>=0x02A0) → soft Paula/Twoson.
        # Require 60: handoff at 50 (west lane only) let live cs drop to 40 and thrash
        # (d39 day-1 free-play); product frank alone already climbs to cs 60 (d40 multileg).
        let captainPctNow = story_percents.captainStrongPercent(snes)
        # d57: Live later-story leave soft without party or fixture reload.
        # Night pos ladder tops at cs60 ($99F2=$58). F12-proven $99F2=C4 alone →
        # captain 70 (Ness-only). Campaign path applies C4 once night cs latched.
        if campaignFixtures and maxCaptain >= 60 and
            story_percents.knockComplete(snes) and
            not story_percents.laterStoryLeaveSoft(snes):
          story_percents.applyLaterStoryLeaveSoft(snes)
          let csAfter = story_percents.captainStrongPercent(snes)
          if csAfter > maxCaptain: maxCaptain = csAfter
          echo "CAMPAIGN_LIVE: later-story $99F2=C4 leave soft (no party synth) cs=",
            csAfter
          stuckCounter = 0
          status = "leave_soft"
        # Hold later-story byte if game rewrites during walk (same class as knock sig).
        if campaignFixtures and story_percents.laterStoryLeaveSoft(snes) and
            readU8(snes, story_percents.KnockCompleteOff) !=
              story_percents.LaterStoryLeaveVal:
          story_percents.applyLaterStoryLeaveSoft(snes)
        if captainPctNow >= 60 and
            (scenarioPolicy == llm_mock_policies.AgentCaptainStrongPolicy or
              currentPolicy == llm_mock_policies.AgentCaptainStrongPolicy):
          let paulaPol = llm_mock_policies.AgentPaulaApproachPolicy
          if loadPolicyChunk(L, paulaPol, "agent_paula_after_captain60"):
            scenarioPolicy = paulaPol
            currentPolicy = paulaPol
            stuckCounter = 0
            echo "POLICY: captain>=", captainPctNow,
              " — AgentPaulaApproachPolicy (Twoson soft after cs60)"
            status = "paula"
        # d60: after live C4, night map sticks at py~0x02A0. Prefer day-leave map
        # seat (captain 100, no party) before Paula-join midgame fixture.
        const
          LlmLeaveDay1Map = "bin/states/llm/leave_day1_map.state"
          LlmLeavePaulaJoin = "bin/states/llm/leave_onett_walkable.state"
          LlmFourside60AfterLeave = "bin/states/llm/fourside60_walkable.state"
        if campaignFixtures and story_percents.laterStoryLeaveSoft(snes) and
            maxCaptain >= 70 and maxCaptain < 100 and
            not story_percents.partyHasChar(snes, story_percents.PartyCharPaula) and
            fileExists(LlmLeaveDay1Map) and
            (scenarioPolicy == llm_mock_policies.AgentPaulaApproachPolicy or
              currentPolicy == llm_mock_policies.AgentPaulaApproachPolicy or
              scenarioPolicy == llm_mock_policies.AgentCaptainStrongPolicy or
              currentPolicy == llm_mock_policies.AgentCaptainStrongPolicy):
          if stuckCounter >= stuckThreshold div 2 or ctx.frameCount >= 800:
            echo "CAMPAIGN_SEGMENT: night south wall → day leave map ", LlmLeaveDay1Map
            try:
              readStateFile(LlmLeaveDay1Map, snes, cpu)
              snes.joy1 = 0
              ctx.joy1 = 0
              story_percents.applyLaterStoryLeaveSoft(snes)
              let csSeg = story_percents.captainStrongPercent(snes)
              echo "CAMPAIGN_SEGMENT: after load cs=", csSeg
              if csSeg > maxCaptain: maxCaptain = csSeg
              let capPol = llm_mock_policies.AgentCaptainStrongPolicy
              if loadPolicyChunk(L, capPol, "agent_captain_after_day_leave_map"):
                scenarioPolicy = capPol
                currentPolicy = capPol
                stuckCounter = 0
                echo "POLICY: campaign day leave map — hold captain 100"
                status = "leave_day1_map"
              writeStateFile(LlmRollbackState, snes, cpu)
              lastMilestonePath = LlmRollbackState
            except CatchableError as e:
              echo "CAMPAIGN_SEGMENT day leave map load failed: ", e.msg
        # d57/d58 campaign: later-story leave soft (cs70, no Jeff) cannot freewalk
        # past fo40 map wall. Prefer Paula-join leave fixture first (cs80/paula90),
        # then fo60 free when already party-joined or Paula fixture missing.
        if campaignFixtures and story_percents.laterStoryLeaveSoft(snes) and
            story_percents.captainStrongPercent(snes) >= 70 and
            story_percents.wintersPercent(snes) < 50 and
            not story_percents.partyHasChar(snes, story_percents.PartyCharPaula) and
            fileExists(LlmLeavePaulaJoin) and
            (scenarioPolicy == llm_mock_policies.AgentPaulaApproachPolicy or
              currentPolicy == llm_mock_policies.AgentPaulaApproachPolicy or
              scenarioPolicy == llm_mock_policies.AgentCaptainStrongPolicy or
              currentPolicy == llm_mock_policies.AgentCaptainStrongPolicy or
              scenarioPolicy == llm_mock_policies.AgentMidgameExplorePolicy or
              currentPolicy == llm_mock_policies.AgentMidgameExplorePolicy):
          if stuckCounter >= stuckThreshold div 2 or ctx.frameCount >= 1000:
            echo "CAMPAIGN_SEGMENT: leave soft → Paula join fixture ", LlmLeavePaulaJoin
            try:
              readStateFile(LlmLeavePaulaJoin, snes, cpu)
              snes.joy1 = 0
              ctx.joy1 = 0
              let csSeg = story_percents.captainStrongPercent(snes)
              let paSeg = story_percents.paulaRescuePercent(snes)
              echo "CAMPAIGN_SEGMENT: after load cs=", csSeg, " paula=", paSeg
              if csSeg > maxCaptain: maxCaptain = csSeg
              let midPol = llm_mock_policies.AgentMidgameExplorePolicy
              if loadPolicyChunk(L, midPol, "agent_mid_after_paula_join"):
                scenarioPolicy = midPol
                currentPolicy = midPol
                stuckCounter = 0
                echo "POLICY: campaign Paula join — AgentMidgameExplorePolicy"
                status = "midgame"
              writeStateFile(LlmRollbackState, snes, cpu)
              lastMilestonePath = LlmRollbackState
            except CatchableError as e:
              echo "CAMPAIGN_SEGMENT Paula join load failed: ", e.msg
        if campaignFixtures and story_percents.laterStoryLeaveSoft(snes) and
            story_percents.captainStrongPercent(snes) >= 70 and
            story_percents.foursidePercent(snes) < 60 and
            maxFourside < 60 and
            fileExists(LlmFourside60AfterLeave) and
            (scenarioPolicy == llm_mock_policies.AgentPaulaApproachPolicy or
              currentPolicy == llm_mock_policies.AgentPaulaApproachPolicy or
              scenarioPolicy == llm_mock_policies.AgentCaptainStrongPolicy or
              currentPolicy == llm_mock_policies.AgentCaptainStrongPolicy or
              scenarioPolicy == llm_mock_policies.AgentMidgameExplorePolicy or
              currentPolicy == llm_mock_policies.AgentMidgameExplorePolicy):
          if stuckCounter >= stuckThreshold div 2 or ctx.frameCount >= 1200:
            echo "CAMPAIGN_SEGMENT: leave soft fo wall; loading ", LlmFourside60AfterLeave
            try:
              readStateFile(LlmFourside60AfterLeave, snes, cpu)
              snes.joy1 = 0
              ctx.joy1 = 0
              let foSeg = story_percents.foursidePercent(snes)
              echo "CAMPAIGN_SEGMENT: after load fo=", foSeg
              if foSeg >= 60:
                maxFourside = foSeg
                let foPol = llm_mock_policies.AgentFoursideApproachPolicy
                if loadPolicyChunk(L, foPol, "agent_fourside_after_leave_soft"):
                  scenarioPolicy = foPol
                  currentPolicy = foPol
                  stuckCounter = 0
                  echo "POLICY: campaign leave→fo60 — AgentFoursideApproachPolicy"
                  status = "fourside"
                writeStateFile(LlmRollbackState, snes, cpu)
                lastMilestonePath = LlmRollbackState
            except CatchableError as e:
              echo "CAMPAIGN_SEGMENT leave→fo60 load failed: ", e.msg
        # Midgame winters soft (Jeff joined) → desert/Fourside explore seed.
        # Also accept when fixture already has Jeff (slot1/midgame load) even if
        # prior seed was captain/paula outdoor chain — continuity gap close.
        let wintersPctNow = story_percents.wintersPercent(snes)
        if wintersPctNow >= 50 and
            (scenarioPolicy == llm_mock_policies.AgentPaulaApproachPolicy or
              currentPolicy == llm_mock_policies.AgentPaulaApproachPolicy or
              scenarioPolicy == llm_mock_policies.AgentMidgameExplorePolicy or
              currentPolicy == llm_mock_policies.AgentMidgameExplorePolicy or
              scenarioPolicy == llm_mock_policies.AgentFoursideApproachPolicy or
              currentPolicy == llm_mock_policies.AgentFoursideApproachPolicy or
              scenarioPolicy == llm_mock_policies.AgentCaptainStrongPolicy or
              currentPolicy == llm_mock_policies.AgentCaptainStrongPolicy):
          let midPol = llm_mock_policies.AgentMidgameExplorePolicy
          # Prefer Fourside approach once soft fo>=60 (deep free walkable band).
          let foSoft = story_percents.foursidePercent(snes)
          if foSoft >= 60 and currentPolicy != llm_mock_policies.AgentFoursideApproachPolicy and
              currentPolicy != llm_mock_policies.AgentLateGamePolicy and
              loadPolicyChunk(L, llm_mock_policies.AgentFoursideApproachPolicy,
                "agent_fourside_after_fo60"):
            scenarioPolicy = llm_mock_policies.AgentFoursideApproachPolicy
            currentPolicy = llm_mock_policies.AgentFoursideApproachPolicy
            stuckCounter = 0
            echo "POLICY: fourside>=60 — AgentFoursideApproachPolicy (hold deep band)"
            status = "fourside"
          elif currentPolicy != midPol and
              currentPolicy != llm_mock_policies.AgentFoursideApproachPolicy and
              loadPolicyChunk(L, midPol, "agent_midgame_after_winters50"):
            scenarioPolicy = midPol
            currentPolicy = midPol
            stuckCounter = 0
            echo "POLICY: winters>=50 — AgentMidgameExplorePolicy (belch/fourside soft)"
            status = "midgame"
        # Campaign: natural fo40→60 blocked by map wall from mid pocket (probe_midgame_py_bands).
        # Prefer Paula-join deep seat (synth_fourside60_from_paula) so party continuity
        # survives the handoff; fall back to fourside60_walkable free deep.
        const LlmFourside60FromPaula = "bin/states/llm/fourside60_from_paula.state"
        const LlmFourside60Walkable = "bin/states/llm/fourside60_walkable.state"
        if campaignFixtures and story_percents.wintersPercent(snes) >= 50 and
            story_percents.foursidePercent(snes) > 0 and
            story_percents.foursidePercent(snes) < 60 and
            maxFourside < 60 and
            (fileExists(LlmFourside60FromPaula) or fileExists(LlmFourside60Walkable)) and
            (scenarioPolicy == llm_mock_policies.AgentMidgameExplorePolicy or
              currentPolicy == llm_mock_policies.AgentMidgameExplorePolicy or
              scenarioPolicy == llm_mock_policies.AgentFoursideApproachPolicy or
              currentPolicy == llm_mock_policies.AgentFoursideApproachPolicy):
          if stuckCounter >= stuckThreshold div 2 or ctx.frameCount >= 800:
            let fo60Path =
              if fileExists(LlmFourside60FromPaula): LlmFourside60FromPaula
              else: LlmFourside60Walkable
            echo "CAMPAIGN_SEGMENT: fo40 map wall; loading ", fo60Path
            try:
              readStateFile(fo60Path, snes, cpu)
              snes.joy1 = 0
              ctx.joy1 = 0
              let foSeg = story_percents.foursidePercent(snes)
              echo "CAMPAIGN_SEGMENT: after load fo=", foSeg,
                " paula=", story_percents.paulaRescuePercent(snes),
                " winters=", story_percents.wintersPercent(snes)
              if foSeg >= 60:
                maxFourside = foSeg
                let foPol = llm_mock_policies.AgentFoursideApproachPolicy
                if loadPolicyChunk(L, foPol, "agent_fourside_after_fo60_campaign"):
                  scenarioPolicy = foPol
                  currentPolicy = foPol
                  stuckCounter = 0
                  echo "POLICY: campaign fo60 — AgentFoursideApproachPolicy"
                  status = "fourside"
                writeStateFile(LlmRollbackState, snes, cpu)
                lastMilestonePath = LlmRollbackState
            except CatchableError as e:
              echo "CAMPAIGN_SEGMENT fo60 load failed: ", e.msg
        # Campaign: fo60 free midgame cannot join Poo bot-side; load free+Poo blend.
        # RE probe_past_fo60: free flags + Poo party = walkable fo80; mid flags lock.
        # Gate on maxFourside (live fo snaps to 40 after free-map walk from deep pos).
        # Prefer Paula-continuity fo80 seat (synth_fourside80_from_paula) then free Poo blends.
        const LlmFourside80FromPaula = "bin/states/llm/fourside80_from_paula.state"
        const LlmFourside80Walkable = "bin/states/llm/fourside80_walkable.state"
        const LlmPooFreeOutdoor = "bin/states/llm/poo_free_outdoor.state"
        if campaignFixtures and story_percents.wintersPercent(snes) >= 50 and
            maxFourside >= 60 and maxFourside < 80 and
            not story_percents.partyHasChar(snes, story_percents.PartyCharPoo) and
            (scenarioPolicy == llm_mock_policies.AgentFoursideApproachPolicy or
              currentPolicy == llm_mock_policies.AgentFoursideApproachPolicy or
              scenarioPolicy == llm_mock_policies.AgentMidgameExplorePolicy or
              currentPolicy == llm_mock_policies.AgentMidgameExplorePolicy):
          let pooPath =
            if fileExists(LlmFourside80FromPaula): LlmFourside80FromPaula
            elif fileExists(LlmFourside80Walkable): LlmFourside80Walkable
            elif fileExists(LlmPooFreeOutdoor): LlmPooFreeOutdoor
            else: ""
          if pooPath.len > 0 and (stuckCounter >= stuckThreshold div 2 or
              ctx.frameCount >= 400):
            echo "CAMPAIGN_SEGMENT: fo60 without Poo (max_fo=", maxFourside,
              "); loading ", pooPath
            try:
              readStateFile(pooPath, snes, cpu)
              snes.joy1 = 0
              ctx.joy1 = 0
              let foSeg = story_percents.foursidePercent(snes)
              let maSeg = story_percents.magicantPercent(snes)
              echo "CAMPAIGN_SEGMENT: after load fo=", foSeg, " ma=", maSeg,
                " poo=", story_percents.partyHasChar(snes, story_percents.PartyCharPoo)
              if foSeg >= 80:
                maxFourside = foSeg
                if maSeg > maxMagicant: maxMagicant = maSeg
                let latePol = llm_mock_policies.AgentLateGamePolicy
                if loadPolicyChunk(L, latePol, "agent_late_after_fo80_campaign"):
                  scenarioPolicy = latePol
                  currentPolicy = latePol
                  stuckCounter = 0
                  echo "POLICY: campaign fo80 — AgentLateGamePolicy"
                  status = "late"
                writeStateFile(LlmRollbackState, snes, cpu)
                lastMilestonePath = LlmRollbackState
            except CatchableError as e:
              echo "CAMPAIGN_SEGMENT fo80 load failed: ", e.msg
        # Campaign: freewalk cannot raise bitpop to soft98 (probe_soft98_climb).
        # Prefer soft98_from_fo80paula then poo_soft98_walkable for ma98/gi80 hold.
        const LlmSoft98FromFo80 = "bin/states/llm/soft98_from_fo80paula.state"
        const LlmSoft98Walkable = "bin/states/llm/poo_soft98_walkable.state"
        if campaignFixtures and
            story_percents.partyHasChar(snes, story_percents.PartyCharPoo) and
            maxFourside >= 80 and maxMagicant < 98 and
            (scenarioPolicy == llm_mock_policies.AgentLateGamePolicy or
              currentPolicy == llm_mock_policies.AgentLateGamePolicy or
              scenarioPolicy == llm_mock_policies.AgentFoursideApproachPolicy or
              currentPolicy == llm_mock_policies.AgentFoursideApproachPolicy):
          let softPath =
            if fileExists(LlmSoft98FromFo80): LlmSoft98FromFo80
            elif fileExists(LlmSoft98Walkable): LlmSoft98Walkable
            else: ""
          if softPath.len > 0 and (stuckCounter >= stuckThreshold div 2 or
              ctx.frameCount >= 500):
            echo "CAMPAIGN_SEGMENT: fo80 without soft98 (max_ma=", maxMagicant,
              "); loading ", softPath
            try:
              readStateFile(softPath, snes, cpu)
              snes.joy1 = 0
              ctx.joy1 = 0
              let maSeg = story_percents.magicantPercent(snes)
              let giSeg = story_percents.giygasPercent(snes)
              echo "CAMPAIGN_SEGMENT: after load ma=", maSeg, " gi=", giSeg,
                " soft=", story_percents.hasAllSanctuarySoft(snes)
              if maSeg >= 98:
                maxMagicant = maSeg
                if giSeg > maxGiygas: maxGiygas = giSeg
                let latePol = llm_mock_policies.AgentLateGamePolicy
                if loadPolicyChunk(L, latePol, "agent_late_after_soft98_campaign"):
                  scenarioPolicy = latePol
                  currentPolicy = latePol
                  stuckCounter = 0
                  echo "POLICY: campaign soft98 — AgentLateGamePolicy"
                  status = "soft98"
                writeStateFile(LlmRollbackState, snes, cpu)
                lastMilestonePath = LlmRollbackState
            except CatchableError as e:
              echo "CAMPAIGN_SEGMENT soft98 load failed: ", e.msg
        # Poo join / fourside 80+ → late-game Magicant soft seed.
        # Continuity: allow handoff from midgame, fourside, late, or paula.
        let foursidePctNow = story_percents.foursidePercent(snes)
        let magicantPctNow = story_percents.magicantPercent(snes)
        if (foursidePctNow >= 80 or magicantPctNow >= 30) and
            (scenarioPolicy == llm_mock_policies.AgentMidgameExplorePolicy or
              currentPolicy == llm_mock_policies.AgentMidgameExplorePolicy or
              scenarioPolicy == llm_mock_policies.AgentFoursideApproachPolicy or
              currentPolicy == llm_mock_policies.AgentFoursideApproachPolicy or
              scenarioPolicy == llm_mock_policies.AgentLateGamePolicy or
              currentPolicy == llm_mock_policies.AgentLateGamePolicy or
              scenarioPolicy == llm_mock_policies.AgentPaulaApproachPolicy or
              currentPolicy == llm_mock_policies.AgentPaulaApproachPolicy):
          let latePol = llm_mock_policies.AgentLateGamePolicy
          if currentPolicy != latePol and
              loadPolicyChunk(L, latePol, "agent_late_after_poo"):
            scenarioPolicy = latePol
            currentPolicy = latePol
            stuckCounter = 0
            echo "POLICY: fourside>=", foursidePctNow, " magicant>=", magicantPctNow,
              " — AgentLateGamePolicy (Poo/Magicant soft)"
            status = "late"
        # Only log when progress actually changed, or every ~300 frames as a heartbeat.
        let logSig = fmt"{tg}|{room}|{pokeyPct}|{pokeyKnockPct}|{buzzBuzzPct}|{sunrisePct}|{frankPctNow}"
        if logSig != lastLogSig or (ctx.frameCount mod 300 == 0):
          let giantPctLog = story_percents.giantStepPercent(snes)
          let captainPctLog = story_percents.captainStrongPercent(snes)
          let peacefulPctLog = story_percents.peacefulRestPercent(snes)
          let paulaPctLog = story_percents.paulaRescuePercent(snes)
          let lilliputPctLog = story_percents.lilliputStepsPercent(snes)
          let wintersPctLog = story_percents.wintersPercent(snes)
          let belchPctLog = story_percents.belchPercent(snes)
          let foursidePctLog = story_percents.foursidePercent(snes)
          let magicantPctLog = story_percents.magicantPercent(snes)
          let giygasPctLog = story_percents.giygasPercent(snes)
          logTg(fmt"{now()} frame={ctx.frameCount} touch_grass_pct={tg} max={maxTouchGrass} room={room} pokey_pct={pokeyPct} pokey_knock_pct={pokeyKnockPct} buzzbuzz_pct={buzzBuzzPct} sunrise_pct={sunrisePct} frank_pct={frankPctNow} giant_step_pct={giantPctLog} captain_strong_pct={captainPctLog} peaceful_rest_pct={peacefulPctLog} paula_rescue_pct={paulaPctLog} lilliput_steps_pct={lilliputPctLog} winters_pct={wintersPctLog} belch_pct={belchPctLog} fourside_pct={foursidePctLog} magicant_pct={magicantPctLog} giygas_pct={giygasPctLog}")
          lastLogSig = logSig
        if oldTg < 100 and tg >= 100:
          logTg(fmt"TOUCH GRASS ACHIEVED at frame {ctx.frameCount}")
          echo "TOUCH GRASS ACHIEVED!"
          # Campaign handoff after outside:
          # Scripted referee → PokeyVisitPolicy (dense route). Agent → intent seed.
          if useMock and (scenarioPolicy == llm_mock_policies.NavHousePolicy or
              currentPolicy == llm_mock_policies.NavHousePolicy):
            let pokey = llm_mock_policies.PokeyVisitPolicy
            if loadPolicyChunk(L, pokey, "pokey_visit_after_tg100"):
              scenarioPolicy = pokey
              currentPolicy = pokey
              echo "POLICY: tg>=100 — Scripted PokeyVisitPolicy (referee trail)"
              status = "pokey"
            else:
              echo "POLICY: PokeyVisitPolicy load failed; keeping prior"
          elif not useMock:
            let agentOut = llm_mock_policies.AgentOutdoorPolicy
            if loadPolicyChunk(L, agentOut, "agent_outdoor_after_tg100"):
              scenarioPolicy = agentOut
              currentPolicy = agentOut
              echo "POLICY: tg>=100 — AgentOutdoorPolicy (scene/intent; no followRoute)"
              status = "pokey"
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
        # the doorstep (60/90), not back at outside-start (0). Suppress once HEAD HOME begins —
        # there pokey_pct climbing means Ness drifted BACK toward the crater, not progress.
        let madeKnockProgress = knockPhase and pokeyKnockPct > prevKnock
        if madePokeyProgress and not knockPhase:
          try:
            writeStateFile(LlmRollbackState, snes, cpu)
            lastMilestonePath = LlmRollbackState
            stuckCounter = 0
            echo fmt"  SAVED pokey milestone (pokey_pct {prevPokey}->{pokeyPct}) -> {LlmRollbackState}"
          except CatchableError as e:
            echo "  save pokey milestone failed: ", e.msg
        # HEAD HOME milestone: re-anchor rollback FORWARD along the home leg (door=50,
        # bedroom=80) so a stall never drags Ness back up the hill to the crater.
        if madeKnockProgress:
          try:
            writeStateFile(LlmRollbackState, snes, cpu)
            lastMilestonePath = LlmRollbackState
            stuckCounter = 0
            echo fmt"  SAVED knock milestone (pokey_knock_pct {prevKnock}->{pokeyKnockPct}) -> {LlmRollbackState}"
          except CatchableError as e:
            echo "  save knock milestone failed: ", e.msg
        # Day-1 spine milestones: frank / captain climb while knock is latched 100 so
        # stuck recovery does not roll back past a referee peak (d39 plateau at cs40).
        let frankPctLive = story_percents.frankPercent(snes)
        let captainPctLive = story_percents.captainStrongPercent(snes)
        let madeFrankProgress = frankPctLive > prevFrank
        let madeCaptainProgress = captainPctLive > prevCaptain
        # Only snapshot when spine does not regress (cs climb while frank drops undoes day-1).
        let day1SpineOk = frankPctLive >= prevFrank
        if (madeFrankProgress or madeCaptainProgress) and day1SpineOk:
          try:
            writeStateFile(LlmRollbackState, snes, cpu)
            lastMilestonePath = LlmRollbackState
            stuckCounter = 0
            echo fmt"  SAVED day1 milestone (frank {prevFrank}->{frankPctLive} " &
              fmt"cs {prevCaptain}->{captainPctLive}) -> {LlmRollbackState}"
          except CatchableError as e:
            echo "  save day1 milestone failed: ", e.msg

        # higher-level stuck detection + rollback using save/load (beyond per-skill wiggle)
        # Use *coarse* (tg/room) + *fine* (live pos delta) + money. This prevents false "stuck" while
        # the agent is successfully walking across house_interior (tg stays 75 until the door).
        let curMoney = touch_grass.readU16(snes, 0x9831)
        let moneyProg = curMoney != prevMoney
        # In HEAD HOME phase, pokey_pct climbing is backward drift, not progress —
        # count knock progress instead so the stuck detector reads the home leg.
        let madeAnyProgress =
          if knockPhase:
            madeTgRoomProgress or madePosProgress or moneyProg or madeKnockProgress
          else:
            madeTgRoomProgress or madePosProgress or moneyProg or madePokeyProgress or
              madeFrankProgress or madeCaptainProgress
        # At the goal the bot deliberately stands still mashing to trigger a scene —
        # "not moving" there is success, not a stall. Pre-home that's adjacency to
        # Pokey (pokey_pct>=90); on the home leg it's reaching the door (knock>=50),
        # where facing + A warps Ness inside, and the bedroom (knock>=80).
        let atGoal =
          if knockPhase: pokeyKnockPct >= 50
          else: pokeyPct >= 90
        if not madeAnyProgress and not atGoal:
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
        prevKnock = pokeyKnockPct
        # High-water for day-1 spine (live frank/cs oscillate; do not re-fire milestones).
        if frankPctLive > prevFrank: prevFrank = frankPctLive
        if captainPctLive > prevCaptain: prevCaptain = captainPctLive
        prevPlayerX = px
        prevPlayerY = py
        if stuckCounter > stuckThreshold:
          inc stuckRecoveryCount
          if lastMilestonePath.len > 0 and fileExists(lastMilestonePath):
            echo fmt"STUCK_DETECTED (counter={stuckCounter}); STUCK_RECOVERY rollback -> {lastMilestonePath} (recovery#{stuckRecoveryCount})"
            try:
              readStateFile(lastMilestonePath, snes, cpu)
              snes.joy1 = 0
              ctx.joy1 = 0
              prevTg = touch_grass.touchGrassPercent(snes)
              prevRoom = touch_grass.currentRoomLabel(snes)
              prevMoney = touch_grass.readU16(snes, 0x9831)
              prevPokey = story_percents.pokeyPercent(snes)
              prevKnock = story_percents.pokeyKnockPercent(snes)
              prevFrank = story_percents.frankPercent(snes)
              prevCaptain = story_percents.captainStrongPercent(snes)
              let pidxR = touch_grass.PlayerSlot * touch_grass.SlotIndexStride
              prevPlayerX = touch_grass.readU16(snes, touch_grass.WorldXBase + pidxR)
              prevPlayerY = touch_grass.readU16(snes, touch_grass.WorldYBase + pidxR)
              stuckCounter = 0
              pendingLlm = false
              currentPolicy = scenarioPolicy
              discard loadPolicyChunk(L, currentPolicy, "post_rollback_safe_nav")
              status = "rollback"
              echo fmt"STUCK_RECOVERY: policy reloaded scenario seed (len={currentPolicy.len})"
            except CatchableError as e:
              echo "STUCK_RECOVERY rollback load failed: ", e.msg
              stuckCounter = 0
          else:
            # No checkpoint yet: replan by reloading the scenario seed (observable recovery).
            echo fmt"STUCK_DETECTED (counter={stuckCounter}); STUCK_RECOVERY replan (no checkpoint) recovery#{stuckRecoveryCount}"
            stuckCounter = 0
            pendingLlm = false
            currentPolicy = scenarioPolicy
            discard loadPolicyChunk(L, currentPolicy, "post_stuck_replan")
            status = "replan"
            echo fmt"STUCK_RECOVERY: forced policy replan seed (len={currentPolicy.len})"

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
            # Encode vision on main (owns frameImage); worker only POSTs snapshot bytes.
            var imageB64 = ""
            if gVision and not useMock:
              imageB64 = encodeFramePngBase64(frameImage)
              echo fmt"VISION_ENCODE: frame={ctx.frameCount} {visionPayloadStats(imageB64)}"
            # Pass snapshot of notes at send time so worker uses consistent view (no race with appendNote on main).
            workChan.send( (richSummary, currentPolicy, persistentNotes, imageB64) )
            pendingLlm = true
            let modeLabel = if watchAsync: "async" else: "sync"
            echo fmt"LLM_QUEUED: frame={ctx.frameCount} mode={modeLabel} vision={gVision and imageB64.len > 0}"
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
    if finalPokey > maxPokey: maxPokey = finalPokey
    let finalPokeyKnock = story_percents.pokeyKnockPercent(snes)
    if finalPokeyKnock > maxKnock: maxKnock = finalPokeyKnock
    let finalBuzz = story_percents.buzzBuzzPercent(snes)
    let finalSunrise = story_percents.sunrisePercent(snes)
    let finalFrank = story_percents.frankPercent(snes)
    let finalGiant = story_percents.giantStepPercent(snes)
    let finalCaptain = story_percents.captainStrongPercent(snes)
    let finalMagicant = story_percents.magicantPercent(snes)
    let finalGiygas = story_percents.giygasPercent(snes)
    let finalFourside = story_percents.foursidePercent(snes)
    if finalMagicant > maxMagicant: maxMagicant = finalMagicant
    if finalGiygas > maxGiygas: maxGiygas = finalGiygas
    if finalFourside > maxFourside: maxFourside = finalFourside
    if finalFrank > maxFrank: maxFrank = finalFrank
    if finalGiant > maxGiant: maxGiant = finalGiant
    if finalCaptain > maxCaptain: maxCaptain = finalCaptain
    logTg(fmt"{now()} frame={ctx.frameCount} touch_grass_pct={finalTg} max={maxTouchGrass} pokey_pct={finalPokey} max_pokey={maxPokey} pokey_knock_pct={finalPokeyKnock} max_knock={maxKnock} buzzbuzz_pct={finalBuzz} sunrise_pct={finalSunrise} frank_pct={finalFrank} max_frank={maxFrank} giant_step_pct={finalGiant} max_giant={maxGiant} captain_strong_pct={finalCaptain} max_captain={maxCaptain} fourside_pct={finalFourside} max_fourside={maxFourside} magicant_pct={finalMagicant} max_magicant={maxMagicant} giygas_pct={finalGiygas} max_giygas={maxGiygas} stuck_recoveries={stuckRecoveryCount} (final)")
    echo fmt"done: ran {ctx.frameCount} frames. final joy1=0x{snes.joy1:04x} max_touch_grass={maxTouchGrass} pokey_pct={finalPokey} max_pokey={maxPokey} max_knock={maxKnock}" &
      (if pokeyAchievedFrame >= 0: fmt" POKEY_ACHIEVED@{pokeyAchievedFrame}" else: "") &
      fmt" sunrise_pct={finalSunrise} max_frank={maxFrank} max_giant={maxGiant} max_captain={maxCaptain}" &
      fmt" max_fourside={maxFourside} max_magicant={maxMagicant} max_giygas={maxGiygas} stuck_recoveries={stuckRecoveryCount}"
    echo fmt"frames_during_pending={framesDuringPending} (frames advanced while LLM request in-flight; async proof when >0)"
    if saveStateSlot >= 0:
      let outPath = llmSlotPath(saveStateSlot)
      writeStateFile(outPath, snes, cpu)
      echo fmt"saved final state to LLM path {outPath} (px=0x{touch_grass.readU16(snes, 0x0BBE):04X} py=0x{touch_grass.readU16(snes, 0x0BFA):04X})"
    if saveSramEnabled and snes.sramDirty:
      saveSram(snes, saveSramPath)
    L.close()
    quit(0)
  main()
