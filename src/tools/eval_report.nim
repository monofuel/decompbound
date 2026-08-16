import
  std/[algorithm, json, os, strformat, strutils]

## eval_report: render runs/*/scorecard.json into a static runs/index.html —
## the hero series (primary metric over runs, discards kept visible) plus a
## per-run table. Numbers-only SVG/HTML; no gameplay content ever lands here.
## Regenerate with `make eval-report`; the artifact is committed history.

const
  RunsDir = "runs"
  OutFile = "runs/index.html"
  ChartW = 900
  ChartH = 320
  PadL = 56
  PadR = 24
  PadT = 24
  PadB = 48
  InkColor = "#1a1a2e"
  MutedColor = "#6b7280"
  GridColor = "#e5e7eb"
  SeriesColor = "#4c6ef5"
  KeepColor = "#2f9e44"
  DiscardColor = "#e03131"
  InconclusiveColor = "#e8890c"

type
  RunRow = object
    utc: string
    ideaId: string
    tier: string
    scaffold: string
    pilot: string
    primaryName: string
    primaryValue: float
    decision: string
    reasons: string
    gates: string
    floorsPass: bool

proc loadRuns(): seq[RunRow] =
  ## Collect every scorecard.json under runs/, sorted chronologically by utc.
  for kind, dir in walkDir(RunsDir):
    if kind != pcDir:
      continue
    let path = dir / "scorecard.json"
    if not fileExists(path):
      continue
    let j = parseJson(readFile(path))
    var row = RunRow()
    row.utc = j["utc"].getStr
    row.ideaId = j["idea_id"].getStr
    row.tier = j["tier"].getStr
    row.primaryName = j["primary_for_ranking"]["name"].getStr
    row.primaryValue = j["primary_for_ranking"]["value"].getFloat
    row.decision = j["decision"].getStr
    var reasons: seq[string]
    for r in j["reason_codes"]:
      reasons.add r.getStr
    row.reasons = reasons.join(" ")
    row.floorsPass = true
    for c in j["hard_constraints"]:
      if not c["pass"].getBool:
        row.floorsPass = false
    let extra = j["domain_extra"]
    row.scaffold = extra{"scaffold_tier"}.getStr("")
    row.pilot = extra{"pilot"}.getStr("")
    if extra.hasKey("gates"):
      var parts: seq[string]
      for name, v in extra["gates"]:
        if not name.startsWith("walk_"):
          parts.add fmt"{name}={v.getInt}"
      row.gates = parts.join(" ")
    result.add row
  result.sort(proc(a, b: RunRow): int = cmp(a.utc, b.utc))

proc decisionColor(decision: string): string =
  ## Status color for a run's gate decision.
  case decision
  of "keep": KeepColor
  of "discard": DiscardColor
  else: InconclusiveColor

proc decisionGlyph(decision: string): string =
  ## Shape marker so decisions never rely on color alone.
  case decision
  of "keep": "●"
  of "discard": "✕"
  else: "◇"

proc heroSvg(runs: seq[RunRow]): string =
  ## Hero series: primary metric per run, connected line, decision-marked
  ## points. Discards stay plotted — the failures are part of the history.
  var maxV = 100.0
  for r in runs:
    if r.primaryValue > maxV:
      maxV = r.primaryValue
  maxV = maxV * 1.1
  let plotW = ChartW - PadL - PadR
  let plotH = ChartH - PadT - PadB
  proc px(i: int): float =
    if runs.len <= 1: PadL.float + plotW.float / 2
    else: PadL.float + plotW.float * i.float / (runs.len - 1).float
  proc py(v: float): float =
    PadT.float + plotH.float * (1.0 - v / maxV)
  var s = fmt"""<svg viewBox="0 0 {ChartW} {ChartH}" role="img" aria-label="primary metric over runs">"""
  for g in 0 .. 4:
    let v = maxV * g.float / 4
    let y = py(v)
    s.add fmt"""<line x1="{PadL}" y1="{y:.1f}" x2="{ChartW - PadR}" y2="{y:.1f}" stroke="{GridColor}" stroke-width="1"/>"""
    s.add fmt"""<text x="{PadL - 8}" y="{y + 4:.1f}" text-anchor="end" font-size="11" fill="{MutedColor}">{v:.0f}</text>"""
  var pts: seq[string]
  for i, r in runs:
    pts.add fmt"{px(i):.1f},{py(r.primaryValue):.1f}"
  if runs.len > 1:
    s.add fmt"""<polyline points="{pts.join(" ")}" fill="none" stroke="{SeriesColor}" stroke-width="2"/>"""
  for i, r in runs:
    let x = px(i)
    let y = py(r.primaryValue)
    let c = decisionColor(r.decision)
    s.add fmt"""<circle cx="{x:.1f}" cy="{y:.1f}" r="5" fill="{c}" stroke="#ffffff" stroke-width="2"><title>{r.utc} {r.ideaId}: {r.primaryName}={r.primaryValue:.0f} ({r.decision})</title></circle>"""
    s.add fmt"""<text x="{x:.1f}" y="{y - 10:.1f}" text-anchor="middle" font-size="11" fill="{InkColor}">{r.primaryValue:.0f}</text>"""
    s.add fmt"""<text x="{x:.1f}" y="{ChartH - PadB + 16}" text-anchor="middle" font-size="10" fill="{MutedColor}">{r.utc[4..7]}</text>"""
  s.add fmt"""<line x1="{PadL}" y1="{ChartH - PadB}" x2="{ChartW - PadR}" y2="{ChartH - PadB}" stroke="{MutedColor}" stroke-width="1"/>"""
  s.add "</svg>"
  return s

proc tableHtml(runs: seq[RunRow]): string =
  ## Per-run table — the accessible view of the same data as the chart.
  var s = """<table><thead><tr>
<th>utc</th><th>idea</th><th>tier</th><th>scaffold</th><th>pilot</th>
<th>primary</th><th>floors</th><th>decision</th><th>reasons</th><th>gates</th>
</tr></thead><tbody>"""
  for r in runs:
    let c = decisionColor(r.decision)
    let floors = if r.floorsPass: "pass" else: "FAIL"
    s.add fmt"""<tr>
<td>{r.utc}</td><td>{r.ideaId}</td><td>{r.tier}</td><td>{r.scaffold}</td><td>{r.pilot}</td>
<td>{r.primaryName}={r.primaryValue:.0f}</td><td>{floors}</td>
<td><span style="color:{c}">{decisionGlyph(r.decision)} {r.decision}</span></td>
<td>{r.reasons}</td><td>{r.gates}</td></tr>"""
  s.add "</tbody></table>"
  return s

proc main() =
  ## Read all scorecards and write the static report page.
  let runs = loadRuns()
  if runs.len == 0:
    echo "eval_report: no scorecards under runs/ — nothing to render"
    quit(1)
  let legend = fmt"""<p class="legend">
<span style="color:{KeepColor}">● keep</span>
<span style="color:{DiscardColor}">✕ discard</span>
<span style="color:{InconclusiveColor}">◇ inconclusive</span>
— discards stay on the chart; deleting failed runs is an anti-pattern.</p>"""
  let html = fmt"""<!doctype html>
<html><head><meta charset="utf-8"><title>llm-play eval runs</title>
<style>
body {{ background: #ffffff; color: {InkColor}; font-family: system-ui, sans-serif; margin: 2rem; }}
h1 {{ font-size: 1.3rem; }}
.legend span {{ margin-right: 1rem; }}
table {{ border-collapse: collapse; font-size: 0.85rem; }}
th, td {{ border: 1px solid {GridColor}; padding: 4px 8px; text-align: left; }}
th {{ background: #f3f4f6; }}
</style></head><body>
<h1>LLM-plays-EarthBound — eval run history</h1>
<p>Primary metric per run ({runs[^1].primaryName} on the latest run). Regenerate with <code>make eval-report</code>.</p>
{heroSvg(runs)}
{legend}
{tableHtml(runs)}
</body></html>
"""
  writeFile(OutFile, html)
  echo fmt"eval_report: wrote {OutFile} ({runs.len} runs)"

when isMainModule:
  main()
