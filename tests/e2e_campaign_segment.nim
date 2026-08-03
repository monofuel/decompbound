## Campaign fixture handoff + AgentBuzzBuzz from post_knock (shipped harness).

import
  std/[os, osproc, strutils]

proc main() =
  ## Run llm_ai with --campaign-fixtures from bedroom knock-80 path via home_door.
  ## Expect CAMPAIGN_SEGMENT load and knock=100, then buzz seed.
  let cmd = "nim r -d:release src/tools/llm_ai.nim -- --mock --headless " &
    "--campaign-fixtures --frames 120 --llm-interval 20 --speed 0 " &
    "--load-state-path bin/states/llm/pre_knock_bed.state --scenario agenthome"
  let (outp, code) = execCmdEx(cmd)
  echo outp
  doAssert code == 0, "harness failed"
  doAssert "CAMPAIGN_SEGMENT" in outp, "expected campaign fixture handoff"
  doAssert "knock=100" in outp or "complete=true" in outp
  # Prefer free outdoor synth when present
  if "post_knock_outdoor" in outp:
    doAssert "tg=100" in outp or "AgentFrankPolicy" in outp or "buzzbuzz_pct=40" in outp
  doAssert "knock=100" in outp or "complete=true" in outp or
    "AgentBuzzBuzzPolicy" in outp,
    "expected knock-complete advance after segment load"
  # Policy body for buzz should not be required to be trail-only at top level
  doAssert "scenario=agenthome" in outp or "initial policy" in outp
  echo "OK test_campaign_segment"

when isMainModule:
  main()
