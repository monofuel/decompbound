import
  std/[math, os, parseopt, strformat, strutils],
  ../decompbound/music_player

const
  DefaultRom = "bin/Earthbound (U) [!].smc"
  StereoChannels = 2
  SampleBytes = 2
  Help = """Usage: nim r src/tools/sound_explore.nim [ROM] --song N [--seconds S | --frames F] [--out PATH]
Render numeric EarthBound music tracks from your own ROM to a local WAV.
--frames counts stereo sample frames at 32000 Hz. Defaults: song 1, 5 seconds.
"""

proc writeWav(path: string, samples: openArray[int16]) =
  ## Write interleaved stereo PCM as a little-endian 16-bit WAV.
  let
    dataLength = samples.len * SampleBytes
    parent = path.parentDir
  if dataLength > high(uint32).int - 36:
    raise newException(ValueError, "PCM is too large for a RIFF WAV.")
  if parent.len > 0: createDir(parent)
  var data = newStringOfCap(44 + dataLength)
  proc u16(value: uint16) =
    ## Append one little-endian word to the WAV buffer.
    data.add(char(value and 0xFF))
    data.add(char(value shr 8))
  proc u32(value: uint32) =
    ## Append one little-endian double word to the WAV buffer.
    for shift in [0, 8, 16, 24]: data.add(char((value shr shift) and 0xFF))
  data.add("RIFF")
  u32((36 + dataLength).uint32)
  data.add("WAVEfmt ")
  u32(16)
  u16(1)
  u16(StereoChannels)
  u32(MusicSampleRate)
  u32(MusicSampleRate * StereoChannels * SampleBytes)
  u16(StereoChannels * SampleBytes)
  u16(SampleBytes * 8)
  data.add("data")
  u32(dataLength.uint32)
  for sample in samples: u16(cast[uint16](sample))
  writeFile(path, data)

proc main() =
  ## Use the same validated loading and playback engine as Pocket Jukebox.
  var
    romPath = DefaultRom
    song = 1
    seconds = 5
    frames = 0
    outPath, pending: string
  proc option(key, value: string) =
    ## Apply one complete value-bearing command-line option.
    case key
    of "song": song = parseInt(value)
    of "seconds": seconds = parseInt(value)
    of "frames": frames = parseInt(value)
    of "rom": romPath = value
    of "out": outPath = value
    else: raise newException(ValueError, "Unknown option: " & key)
  for kind, key, value in getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      if key in ["help", "h"]:
        stdout.write(Help)
        return
      if pending.len > 0: raise newException(ValueError, "Missing value for --" & pending)
      if key notin ["song", "seconds", "frames", "rom", "out"]:
        raise newException(ValueError, "Unknown option: " & key)
      if value.len == 0: pending = key
      else: option(key, value)
    of cmdArgument:
      if pending.len > 0:
        option(pending, key)
        pending = ""
      else: romPath = key
    of cmdEnd: discard
  if pending.len > 0: raise newException(ValueError, "Missing value for --" & pending)
  if seconds <= 0 or frames < 0: raise newException(ValueError, "Duration must be positive.")
  if outPath.len == 0: outPath = &"bin/jukebox_song{song:03d}.wav"
  let
    player = newMusicPlayer(loadMusicLibrary(romPath))
    total = if frames > 0: frames else: seconds * MusicSampleRate
  defer: player.stop()
  player.startTrack(song)
  var pcm: seq[int16]
  player.renderPcm(total, pcm)
  writeWav(outPath, pcm)
  var
    peak = 0
    nonzero = 0
    sumSquares = 0.0
  for sample in pcm:
    peak = max(peak, abs(sample.int))
    if sample != 0: inc nonzero
    sumSquares += sample.float64 * sample.float64
  let rms = if pcm.len > 0: sqrt(sumSquares / pcm.len.float64) else: 0.0
  echo &"song {song}: wrote {outPath}: {total.float64 / MusicSampleRate:.2f}s, {nonzero}/{pcm.len} nonzero samples, peakAbs={peak}, rms={rms:.1f}"

when isMainModule:
  main()
