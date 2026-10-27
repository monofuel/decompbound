## Verify player audio cadence and stereo sample packing without a ROM.

import
  ../src/decompbound/[frame_audio, replay, save_state, snesbus]

proc testSamplePacking() =
  ## Signed samples retain their little-endian bit patterns.
  var pcm = newSeq[uint8](8)
  packSample(pcm, 1, -2'i16, 0x1234'i16)
  doAssert pcm == @[0'u8, 0, 0, 0, 0xfe, 0xff, 0x34, 0x12]

proc testFrameCadence() =
  ## Captured and silent frames advance the real APU by the same 533 ticks.
  let
    audible = newSnesBus(@[])
    silent = newSnesBus(@[])
    reference = newSnesBus(@[])
    audibleCpu = audible.resetCpu()
    silentCpu = silent.resetCpu()
    referenceCpu = reference.resetCpu()
    initial = serializeState(reference, referenceCpu)
  var
    captured = initFrameAudio(true)
    muted = initFrameAudio(false)
  for _ in 0 ..< 262 * 2:
    captured.tickApuSample(audible)
    muted.tickApuSample(silent)
  captured.finishFrameAudio(audible)
  muted.finishFrameAudio(silent)
  for _ in 0 ..< ReplayApuTicksPerFrame:
    discard reference.tickApu()
  doAssert captured.ticks == ReplayApuTicksPerFrame
  doAssert muted.ticks == ReplayApuTicksPerFrame
  doAssert captured.pcm.len == ReplayApuTicksPerFrame * 4
  doAssert muted.pcm.len == 0
  let expected = serializeState(reference, referenceCpu)
  doAssert expected != initial
  doAssert serializeState(audible, audibleCpu) == expected
  doAssert serializeState(silent, silentCpu) == expected
  captured.finishFrameAudio(audible)
  doAssert serializeState(audible, audibleCpu) == expected

  # Reuse the captured buffer through a muted frame and back to capture.
  for i in 0 ..< captured.pcm.len:
    captured.pcm[i] = 0xa5'u8
  captured.ticks = 0
  for _ in 0 ..< 262 * 2:
    captured.tickApuSample(audible, false)
  captured.finishFrameAudio(audible, false)
  for _ in 0 ..< ReplayApuTicksPerFrame:
    discard reference.tickApu()
  doAssert captured.ticks == ReplayApuTicksPerFrame
  for b in captured.pcm:
    doAssert b == 0xa5'u8
  doAssert serializeState(audible, audibleCpu) == serializeState(reference, referenceCpu)

  captured.ticks = 0
  for _ in 0 ..< 262 * 2:
    captured.tickApuSample(audible, true)
  captured.finishFrameAudio(audible, true)
  for _ in 0 ..< ReplayApuTicksPerFrame:
    discard reference.tickApu()
  doAssert captured.ticks == ReplayApuTicksPerFrame
  doAssert captured.pcm[0] != 0xa5'u8
  doAssert serializeState(audible, audibleCpu) == serializeState(reference, referenceCpu)

testSamplePacking()
testFrameCadence()
