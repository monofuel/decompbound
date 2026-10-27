## APU samples and optional stereo PCM for one player frame.

import
  ./[replay, snesbus]

type
  FrameAudio* = object
    ticks*: int
    pcm*: seq[uint8]

const
  BytesPerStereoSample = 4

proc initFrameAudio*(capture: bool): FrameAudio =
  ## Allocate a PCM buffer only when the caller will stream audio.
  if capture:
    result.pcm = newSeq[uint8](ReplayApuTicksPerFrame * BytesPerStereoSample)

proc packSample*(pcm: var seq[uint8], index: int, left, right: int16) =
  ## Write a stereo signed 16-bit sample in little-endian order.
  let
    offset = index * BytesPerStereoSample
    l = cast[uint16](left)
    r = cast[uint16](right)
  pcm[offset] = (l and 0xff).uint8
  pcm[offset + 1] = (l shr 8).uint8
  pcm[offset + 2] = (r and 0xff).uint8
  pcm[offset + 3] = (r shr 8).uint8

proc tickApuSample*(audio: var FrameAudio, snes: SnesBus, capture = true) =
  ## Advance the APU once and optionally capture its sample.
  let (left, right) = snes.tickApu()
  if capture and audio.pcm.len > 0 and audio.ticks < ReplayApuTicksPerFrame:
    packSample(audio.pcm, audio.ticks, left, right)
  inc audio.ticks

proc finishFrameAudio*(audio: var FrameAudio, snes: SnesBus, capture = true) =
  ## Advance the APU until the frame's replay cadence is reached.
  while audio.ticks < ReplayApuTicksPerFrame:
    audio.tickApuSample(snes, capture)
