import
  std/os,
  decompbound/[manifest, rom_pipeline]

proc engineImages*(extractRoot: string): array[2, seq[uint8]] =
  ## Return the user's ROM and an independently checked rebuild of current source.
  let layout = parseManifestFile("manifest.json")
  result[0] = readGoldBaserom()
  createDir(extractRoot)
  discard extractRegions(layout, result[0], extractRoot)
  result[1] = rebuildRom(layout, extractRoot)
  doAssert romsEqual(result[0], result[1]), "Engine tests require a byte-identical rebuild"
