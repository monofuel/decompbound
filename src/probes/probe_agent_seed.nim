## Audit Agent product seed: must not be solely followRoute trail policy.
## Prints AgentOutdoorPolicy / system prompt contracts for docs/grok_play_work.md.
## Usage: nim r src/probes/probe_agent_seed.nim

import
  std/[strutils, os],
  ../tools/[llm_mock_policies, llm_ai]

proc main() =
  ## Verify Agent seed is intent-based and AgentSystemPrompt demotes trails.
  let agent = AgentOutdoorPolicy
  # Policy body must not invoke followRoute(...); comments mentioning the ban are ok.
  doAssert "followRoute(" notin agent,
    "AgentOutdoorPolicy must not call followRoute(...)"
  doAssert "talk" in agent and "nearestEntity" in agent
  doAssert "goToward" in agent or "scene" in agent

  let scripted = PokeyVisitPolicy
  doAssert "followRoute" in scripted,
    "Scripted PokeyVisitPolicy still uses followRoute as referee"

  doAssert "followRoute" in AgentSystemPrompt or "Scripted" in AgentSystemPrompt
  doAssert "scene" in AgentSystemPrompt.toLowerAscii or
    "SCENE" in AgentSystemPrompt or "intent" in AgentSystemPrompt.toLowerAscii
  doAssert "talk" in AgentSystemPrompt

  # Named selection
  doAssert selectMockPolicyByName("agent") == AgentOutdoorPolicy
  doAssert selectMockPolicyByName("pokey") == PokeyVisitPolicy

  echo "AGENT_SEED_OK: AgentOutdoorPolicy len=", agent.len,
    " has_talk=", ("talk" in agent),
    " has_followRoute=", ("followRoute" in agent)
  echo "SCRIPTED_REFEREE: PokeyVisit has followRoute=", ("followRoute" in scripted)
  echo "SYSTEM_PROMPT: chars=", AgentSystemPrompt.len,
    " demotes_trails=", ("Scripted" in AgentSystemPrompt or
      "not" in AgentSystemPrompt.toLowerAscii)

when isMainModule:
  main()
