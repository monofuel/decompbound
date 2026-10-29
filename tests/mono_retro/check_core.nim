import
  std/[os, strformat, strutils, tempfiles],
  retro/libretro,
  ../../src/decompbound/rom_pipeline

const
  CorePath = "bin/libretro/decompbound_libretro.so"
  Frames = 120
  SramSize = 8192
  SamplesPerFrame = 533

proc checkMode(dual: bool) =
  ## Exercise mono-retro's actual loader, callbacks, and battery-save handling.
  let
    directory = createTempDir("decompbound-frontend-", "")
  defer: removeDir(directory)
  let
    options: seq[CoreOption] = if dual: @[("decompbound_dual_screen", "enabled")] else: @[]
    height = if dual: 448 else: 224
    session = openCore(absolutePath(CorePath), absolutePath(resolveGoldBaseromPath()), directory,
      options = options)
  var savePath: string
  try:
    doAssert $session.info.libraryName == "Decompbound"
    doAssert session.av.geometry.baseWidth == 256 and session.av.geometry.baseHeight == height.cuint
    doAssert session.av.timing.fps == 60 and session.av.timing.sampleRate == 31980
    for frame in 0 ..< Frames:
      session.step(0)
    doAssert session.frames == Frames.uint64
    doAssert session.videoFrames == Frames.uint64
    doAssert session.audioFrames == (Frames * SamplesPerFrame).uint64
    doAssert session.image != nil
    doAssert session.image.width == 256 and session.image.height == height
    session.save()
    savePath = session.savePath
    doAssert readFile(savePath).len == SramSize
  finally:
    session.close()
  var syntheticSram = repeat('\0', SramSize)
  for index in 0 ..< syntheticSram.len:
    syntheticSram[index] = char(index mod 251)
  writeFile(savePath, syntheticSram)
  let restored = openCore(absolutePath(CorePath), absolutePath(resolveGoldBaseromPath()), directory,
    options = options)
  restored.close()
  doAssert readFile(savePath) == syntheticSram
  echo &"mono-retro headless: {Frames} frames, {Frames * SamplesPerFrame} audio frames, SRAM reload matched."

checkMode(false)
checkMode(true)
