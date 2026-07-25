## In-process Goal 5 MCP for `play.nim`: live party vitals over HTTP.
##
## Mummy handlers run on worker threads — they only read a lock-guarded
## snapshot. The main frame loop publishes that snapshot (struct copy under
## lock). No disk, no separate process. Defaults: localhost:4343, every frame.

import
  std/[json, locks, net, options, strformat],
  mcport,
  mummy,
  ../decompbound/[party_sram, party_wram, snesbus]

const
  ServerName = "decompbound"
  ServerVersion = "0.1.0"
  DefaultHost* = "localhost"
  DefaultPort* = 4343
  McpUrl* = "http://localhost:4343/mcp"

type
  LivePartySnap* = object
    ## In-memory party vitals published by the frame loop.
    report*: PartyVitalsReport
    frameCount*: int
    valid*: bool

var
  gSnapLock: Lock
  gSnap: LivePartySnap
  gHttp: HttpMcpServer
  gServeThread: Thread[int]
  gServing: bool
  gLockInited: bool

proc ensureLock() =
  ## Init the snapshot lock once.
  if not gLockInited:
    initLock(gSnapLock)
    gLockInited = true

proc publishLiveParty*(snes: SnesBus, frameCount: int) =
  ## Copy live WRAM vitals into the lock-guarded snapshot (main thread only).
  ensureLock()
  let report = readPartyVitalsFromWram(snes, frameCount)
  withLock gSnapLock:
    gSnap.report = report
    gSnap.frameCount = frameCount
    gSnap.valid = true

proc publishLivePartyReport*(report: PartyVitalsReport, frameCount: int) =
  ## Publish an already-parsed report (for headless probes).
  ensureLock()
  withLock gSnapLock:
    gSnap.report = report
    gSnap.frameCount = frameCount
    gSnap.valid = true

proc copyLiveParty*(): LivePartySnap =
  ## Handler-safe snapshot copy (lock hold = object assignment only).
  ensureLock()
  withLock gSnapLock:
    result = gSnap

proc partyVitalsToJson*(report: PartyVitalsReport): JsonNode =
  ## Structured payload for get_party_vitals (live or offline shape).
  var members = newJArray()
  for m in report.members:
    members.add memberToJson(m)
  result = %*{
    "srmPath": report.srmPath,
    "source": report.source,
    "slotBase": report.slotBase,
    "modifiedAt": report.modifiedAt,
    "frameCount": report.frameCount,
    "empty": report.empty,
    "note": report.note,
    "members": members
  }

proc getPartyVitalsLiveHandler(arguments: JsonNode): ToolResult {.gcsafe.} =
  ## MCP handler: party vitals from the in-memory live snapshot only.
  {.cast(gcsafe).}:
    discard arguments
    let snap = copyLiveParty()
    if not snap.valid:
      let empty = PartyVitalsReport(
        source: "live-wram",
        empty: true,
        note: "No live snapshot yet (emulator not running frames)"
      )
      let payload = partyVitalsToJson(empty)
      return ToolResult(
        content: @[textContent($payload)],
        structuredContent: some(payload),
        isError: true
      )
    var report = snap.report
    report.frameCount = snap.frameCount
    report.source = "live-wram"
    let payload = partyVitalsToJson(report)
    return ToolResult(
      content: @[textContent($payload)],
      structuredContent: some(payload),
      isError: report.empty
    )

proc liveTool(name, description: string): McpTool =
  ## No-arg tool schema for in-process live vitals.
  McpTool(
    name: name,
    description: description,
    inputSchema: %*{
      "type": "object",
      "properties": {},
      "required": [],
      "additionalProperties": false,
      "$schema": "http://json-schema.org/draft-07/schema#"
    },
    outputSchema: some(%*{
      "type": "object",
      "properties": {
        "source": {"type": "string"},
        "frameCount": {"type": "integer"},
        "empty": {"type": "boolean"},
        "note": {"type": "string"},
        "members": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "role": {"type": "string"},
              "name": {"type": "string"},
              "level": {"type": "integer"},
              "exp": {"type": "integer"},
              "hp": {"type": "integer"},
              "hpMax": {"type": "integer"},
              "pp": {"type": "integer"},
              "ppMax": {"type": "integer"},
              "stats": {
                "type": "object",
                "description": "With equipment (status-screen numbers)",
                "properties": {
                  "offense": {"type": "integer"},
                  "defense": {"type": "integer"},
                  "speed": {"type": "integer"},
                  "guts": {"type": "integer"},
                  "luck": {"type": "integer"},
                  "vitality": {"type": "integer"},
                  "iq": {"type": "integer"}
                }
              },
              "statsBase": {
                "type": "object",
                "description": "Base stats without equipment",
                "properties": {
                  "offense": {"type": "integer"},
                  "defense": {"type": "integer"},
                  "speed": {"type": "integer"},
                  "guts": {"type": "integer"},
                  "luck": {"type": "integer"},
                  "vitality": {"type": "integer"},
                  "iq": {"type": "integer"}
                }
              },
              "inventory": {
                "type": "array",
                "description": "Occupied inventory slots (of 14 per character); names decoded from the ROM item table",
                "items": {
                  "type": "object",
                  "properties": {
                    "slot": {"type": "integer"},
                    "id": {"type": "integer"},
                    "name": {"type": "string"},
                    "equipped": {"type": "boolean"}
                  }
                }
              },
              "inParty": {"type": "boolean"}
            }
          }
        }
      }
    })
  )

proc createLiveMcpServer*(): McpServer =
  ## Build the in-process co-pilot MCP server (live WRAM tools only).
  let server = newMcpServer(ServerName, ServerVersion)
  server.registerRichTool(
    liveTool(
      "get_party_vitals",
      "Get party HP/PP/level/names from the LIVE running game (WRAM). Goal 5 co-pilot — not the LLM player agent. source is live-wram with frameCount."
    ),
    getPartyVitalsLiveHandler
  )
  return server

proc portFree(host: string, port: int): bool =
  ## True if we can bind `host:port` right now (probe, then close).
  try:
    let sock = newSocket(Domain.AF_INET, SockType.SOCK_STREAM, Protocol.IPPROTO_TCP, buffered = false)
    defer: sock.close()
    sock.setSockOpt(OptReuseAddr, true)
    sock.bindAddr(Port(port), host)
    result = true
  except CatchableError:
    result = false

proc serveThreadProc(unused: int) {.thread.} =
  ## Block on Mummy serve until process exit or close.
  discard unused
  {.cast(gcsafe).}:
    try:
      if gHttp != nil:
        gHttp.serve(DefaultPort, DefaultHost)
    except CatchableError as e:
      echo &"decompbound MCP serve ended: {e.msg}"

proc tryStartLiveMcp*(): bool =
  ## Start HTTP MCP on localhost:4343 in a background thread. Returns false if
  ## the port is taken (game continues without MCP). Idempotent.
  if gServing:
    return true
  ensureLock()
  if not portFree(DefaultHost, DefaultPort):
    echo &"warning: MCP port {DefaultPort} in use — continuing without co-pilot MCP"
    return false
  let mcp = createLiveMcpServer()
  gHttp = newHttpMcpServer(mcp, logEnabled = false)
  createThread(gServeThread, serveThreadProc, 0)
  gServing = true
  echo &"decompbound MCP on {McpUrl}  (live WRAM, in-process)"
  return true

proc stopLiveMcp*() =
  ## No-op for clean process exit.
  ##
  ## Mummy `close()` + ORC has raced into SIGSEGV on destroy in headless
  ## probes; the server is bound to the play process lifetime and dies with it
  ## (task requirement). Leaving the thread running until process teardown is
  ## intentional.
  discard
