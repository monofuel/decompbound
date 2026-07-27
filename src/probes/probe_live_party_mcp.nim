## Headless verification of live party WRAM parse + in-process MCP plumbing.
## Loads a state, runs a few frames, asserts party_wram vitals are sane and
## match party_sram on a freshly-copied persist-block SRAM image. Then starts
## the same snapshot+HTTP stack play.nim uses and curls get_party_vitals.
##
## No GUI, no audio. Usage: nim r src/probes/probe_live_party_mcp.nim

import
  std/[httpclient, json, os, strformat, strutils],
  pixie,
  ../decompbound/[cpu, item_table, party_sram, party_wram, policy, ppu,
                  save_state, snesbus],
  ../tools/play_mcp

const
  RomPath = "bin/Earthbound (U) [!].smc"
  StatePath = "bin/states/llm/onett_start.state"
  FramesToRun = 8

proc stepFrames(snes: SnesBus, cpu: var Cpu, n: int) =
  ## Run `n` emulated frames headless (no window/audio; discard pixel buffer).
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  for _ in 0 ..< n:
    policy.stepOneFrame(snes, cpu, img)

proc assertSaneMember(m: PartyMemberVitals, label: string) =
  ## Require decoded name + level/HP ranges used by play co-pilot consumers.
  doAssert m.name.len > 0 and m.name != "(empty)", &"{label}: bad name {m.name}"
  doAssert m.level >= 1 and m.level <= 99, &"{label}: level {m.level}"
  # HP/PP are u16 and CAN legitimately exceed 999 (UI shows 3 digits but the
  # value works — docs/gameplay/stats.md); only the storage width bounds them.
  doAssert m.hpMax > 0 and m.hpMax <= 0xFFFF, &"{label}: hpMax {m.hpMax}"
  doAssert m.hp > 0 and m.hp <= m.hpMax, &"{label}: hp {m.hp}/{m.hpMax}"
  doAssert m.pp >= 0 and m.pp <= m.ppMax and m.ppMax <= 0xFFFF,
    &"{label}: pp {m.pp}/{m.ppMax}"
  doAssert m.exp >= 0, &"{label}: exp {m.exp}"
  doAssert m.stats.offense > 0 and m.stats.defense > 0,
    &"{label}: stats {m.stats}"
  doAssert m.statsBase.speed > 0 and m.statsBase.vitality > 0,
    &"{label}: statsBase {m.statsBase}"

proc membersMatch(a, b: seq[PartyMemberVitals]): bool =
  ## Compare vitals rows used by get_party_vitals.
  if a.len != b.len: return false
  for i in 0 ..< a.len:
    if a[i].role != b[i].role: return false
    if a[i].name != b[i].name: return false
    if a[i].level != b[i].level: return false
    if a[i].hp != b[i].hp or a[i].hpMax != b[i].hpMax: return false
    if a[i].pp != b[i].pp or a[i].ppMax != b[i].ppMax: return false
    if a[i].exp != b[i].exp: return false
    if a[i].stats != b[i].stats or a[i].statsBase != b[i].statsBase: return false
    if a[i].inventory != b[i].inventory: return false
    if a[i].inParty != b[i].inParty: return false
  true

proc mcpInitializeAndCall(): JsonNode =
  ## HTTP MCP: initialize session then tools/call get_party_vitals.
  let client = newHttpClient(timeout = 5000)
  defer: client.close()
  client.headers = newHttpHeaders({"Content-Type": "application/json"})
  let initBody = $(%*{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
      "protocolVersion": "2024-11-05",
      "capabilities": {},
      "clientInfo": {"name": "probe_live_party_mcp", "version": "0.1.0"}
    }
  })
  let initResp = client.postContent(McpUrl, initBody)
  doAssert initResp.len > 0, "empty initialize response"
  let callBody = $(%*{
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tools/call",
    "params": {
      "name": "get_party_vitals",
      "arguments": {}
    }
  })
  let callResp = client.postContent(McpUrl, callBody)
  result = parseJson(callResp)

proc main() =
  ## Headless party_wram + live MCP probe.
  doAssert fileExists(RomPath), &"need ROM at {RomPath}"
  doAssert fileExists(StatePath), &"need state at {StatePath}"

  let rom = policy.readRomFile(RomPath)
  var snes = newSnesBus(rom)
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(StatePath)), snes, cpu)
  stepFrames(snes, cpu, FramesToRun)

  let wramRep = readPartyVitalsFromWram(snes, frameCount = FramesToRun)
  doAssert not wramRep.empty, wramRep.note
  doAssert wramRep.source == "live-wram"
  doAssert wramRep.frameCount == FramesToRun
  doAssert wramRep.members.len >= 1, "expected at least Ness"
  for m in wramRep.members:
    assertSaneMember(m, m.role)
  echo &"OK wram: {wramRep.members.len} member(s)  Ness HP={wramRep.members[0].hp}/{wramRep.members[0].hpMax} lv={wramRep.members[0].level}"

  # Live inventory should decode item names from the ROM (Onett start: Ness
  # carries at least the Cracked bat or similar — assert *some* named item).
  var namedItems = 0
  var sawSellable = false
  var sawUnsellableKey = false
  for m in wramRep.members:
    for s in m.inventory:
      doAssert s.id > 0 and s.slot >= 1 and s.slot <= 14
      if s.name.len > 0: inc namedItems
      # Sell fields always present; sellPrice must match floor(price/2).
      doAssert s.sellPrice == s.price div 2,
        &"sellPrice mismatch id={s.id} price={s.price} sell={s.sellPrice}"
      doAssert s.sellable == (s.price > 0),
        &"sellable mismatch id={s.id} price={s.price} sellable={s.sellable}"
      if s.sellable and s.price > 0:
        sawSellable = true
        doAssert s.sellPrice == s.price div 2
      # ATM card id177: key item, price 0 → not sellable (ROM evidence).
      if s.id == 177:
        doAssert s.price == 0 and not s.sellable and s.sellPrice == 0,
          &"ATM card should be unsellable: {s}"
        sawUnsellableKey = true
  doAssert namedItems > 0, "expected at least one ROM-decoded item name"
  # Direct ROM checks (state may not carry ATM card / a priced junk item).
  const AtmCardId = 177
  doAssert itemPrice(snes.rom, AtmCardId) == 0
  doAssert not itemSellable(snes.rom, AtmCardId)
  doAssert itemSellPrice(snes.rom, AtmCardId) == 0
  # Cookie id88 price $7 → sell $3 (floor half).
  const CookieId = 88
  doAssert itemPrice(snes.rom, CookieId) == 7
  doAssert itemSellable(snes.rom, CookieId)
  doAssert itemSellPrice(snes.rom, CookieId) == 3
  if sawSellable:
    echo "OK inventory sell fields: saw priced sellable item in party bag"
  if sawUnsellableKey:
    echo "OK inventory: ATM card present and sellable=false"
  echo &"OK inventory: {namedItems} named item(s); ATM/Cookie sell rules via ROM"

  # Freshly-saved SRAM image = persist block copy (what phone-save writes).
  let synthSrm = persistBlockToSramBytes(snes)
  let sramRep = readPartyVitalsFromBytes(synthSrm, "synthetic_from_wram.srm", snes.rom)
  doAssert not sramRep.empty, sramRep.note
  doAssert membersMatch(wramRep.members, sramRep.members),
    &"wram vs sram mismatch\n  wram={wramRep.members}\n  sram={sramRep.members}"
  echo "OK wram == sram on freshly-copied persist block"

  # Snapshot + real HTTP MCP (same plumbing as play.nim; no SDL window).
  publishLiveParty(snes, FramesToRun)
  if not tryStartLiveMcp():
    echo "SKIP mcp http: port 4343 busy"
    echo "OK probe_live_party_mcp (wram only)"
    quit(0)

  # Give Mummy a moment to bind + accept.
  sleep(200)
  try:
    let rpc = mcpInitializeAndCall()
    doAssert rpc.hasKey("result"), &"no result: {rpc}"
    let res = rpc["result"]
    # structuredContent may be under result directly or nested by MCPort version
    var payload: JsonNode
    if res.hasKey("structuredContent"):
      payload = res["structuredContent"]
    elif res.hasKey("content") and res["content"].kind == JArray and res["content"].len > 0:
      payload = parseJson(res["content"][0]["text"].getStr())
    else:
      doAssert false, &"unexpected tools/call shape: {res}"
    doAssert payload["source"].getStr() == "live-wram", $payload
    doAssert payload["frameCount"].getInt() == FramesToRun, $payload
    doAssert payload["empty"].getBool() == false, $payload
    let members = payload["members"]
    doAssert members.kind == JArray and members.len >= 1
    let ness = members[0]
    doAssert ness["name"].getStr().len > 0
    doAssert ness["hp"].getInt() > 0
    doAssert ness["hp"].getInt() <= ness["hpMax"].getInt()
    doAssert ness["stats"]["offense"].getInt() > 0, $ness
    doAssert ness["exp"].getInt() >= 0, $ness
    echo &"OK mcp http: source={payload[\"source\"]} frameCount={payload[\"frameCount\"]} ness.hp={ness[\"hp\"]}"
  except CatchableError as e:
    echo &"FAIL mcp http: {e.msg}"
    quit(1)

  echo "OK probe_live_party_mcp"
  # Process exit kills the Mummy serve thread (do not call close — ORC race).
  quit(0)

main()
