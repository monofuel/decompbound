## Headless audio-path leak isolator: exercises ONLY the slappy/OpenAL streaming
## path (newStreamingSource + queueData + pump) in a tight per-frame loop, with
## NO emulator, NO window, NO GL. Reports BOTH the Nim GC heap (getOccupiedMem)
## and process RssAnon (/proc/self/status), because OpenAL's PCM buffers live in
## the driver — they never show up in the Nim heap, so a pure getOccupiedMem probe
## is blind to them. If RssAnon climbs here while occupied stays flat, the live
## leak is the audio queue (buffers not reclaimed by pump fast enough / at all).
##
## Usage: nim r src/probes/probe_audio_leak.nim [nopump] [fast] [frames=N]
##   nopump   skip ss.pump() each frame (simulates the "never reclaim" bug to prove
##            the probe can actually SEE an OpenAL-side leak — expect RssAnon to climb).
##   fast     run flat-out (no real-time pacing). NOTE: without pacing, playback
##            can't keep up with queueing so pump has nothing to reclaim yet and
##            it LOOKS like a leak. Default paces to ~60fps so pump is tested fairly.
##
## Needs a working OpenAL device; if none is present (headless CI) it says so and
## exits 0 rather than failing — this is a dig tool, not a gate.

import
  std/[os, strformat, strutils],
  slappy

const SamplesPerFrame = 32000 div 60  # match play.nim's stereo 16-bit frame chunk

proc readRssAnonKb(): int =
  ## Linux-only: parse RssAnon (anonymous resident set, KB) from /proc/self/status.
  ## Returns -1 if unavailable so callers can note "RSS unsupported here".
  try:
    for line in lines("/proc/self/status"):
      if line.startsWith("RssAnon:"):
        for tok in line.splitWhitespace():
          if tok.len > 0 and tok[0].isDigit:
            return parseInt(tok)
  except CatchableError:
    discard
  -1

proc main() =
  let doPump = "nopump" notin commandLineParams()
  let paced = "fast" notin commandLineParams()
  var frames = if paced: 1800 else: 3600  # paced: ~30s real-time; fast: instant
  for p in commandLineParams():
    if p.startsWith("frames="):
      frames = parseInt(p["frames=".len .. ^1])

  try:
    slappyInit()
  except SlappyError as e:
    echo "no OpenAL device available (", e.msg, ") — cannot exercise audio path here; skipping."
    quit(0)

  let ss = newStreamingSource(frequency = 32000, channels = 2, bits = 16)
  echo &"mode: pump={doPump} frames={frames} chunk={SamplesPerFrame * 4} bytes/frame"

  # A fixed non-silent PCM chunk (a low square wave) so OpenAL actually allocates
  # and plays through buffers exactly as it does live.
  var pcm = newSeq[uint8](SamplesPerFrame * 4)
  for s in 0 ..< SamplesPerFrame:
    let v = if (s div 16) mod 2 == 0: 4000'i16 else: -4000'i16
    let off = s * 4
    pcm[off + 0] = (v and 0xFF).uint8
    pcm[off + 1] = ((v shr 8) and 0xFF).uint8
    pcm[off + 2] = (v and 0xFF).uint8
    pcm[off + 3] = ((v shr 8) and 0xFF).uint8

  for i in 0 ..< 120:  # warmup — let the device/source reach steady state.
    ss.queueData(pcm)
    if doPump: ss.pump()

  let heapBefore = getOccupiedMem()
  let rssBefore = readRssAnonKb()
  for i in 0 ..< frames:
    ss.queueData(pcm)
    if doPump: ss.pump()
    if paced: sleep(16)  # ~60fps so OpenAL playback keeps pace with queueing
    if (i + 1) mod 600 == 0:
      echo &"  frame {i+1}: heap={getOccupiedMem() div 1024} KB rssAnon={readRssAnonKb()} KB"
  let heapAfter = getOccupiedMem()
  let rssAfter = readRssAnonKb()

  echo ""
  let heapPerFrame = (heapAfter - heapBefore) div frames
  echo &"NIM-HEAP: {(heapAfter - heapBefore) div 1024} KB over {frames} frames = {heapPerFrame} B/frame"
  if rssBefore >= 0 and rssAfter >= 0:
    let rssKbPerMin = (rssAfter - rssBefore).float / (frames.float / 60.0) * 60.0
    echo &"RSS-ANON: {rssAfter - rssBefore} KB over {frames} frames = {rssKbPerMin/1024.0:.1f} MB/min"
    echo "  ^ if this climbs while NIM-HEAP is flat, the leak is OpenAL-side (the live-only leak)."
  else:
    echo "RSS-ANON: unavailable on this platform."

  slappyClose()

main()
