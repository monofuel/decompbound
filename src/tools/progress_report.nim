## Emit Build × Comprehension progress from manifest.json.

import
  std/[os, strformat],
  ../decompbound/[manifest, progress_report]

proc main() =
  ## Load manifest and print / write axis report.
  var
    manifestPath = ManifestDefaultPath
    outPath = "report.md"
  var i = 1
  while i <= paramCount():
    let a = paramStr(i)
    if a == "--manifest" and i < paramCount():
      i += 1
      manifestPath = paramStr(i)
    elif a == "--out" and i < paramCount():
      i += 1
      outPath = paramStr(i)
    i += 1
  let m = parseManifestFile(manifestPath)
  let cov = validateManifest(m)
  if not cov.ok:
    echo cov.message
    quit(1)
  let p = computeProgress(m)
  let md = formatProgressMarkdown(p)
  echo md
  writeFile(outPath, md)
  echo &"\nwrote {outPath}"

main()
