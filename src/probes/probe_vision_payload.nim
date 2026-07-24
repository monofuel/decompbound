## Offline + optional live vision payload probe for LLM-play.
## 1) Encode a rendered frame from an LLM fixture → PNG base64 stats (always).
## 2) If --live: POST one multimodal request to azem and report Lua extract or error.
## Usage:
##   nim r -d:release src/probes/probe_vision_payload.nim [--live] [rom] [state]

import
  std/[os, strformat, strutils, httpclient, json, times],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, policy],
  ../tools/[vision_payload, llm_ai]

const
  DefaultRom = "bin/Earthbound (U) [!].smc"
  DefaultState = "bin/states/llm/onett_start.state"
  AzemUrl = "http://10.11.2.22:1234/v1/chat/completions"

proc main() =
  ## Render one frame from a fixture and prove vision payload is non-empty.
  var live = false
  var args: seq[string] = @[]
  for i in 1 .. paramCount():
    let a = paramStr(i)
    if a == "--live": live = true
    elif a != "--": args.add a
  let romPath = if args.len >= 1: args[0] else: DefaultRom
  let statePath = if args.len >= 2: args[1] else: DefaultState

  if not fileExists(romPath):
    echo "SKIP: no ROM at ", romPath
    quit(0)
  if not fileExists(statePath):
    echo "SKIP: no state at ", statePath
    quit(0)

  let snes = newSnesBus(policy.readRomFile(romPath))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(statePath)), snes, cpu)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  for i in 0 .. 30:
    snes.joy1 = 0
    policy.stepOneFrame(snes, cpu, img)

  let b64 = encodeFramePngBase64(img)
  let stats = visionPayloadStats(b64)
  echo "VISION_OFFLINE: ", stats
  let msgs = chatMessagesWithOptionalVision(
    AgentSystemPrompt,
    "RICH STATE: probe frame. Return ONLY function update() end with escapeMenu().",
    b64)
  echo "VISION_OFFLINE: image_parts_in_messages=", countImageParts(msgs)
  doAssert countImageParts(msgs) == 1
  doAssert b64.len > 100

  # Optional write stats only (no PNG commit).
  let outStats = getEnv("VISION_STATS_OUT")
  if outStats.len > 0:
    writeFile(outStats, stats & "\nimage_parts=" & $countImageParts(msgs) & "\n")

  if not live:
    echo "OK probe_vision_payload offline (pass --live to hit azem)"
    return

  echo "VISION_LIVE: POST ", AzemUrl
  let body = %* {
    "model": "qwen3.6-27b@q6_k",
    "max_tokens": 4096,
    "temperature": 0.2,
    "messages": msgs
  }
  try:
    let client = newHttpClient(timeout = 600_000)
    client.headers = newHttpHeaders({
      "Content-Type": "application/json",
      "Authorization": "Bearer lm-studio"
    })
    let t0 = now()
    let resp = client.post(AzemUrl, $body)
    client.close()
    let dt = (now() - t0).inMilliseconds
    echo "VISION_LIVE: status=", resp.status, " latency_ms=", dt
    echo "VISION_LIVE: body_head=", resp.body[0 ..< min(400, resp.body.len)]
    if resp.status.startsWith("200"):
      let j = parseJson(resp.body)
      var raw = ""
      var reas = ""
      if j.hasKey("choices") and j["choices"].len > 0:
        let msg = j["choices"][0]["message"]
        raw = msg.getOrDefault("content").getStr("")
        reas = msg.getOrDefault("reasoning_content").getStr("")
      let cand = if "function update" in raw: raw else: reas
      if "function update" in cand:
        echo "VISION_LIVE: extracted function update() from response"
      else:
        echo "VISION_LIVE: no function update in content/reasoning (len raw=",
          raw.len, " reas=", reas.len, ")"
    else:
      echo "VISION_LIVE: HTTP error body retained above"
  except CatchableError as e:
    echo "VISION_LIVE: connection/error: ", e.msg

when isMainModule:
  main()
