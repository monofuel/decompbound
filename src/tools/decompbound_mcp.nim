## Goal 5 playthrough co-pilot MCP server (MCPort).
##
## Read-only tools over the current EarthBound playthrough. Distinct from Goal 4
## (LLM *plays* the game): this is for "help me with *my* save" questions.
##
## MVP: get_party_vitals — party HP/PP from the battery .srm (same offsets as
## sram_info / docs/sram-format.md). Live WRAM / inventory / PSI later.
##
## Run from repo root:
##   make mcp
##   nim r src/tools/decompbound_mcp.nim
## HTTP: http://localhost:4343/mcp  (avoids FFXIV MCP on :4242)

import
  std/[json, options, os, strformat, strutils],
  mcport,
  ../decompbound/[item_table, party_sram]

const
  ServerName = "decompbound"
  ServerVersion = "0.1.0"
  DefaultHost = "localhost"
  DefaultPort = 4343
  EnvSrm = "DECOMPBOUND_SRM"

proc resolveSrmPath(arguments: JsonNode): string =
  ## Optional tool arg srm_path, else DECOMPBOUND_SRM, else default battery path.
  if arguments != nil and arguments.hasKey("srm_path") and arguments["srm_path"].kind == JString:
    let p = arguments["srm_path"].getStr()
    if p.len > 0:
      return p
  let env = getEnv(EnvSrm)
  if env.len > 0:
    return env
  return DefaultSrmPath

proc partyVitalsToJson(report: PartyVitalsReport): JsonNode =
  ## Structured payload for get_party_vitals.
  var members = newJArray()
  for m in report.members:
    members.add memberToJson(m)
  result = %*{
    "srmPath": report.srmPath,
    "source": report.source,
    "slotBase": report.slotBase,
    "modifiedAt": report.modifiedAt,
    "empty": report.empty,
    "note": report.note,
    "members": members
  }

var gRomBytes: seq[uint8]  # loaded once at startup for item-name decode

proc getPartyVitalsHandler(arguments: JsonNode): ToolResult {.gcsafe.} =
  ## Handler for get_party_vitals: HP/PP from the battery save.
  {.cast(gcsafe).}:
    let path = resolveSrmPath(arguments)
    let report = readPartyVitals(path, gRomBytes)
    let payload = partyVitalsToJson(report)
    return ToolResult(
      content: @[textContent($payload)],
      structuredContent: some(payload),
      isError: report.empty and report.note.startsWith("SRAM file not found")
    )

proc simpleTool(name, description: string): McpTool =
  ## A no-argument tool with a permissive output schema.
  McpTool(
    name: name,
    description: description,
    inputSchema: %*{
      "type": "object",
      "properties": {
        "srm_path": {
          "type": "string",
          "description": "Optional path to an EarthBound .srm (default: bin/Earthbound (U) [!].srm or DECOMPBOUND_SRM)"
        }
      },
      "required": [],
      "additionalProperties": false,
      "$schema": "http://json-schema.org/draft-07/schema#"
    },
    outputSchema: some(%*{
      "type": "object",
      "properties": {
        "srmPath": {"type": "string"},
        "source": {"type": "string"},
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

proc createServer(): McpServer =
  ## Build the decompbound co-pilot MCP server with registered tools.
  let server = newMcpServer(ServerName, ServerVersion)
  server.registerRichTool(
    simpleTool(
      "get_party_vitals",
      "Get party HP/PP/level/names from the EarthBound battery save (.srm). Playthrough co-pilot (Goal 5) — not the LLM player agent. Save in-game for freshest numbers; this is not live mid-battle WRAM."
    ),
    getPartyVitalsHandler
  )
  return server

when isMainModule:
  let args = commandLineParams()
  var host = DefaultHost
  var port = DefaultPort
  var useStdio = false
  var i = 0
  while i < args.len:
    case args[i]
    of "--stdio":
      useStdio = true
    of "--port":
      inc i
      if i < args.len:
        port = parseInt(args[i])
    of "--host":
      inc i
      if i < args.len:
        host = args[i]
    of "--help", "-h":
      echo "decompbound MCP (Goal 5 playthrough co-pilot)"
      echo "  nim r src/tools/decompbound_mcp.nim [--port 4343] [--host localhost]"
      echo "  nim r src/tools/decompbound_mcp.nim --stdio"
      echo &"  Default SRAM: {DefaultSrmPath} (override with DECOMPBOUND_SRM or tool arg srm_path)"
      quit(0)
    else:
      discard
    inc i

  gRomBytes = loadRomBytes()
  let mcp = createServer()
  if useStdio:
    runStdioServer(mcp)
  else:
    let httpServer = newHttpMcpServer(mcp, logEnabled = false)
    echo &"decompbound MCP on http://{host}:{port}/mcp  (Goal 5 co-pilot)"
    echo &"  tool: get_party_vitals  srm default: {DefaultSrmPath}"
    httpServer.serve(port, host)
