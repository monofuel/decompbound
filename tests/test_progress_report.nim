## Progress axes from manifest — no silent promotion of blobs to explained.

import
  decompbound/[common, manifest, progress_report]

block committedManifestAxes:
  let m = parseManifestFile("manifest.json")
  doAssert validateManifest(m).ok
  let p = computeProgress(m)
  doAssert p.romSize == EarthboundRomSize
  doAssert p.copyBytes + p.reproduceBytes + p.byBuild[blModify] == p.romSize
  doAssert p.unknownBytes + p.identifiedBytes + p.explainedBytes == p.romSize
  # Explained must equal sum of explained cells only (adopted asm regions).
  doAssert p.explainedBytes > 0
  doAssert p.explainedBytes == p.byComprehension[clExplained]
  # Blobs are unknown/copy — must not count as explained.
  for r in m.regions:
    if r.kind == rkBlob:
      doAssert r.comprehension == clUnknown
      doAssert r.build == blCopy
  echo formatProgressMarkdown(p)

echo "[test_progress_report] ok"
