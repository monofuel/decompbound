## Shared PCM output, mixer sync, and wall-clock pumping for `MusicPlayer`.
##
## Owns Slappy streaming and optional `SystemVolume` when enabled. Disabled
## output still renders the player for silent `--mute` smoke.

import
  std/[math, monotimes, os, strformat, times],
  slappy,
  ./[music_player, system_volume]

type
  MusicOutput* = ref object
    player*: MusicPlayer
    volume*: int
    muted*: bool
    level*: float32
    underruns*: int
    audioEnabled*: bool
    stream: StreamingSource
    systemVolume: SystemVolume
    usingSystemVolume: bool
    pendingMute, muteSent, pendingPercent, percentSent: bool
    deviceOpen: bool
    closed: bool
    trace: bool
    volumeError: string
    audioCarry: int64
    lastAudio: MonoTime
    audioStarted: bool
    pcm: seq[int16]
    bytes: seq[uint8]

const
  MaxAudioDelayNs = 100_000_000'i64
  AudioChunkFrames = 512
  AudioPrefillFrames = MusicSampleRate div 20
  NanosecondsPerSecond = 1_000_000_000'i64
  DefaultVolume = 80
  MaxPercent = 100

proc requireOutput(output: MusicOutput) =
  ## Reject a missing or already closed output handle.
  if output.isNil:
    raise newException(ValueError, "music output is nil")
  if output.closed:
    raise newException(ValueError, "music output is closed")

proc resetAudio(output: MusicOutput) =
  ## Drop queued audio immediately on song changes, stop, or pause transitions.
  if output.stream != nil:
    output.stream.flush()
  output.audioCarry = 0
  output.lastAudio = getMonoTime()
  output.level = 0
  output.audioStarted = false

proc applyLocalGain(output: MusicOutput) =
  ## Apply stored volume or local mute to OpenAL when the mixer is not in control.
  if not output.deviceOpen:
    return
  if output.usingSystemVolume:
    listener.gain = if output.pendingMute or output.pendingPercent: 0 else: 1
  elif output.muted:
    listener.gain = 0
  else:
    listener.gain = output.volume.float32 / MaxPercent.float32

proc syncMixer(output: MusicOutput) =
  ## Preserve local requests until actual mixer readback confirms them, guarding attachment gain.
  if output.systemVolume == nil: return
  let
    wasUsing = output.usingSystemVolume
    wasPending = output.pendingMute or output.pendingPercent
    previousVolume = output.volume
    previousMute = output.muted
  output.systemVolume.poll()
  if output.trace and output.systemVolume.lastError != output.volumeError:
    output.volumeError = output.systemVolume.lastError
    if output.volumeError.len > 0: echo "systemVolume: ", output.volumeError
  if output.systemVolume.available:
    output.usingSystemVolume = true
    if output.pendingPercent and not output.percentSent:
      output.systemVolume.setPercent(output.volume)
      output.percentSent = true
    if output.pendingMute and not output.muteSent:
      output.systemVolume.setMuted(output.muted)
      output.muteSent = true
    if output.systemVolume.writesSettled:
      output.volume = output.systemVolume.percent
      output.muted = output.systemVolume.muted
      output.pendingPercent = false
      output.percentSent = false
      output.pendingMute = false
      output.muteSent = false
    applyLocalGain(output)
    if output.trace and not output.pendingMute and not output.pendingPercent and
        (not wasUsing or wasPending or previousVolume != output.volume or previousMute != output.muted):
      echo &"systemVolume={output.volume} muted={output.muted} gain={listener.gain:.2f}"
  else:
    if wasUsing:
      output.volume = clamp(output.volume, 0, MaxPercent)
      output.pendingMute = true
      output.pendingPercent = true
    output.usingSystemVolume = false
    output.muteSent = false
    output.percentSent = false
    applyLocalGain(output)

proc openMusicOutput*(player: MusicPlayer, enabled = true, trace = false): MusicOutput =
  ## Open PCM output for `player`. Disabled mode never initializes a device.
  if player.isNil:
    raise newException(ValueError, "music player is nil")
  result = MusicOutput(
    player: player,
    volume: DefaultVolume,
    muted: false,
    audioEnabled: enabled,
    trace: trace,
    lastAudio: getMonoTime())
  if not enabled:
    return
  slappyInit()
  result.deviceOpen = true
  result.stream = newStreamingSource(
    frequency = MusicSampleRate, channels = 2, bits = 16)
  listener.gain = result.volume.float32 / MaxPercent.float32
  result.systemVolume = openSystemVolume(getCurrentProcessId())

proc close*(output: MusicOutput) =
  ## Release stream, mixer, and Slappy; safe to call more than once.
  if output.isNil or output.closed:
    return
  output.closed = true
  resetAudio(output)
  output.player.stop()
  if output.stream != nil:
    output.stream.close()
    output.stream = nil
  if output.systemVolume != nil:
    output.systemVolume.close()
    output.systemVolume = nil
  if output.deviceOpen:
    slappyClose()
    output.deviceOpen = false

proc start*(output: MusicOutput, songId: int) =
  ## Flush queued audio, start `songId`, and prebuffer a short lead.
  requireOutput(output)
  resetAudio(output)
  output.player.startTrack(songId)
  output.audioCarry = AudioPrefillFrames.int64 * NanosecondsPerSecond
  output.lastAudio = getMonoTime()

proc stop*(output: MusicOutput) =
  ## Flush queued audio and stop the player.
  requireOutput(output)
  resetAudio(output)
  output.player.stop()

proc setPaused*(output: MusicOutput, paused: bool) =
  ## Flush on pause or resume; resume prebuffers without advancing the APU while paused.
  requireOutput(output)
  if paused:
    if output.player.state == Playing:
      resetAudio(output)
      output.player.togglePause()
  elif output.player.state == Paused:
    resetAudio(output)
    output.player.togglePause()
    output.audioCarry = AudioPrefillFrames.int64 * NanosecondsPerSecond

proc setPercent*(output: MusicOutput, percent: int) =
  ## Remember volume changes until backend readback confirms the requested percentage.
  requireOutput(output)
  if percent < 0 or percent > MaxPercent:
    raise newException(ValueError, "percent must be in 0..100")
  output.volume = percent
  output.pendingPercent = true
  output.percentSent = false
  if output.usingSystemVolume and output.systemVolume.available:
    output.systemVolume.setPercent(percent)
    output.percentSent = true
  applyLocalGain(output)

proc setMuted*(output: MusicOutput, muted: bool) =
  ## Silence locally until the backend confirms mute or unmute, preserving percentage.
  requireOutput(output)
  output.muted = muted
  output.pendingMute = true
  output.muteSent = false
  if output.usingSystemVolume and output.systemVolume.available:
    output.systemVolume.setMuted(muted)
    output.muteSent = true
  applyLocalGain(output)

proc pump*(output: MusicOutput) =
  ## Bound wall-clock audio, queue PCM, and sync the process mixer stream.
  requireOutput(output)
  syncMixer(output)
  let now = getMonoTime()
  if output.stream != nil:
    output.stream.pump()
  if output.player.state != Playing:
    output.lastAudio = now
    return
  let elapsed = min((now - output.lastAudio).inNanoseconds, MaxAudioDelayNs)
  output.lastAudio = now
  if output.stream != nil and output.audioStarted and not output.stream.playing:
    inc output.underruns
    output.audioCarry += AudioPrefillFrames.int64 * NanosecondsPerSecond
  output.audioCarry += elapsed * MusicSampleRate
  let frames = int(output.audioCarry div NanosecondsPerSecond)
  if frames < AudioChunkFrames:
    return
  output.audioCarry -= frames.int64 * NanosecondsPerSecond
  output.player.renderPcm(frames, output.pcm)
  var sumSquares = 0.0
  output.bytes.setLen(output.pcm.len * 2)
  for i, sample in output.pcm:
    let bits = cast[uint16](sample)
    output.bytes[i * 2] = (bits and 0xFF).uint8
    output.bytes[i * 2 + 1] = (bits shr 8).uint8
    sumSquares += sample.float64 * sample.float64
  if output.pcm.len > 0:
    let level = sqrt(sumSquares / output.pcm.len.float64) / 32768 * 8
    output.level = max(output.level * 0.8, min(1.0, level).float32)
  if output.stream != nil:
    output.stream.queueData(output.bytes)
    output.audioStarted = true
