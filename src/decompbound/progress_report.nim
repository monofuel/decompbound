## Build × Comprehension progress from the JSON manifest (docs/terms.md).

import
  std/[strformat, strutils, tables],
  ./[common, manifest]

type
  AxisCell* = object
    build*: BuildLevel
    comprehension*: ComprehensionLevel
    bytes*: int
    regions*: int

  ProgressReport* = object
    romSize*: int
    byCell*: seq[AxisCell]
    byBuild*: array[BuildLevel, int]
    byComprehension*: array[ComprehensionLevel, int]
    ## Explained column only counts named evidence-bearing regions (not blobs).
    explainedBytes*: int
    reproduceBytes*: int
    copyBytes*: int
    unknownBytes*: int
    identifiedBytes*: int

proc computeProgress*(m: Manifest): ProgressReport =
  ## Aggregate manifest regions into Build × Comprehension byte counts.
  ## Coincidental zero-fill is not counted separately — only claimed regions.
  result.romSize = m.romSize
  var cells = initTable[(BuildLevel, ComprehensionLevel), AxisCell]()
  for r in m.regions:
    let key = (r.build, r.comprehension)
    if key notin cells:
      cells[key] = AxisCell(build: r.build, comprehension: r.comprehension)
    cells[key].bytes += r.length
    cells[key].regions += 1
    result.byBuild[r.build] += r.length
    result.byComprehension[r.comprehension] += r.length
  for _, cell in cells:
    result.byCell.add cell
  result.copyBytes = result.byBuild[blCopy]
  result.reproduceBytes = result.byBuild[blReproduce]
  result.unknownBytes = result.byComprehension[clUnknown]
  result.identifiedBytes = result.byComprehension[clIdentified]
  result.explainedBytes = result.byComprehension[clExplained]

proc formatProgressMarkdown*(p: ProgressReport): string =
  ## Human-readable report for report.md / CLI.
  var lines: seq[string]
  lines.add "# Decomp progress (Build × Comprehension)"
  lines.add ""
  lines.add "Axes per `docs/terms.md`. Counts are **claimed region bytes** from"
  lines.add "`manifest.json` — not coincidental matches against gold."
  lines.add ""
  lines.add &"ROM size: **{p.romSize}** bytes."
  lines.add ""
  lines.add "## By Build"
  lines.add ""
  lines.add &"| Level | Bytes | % of ROM |"
  lines.add &"|---|---:|---:|"
  for b in BuildLevel:
    let pct = 100.0 * p.byBuild[b].float / p.romSize.float
    lines.add &"| `{b}` | {p.byBuild[b]} | {pct:.3f}% |"
  lines.add ""
  lines.add "## By Comprehension"
  lines.add ""
  lines.add &"| Level | Bytes | % of ROM |"
  lines.add &"|---|---:|---:|"
  for c in ComprehensionLevel:
    let pct = 100.0 * p.byComprehension[c].float / p.romSize.float
    lines.add &"| `{c}` | {p.byComprehension[c]} | {pct:.3f}% |"
  lines.add ""
  lines.add "## Matrix cells"
  lines.add ""
  lines.add "| Build | Comprehension | Bytes | Regions |"
  lines.add "|---|---|---:|---:|"
  for cell in p.byCell:
    lines.add &"| `{cell.build}` | `{cell.comprehension}` | {cell.bytes} | {cell.regions} |"
  lines.add ""
  lines.add "## Headline"
  lines.add ""
  lines.add &"- **explained** (comprehension): {p.explainedBytes} bytes " &
    &"({100.0 * p.explainedBytes.float / p.romSize.float:.4f}%)"
  lines.add &"- **reproduce** (build): {p.reproduceBytes} bytes " &
    &"({100.0 * p.reproduceBytes.float / p.romSize.float:.4f}%)"
  lines.add &"- **copy/unknown residual** remains the bulk of the map until more RE."
  lines.add ""
  result = lines.join("\n")
