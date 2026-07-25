## Headless timing probe for audio-skip investigation.
##
## Measures per-frame cost of publishLiveParty (readPartyVitalsFromWram + lock
## assign) alone, under concurrent copyLiveParty hammer, and under concurrent
## HTTP get_party_vitals against tryStartLiveMcp. No GUI, no OpenAL.
##
## Usage: nim r src/probes/probe_audio_skip_mcp.nim

import
  std/[httpclient, json, locks, monotimes, os, strformat, strutils, times],
  pixie,
  ../decompbound/[cpu, party_wram, policy, ppu, save_state, snesbus],
  ../tools/play_mcp

const
  RomPath = "bin/Earthbound (U) [!].smc"
  StatePath = "bin/states/llm/onett_start.state"
  WarmupFrames = 60
  MeasureFrames = 10_000
  HammerIters = 50_000
  HttpBurst = 200

type
  Stats = object
    n: int
    totalUs: int64
    maxUs: int64
    minUs: int64
    over1ms: int
    over5ms: int
    over16ms: int
    over50ms: int
    over100ms: int
    over500ms: int

proc initStats(): Stats =
  ## Empty stats with minUs as max-sentinel.
  result.minUs = high(int64)

proc add(s: var Stats, us: int64) =
  ## Record one sample in microseconds.
  inc s.n
  s.totalUs += us
  if us > s.maxUs: s.maxUs = us
  if us < s.minUs: s.minUs = us
  if us >= 1000: inc s.over1ms
  if us >= 5000: inc s.over5ms
  if us >= 16000: inc s.over16ms
  if us >= 50000: inc s.over50ms
  if us >= 100000: inc s.over100ms
  if us >= 500000: inc s.over500ms

proc report(s: Stats, label: string) =
  ## Print summary line for a stats bucket.
  if s.n == 0:
    echo &"{label}: n=0"
    return
  let avg = s.totalUs.float / s.n.float
  echo &"{label}: n={s.n} avg={avg:.1f}us min={s.minUs}us max={s.maxUs}us " &
    &"(max={s.maxUs.float/1000.0:.2f}ms) " &
    &">=1ms:{s.over1ms} >=5ms:{s.over5ms} >=16ms:{s.over16ms} " &
    &">=50ms:{s.over50ms} >=100ms:{s.over100ms} >=500ms:{s.over500ms}"

proc stepFrames(snes: SnesBus, cpu: var Cpu, n: int) =
  ## Run `n` emulated frames headless (discard pixels).
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  for _ in 0 ..< n:
    policy.stepOneFrame(snes, cpu, img)

var
  gHammerStop: bool
  gHammerLock: Lock
  gHammerCount: int
  gHammerMaxUs: int64
  gHttpStop: bool
  gHttpOk: int
  gHttpFail: int
  gHttpMaxUs: int64

proc copyHammer(unused: int) {.thread.} =
  ## Spin copyLiveParty as fast as possible (simulates MCP handler under load).
  discard unused
  {.cast(gcsafe).}:
    while true:
      withLock gHammerLock:
        if gHammerStop: break
      let t0 = getMonoTime()
      discard copyLiveParty()
      let us = (getMonoTime() - t0).inMicroseconds
      withLock gHammerLock:
        inc gHammerCount
        if us > gHammerMaxUs: gHammerMaxUs = us

proc httpHammer(unused: int) {.thread.} =
  ## Hammer get_party_vitals over HTTP (JSON path on Mummy worker).
  discard unused
  {.cast(gcsafe).}:
    let client = newHttpClient(timeout = 2000)
    defer: client.close()
    client.headers = newHttpHeaders({"Content-Type": "application/json"})
    # One-time initialize
    try:
      let initBody = $(%*{
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
          "protocolVersion": "2024-11-05",
          "capabilities": {},
          "clientInfo": {"name": "probe_audio_skip", "version": "0.1"}
        }
      })
      discard client.postContent(McpUrl, initBody)
    except CatchableError:
      discard
    var id = 2
    while true:
      withLock gHammerLock:
        if gHttpStop: break
      let callBody = $(%*{
        "jsonrpc": "2.0",
        "id": id,
        "method": "tools/call",
        "params": {"name": "get_party_vitals", "arguments": {}}
      })
      inc id
      let t0 = getMonoTime()
      try:
        discard client.postContent(McpUrl, callBody)
        let us = (getMonoTime() - t0).inMicroseconds
        withLock gHammerLock:
          inc gHttpOk
          if us > gHttpMaxUs: gHttpMaxUs = us
      except CatchableError:
        withLock gHammerLock:
          inc gHttpFail

proc main() =
  ## Time publishLiveParty under three contention levels.
  doAssert fileExists(RomPath), &"need ROM at {RomPath}"
  doAssert fileExists(StatePath), &"need state at {StatePath}"

  initLock(gHammerLock)

  let rom = policy.readRomFile(RomPath)
  var snes = newSnesBus(rom)
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(StatePath)), snes, cpu)
  stepFrames(snes, cpu, WarmupFrames)

  let sample = readPartyVitalsFromWram(snes, WarmupFrames)
  echo &"party members={sample.members.len} inv items total=" &
    $(block:
      var n = 0
      for m in sample.members: n += m.inventory.len
      n)

  # --- A: raw readPartyVitalsFromWram cost (no lock) ---
  var sRead = initStats()
  for i in 0 ..< MeasureFrames:
    let t0 = getMonoTime()
    discard readPartyVitalsFromWram(snes, i)
    add(sRead, (getMonoTime() - t0).inMicroseconds)
  report(sRead, "A readPartyVitalsFromWram alone")

  # --- B: publishLiveParty alone (no concurrent readers) ---
  var sPub = initStats()
  for i in 0 ..< MeasureFrames:
    let t0 = getMonoTime()
    publishLiveParty(snes, i)
    add(sPub, (getMonoTime() - t0).inMicroseconds)
  report(sPub, "B publishLiveParty alone")

  # --- C: publish under concurrent copyLiveParty hammer ---
  gHammerStop = false
  gHammerCount = 0
  gHammerMaxUs = 0
  var hammerThr: Thread[int]
  createThread(hammerThr, copyHammer, 0)
  sleep(50)
  var sCont = initStats()
  for i in 0 ..< MeasureFrames:
    let t0 = getMonoTime()
    publishLiveParty(snes, i)
    add(sCont, (getMonoTime() - t0).inMicroseconds)
  withLock gHammerLock:
    gHammerStop = true
  joinThread(hammerThr)
  report(sCont, "C publish + concurrent copyLiveParty")
  echo &"  hammer copies={gHammerCount} hammer max copy={gHammerMaxUs}us"

  # --- D: lock-hold isolation: only the withLock assign cost ---
  # Publish once so gSnap is warm, then measure assign-only via publishLivePartyReport
  publishLiveParty(snes, 0)
  var sLock = initStats()
  for i in 0 ..< MeasureFrames:
    let rep = readPartyVitalsFromWram(snes, i)
    let t0 = getMonoTime()
    publishLivePartyReport(rep, i)
    add(sLock, (getMonoTime() - t0).inMicroseconds)
  report(sLock, "D publishLivePartyReport (lock assign only)")

  # --- E: full HTTP MCP path under concurrent publish ---
  if not tryStartLiveMcp():
    echo "E SKIP: port 4343 busy (cannot start live MCP)"
  else:
    sleep(200)
    gHttpStop = false
    gHttpOk = 0
    gHttpFail = 0
    gHttpMaxUs = 0
    var httpThr: Thread[int]
    createThread(httpThr, httpHammer, 0)
    sleep(100)
    var sHttp = initStats()
    for i in 0 ..< MeasureFrames:
      let t0 = getMonoTime()
      publishLiveParty(snes, i)
      add(sHttp, (getMonoTime() - t0).inMicroseconds)
    withLock gHammerLock:
      gHttpStop = true
    joinThread(httpThr)
    report(sHttp, "E publish + concurrent HTTP get_party_vitals")
    echo &"  http ok={gHttpOk} fail={gHttpFail} max http RTT={gHttpMaxUs}us " &
      &"({gHttpMaxUs.float/1000.0:.2f}ms)"

    # --- F: single-thread sequential HTTP RTT (no publish concurrent) ---
    var sRtt = initStats()
    let client = newHttpClient(timeout = 2000)
    defer: client.close()
    client.headers = newHttpHeaders({"Content-Type": "application/json"})
    for i in 0 ..< HttpBurst:
      publishLiveParty(snes, i)
      let callBody = $(%*{
        "jsonrpc": "2.0",
        "id": i + 100,
        "method": "tools/call",
        "params": {"name": "get_party_vitals", "arguments": {}}
      })
      let t0 = getMonoTime()
      try:
        discard client.postContent(McpUrl, callBody)
        add(sRtt, (getMonoTime() - t0).inMicroseconds)
      except CatchableError as e:
        echo &"  http fail: {e.msg}"
    report(sRtt, "F sequential HTTP RTT (publish then call)")

  # --- G: emulate full frames + publish (no GL/audio) to see total headroom ---
  var sFrame = initStats()
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  for i in 0 ..< 2000:
    let t0 = getMonoTime()
    policy.stepOneFrame(snes, cpu, img)
    publishLiveParty(snes, WarmupFrames + i)
    add(sFrame, (getMonoTime() - t0).inMicroseconds)
  report(sFrame, "G stepOneFrame + publish (2000 frames)")

  echo "DONE probe_audio_skip_mcp"

main()
