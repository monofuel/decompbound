import
  std/[os],
  decompbound/music_player

proc main() =
  ## Exercise actual ROM packages, audio continuity, and transport without a device.
  let
    romPath = if paramCount() > 0: paramStr(1) else: "bin/Earthbound (U) [!].smc"
    library = loadMusicLibrary(romPath)
    reference = newMusicPlayer(library)
    chunked = newMusicPlayer(library)
  defer:
    reference.stop()
    chunked.stop()
  doAssert library.trackIds.len == SongCount
  var
    expected, actual, output: seq[int16]
    nonSilent = 0
  for song in [1, 3, 11, 76]:
    reference.startTrack(song)
    reference.renderPcm(48001, expected)
    doAssert expected.len == 96002
    var nonzero = false
    for sample in expected:
      if sample != 0: nonzero = true
    doAssert nonzero, "Previously audible song became silent: " & $song
    chunked.startTrack(song)
    actual.setLen(0)
    for frames in [0, 1, 15999, 0, 1, 16000, 16000]:
      let beforePause = chunked.renderedFrames
      chunked.togglePause()
      chunked.renderPcm(1000, output)
      doAssert output.len == 0 and chunked.renderedFrames == beforePause
      chunked.togglePause()
      chunked.renderPcm(frames, output)
      actual.add(output)
    doAssert actual == expected, "Chunking or pausing changed PCM for song " & $song
    doAssert chunked.renderedFrames == 48001
  reference.startTrack(1)
  reference.renderPcm(4096, expected)
  chunked.startTrack(3)
  chunked.renderPcm(12000, output)
  chunked.stop()
  chunked.startTrack(1)
  chunked.renderPcm(4096, actual)
  doAssert actual == expected, "Track switching retained a previous APU image"
  for song in library.trackIds:
    chunked.startTrack(song)
    chunked.renderPcm(4096, output)
    doAssert output.len == 8192
    var nonzero = false
    for sample in output:
      if sample != 0: nonzero = true
    if nonzero: inc nonSilent
  echo "Music: all ", library.trackIds.len, " tracks load/render; ", nonSilent,
    " produce nonzero PCM in the first 4096 frames."
  echo "Songs 1/3/11/76: nonzero PCM and exact chunk/pause continuity across command boundaries."

when isMainModule:
  main()
