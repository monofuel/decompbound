## Manifest parse + coverage (tile) tests — synthetic maps and committed manifest.

import
  std/[os, strformat],
  decompbound/[common, manifest]

block syntheticFullTile:
  let raw = """
  {
    "version": 1,
    "romSize": 3145728,
    "regions": [
      {
        "name": "all",
        "offset": 0,
        "length": 3145728,
        "kind": "blob",
        "source": "blobs/all.bin",
        "build": "copy",
        "comprehension": "unknown"
      }
    ]
  }
  """
  let m = parseManifestString(raw)
  let r = validateManifest(m)
  doAssert r.ok, r.message
  doAssert r.covered == EarthboundRomSize
  doAssert r.gapBytes == 0
  doAssert r.overlapBytes == 0
  doAssert r.covered == 3_145_728

block syntheticTwoRegions:
  let raw = """
  {
    "version": 1,
    "romSize": 3145728,
    "regions": [
      {
        "name": "lo",
        "offset": 0,
        "length": 1048576,
        "kind": "blob",
        "source": "blobs/lo.bin",
        "build": "copy",
        "comprehension": "unknown"
      },
      {
        "name": "hi",
        "offset": 1048576,
        "length": 2097152,
        "kind": "data",
        "source": "blobs/hi.bin",
        "build": "copy",
        "comprehension": "identified",
        "evidence": "split fixture"
      }
    ]
  }
  """
  let m = parseManifestString(raw)
  let r = validateManifest(m)
  doAssert r.ok, r.message
  doAssert r.regionCount == 2
  doAssert r.covered == 3_145_728

block gapDetected:
  let raw = """
  {
    "version": 1,
    "romSize": 3145728,
    "regions": [
      {
        "name": "only",
        "offset": 0,
        "length": 100,
        "kind": "blob",
        "source": "blobs/x.bin",
        "build": "copy",
        "comprehension": "unknown"
      }
    ]
  }
  """
  let r = validateManifest(parseManifestString(raw))
  doAssert not r.ok
  doAssert r.gapBytes > 0

block overlapDetected:
  let raw = """
  {
    "version": 1,
    "romSize": 3145728,
    "regions": [
      {
        "name": "a",
        "offset": 0,
        "length": 2000,
        "kind": "blob",
        "source": "blobs/a.bin",
        "build": "copy",
        "comprehension": "unknown"
      },
      {
        "name": "b",
        "offset": 1000,
        "length": 3144728,
        "kind": "blob",
        "source": "blobs/b.bin",
        "build": "copy",
        "comprehension": "unknown"
      }
    ]
  }
  """
  let r = validateManifest(parseManifestString(raw))
  doAssert not r.ok
  doAssert r.overlapBytes > 0

block committedManifest:
  let path = "manifest.json"
  doAssert fileExists(path), "committed manifest.json must exist at repo root"
  let m = parseManifestFile(path)
  let r = validateManifest(m)
  doAssert r.ok, r.message
  doAssert r.covered == 3_145_728, &"covered={r.covered}"
  doAssert r.gapBytes == 0
  doAssert r.overlapBytes == 0
  echo r.message

echo "[test_manifest] ok"
