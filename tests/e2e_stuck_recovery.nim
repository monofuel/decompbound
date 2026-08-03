## Stuck recovery: FreezePolicy + low stuck-threshold must emit STUCK_RECOVERY
## via the real llm_ai harness (shipped path), not a reimplementation.
## Captures process output by invoking the binary after compile via `nim r`.

import
  std/[os, osproc, strutils]

proc main() =
  ## Run llm_ai freeze seed headless; require STUCK_RECOVERY in stdout.
  let cmd = "nim r -d:release src/tools/llm_ai.nim -- --mock --headless " &
    "--frames 80 --llm-interval 4 --stuck-threshold 2 --speed 0 " &
    "--load-state-path bin/states/llm/onett_start.state --scenario freeze"
  let (outp, code) = execCmdEx(cmd)
  echo outp
  doAssert code == 0, "llm_ai freeze run failed code=" & $code
  doAssert "STUCK_DETECTED" in outp or "STUCK_RECOVERY" in outp,
    "expected stuck recovery lines in harness output"
  doAssert "STUCK_RECOVERY" in outp,
    "expected STUCK_RECOVERY action (rollback or replan), not silent thrash"
  doAssert "followRoute(" notin outp or "FreezePolicy" in outp or "freeze" in outp.toLowerAscii
  # Freeze seed body has no followRoute
  doAssert "scenario=freeze" in outp or "Freeze" in outp or "POLICY: scenario=freeze" in outp or
    "initial policy seeded" in outp
  echo "OK test_stuck_recovery: harness fired STUCK_RECOVERY under FreezePolicy"

when isMainModule:
  main()
