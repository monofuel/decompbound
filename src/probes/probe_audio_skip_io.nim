## Headless timing: getDialogueText + HDMA-style bundle write + OpenAL queueData.
## No GUI window. Usage: nim r src/probes/probe_audio_skip_io.nim

import
  std/[monotimes, os, strformat, times],
  pixie,
  slappy,
  ../decompbound/[cpu, policy, ppu, save_state, snesbus]

const
  RomPath = "bin/Earthbound (U) [!].smc"
  StatePath = "bin/states/llm/onett_start.state"
  SamplesPerFrame = 32000 div 60
  BytesPerFrame = SamplesPerFrame * 4

proc main() =
  ## Time dialogue decode, diagnostic bundle I/O, and OpenAL queue cost.
  let rom = policy.readRomFile(RomPath)
  var snes = newSnesBus(rom)
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(StatePath)), snes, cpu)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  for _ in 0 ..< 30:
    policy.stepOneFrame(snes, cpu, img)

  var maxUs, sumUs: int64
  const N = 500
  for i in 0 ..< N:
    let t0 = getMonoTime()
    discard policy.getDialogueText(snes)
    let us = (getMonoTime() - t0).inMicroseconds
    sumUs += us
    if us > maxUs: maxUs = us
  echo &"getDialogueText n={N} avg={sumUs.float/N.float:.1f}us max={maxUs}us"

  maxUs = 0
  sumUs = 0
  createDir("bin/autoshots")
  const Nb = 20
  for i in 0 ..< Nb:
    let t0 = getMonoTime()
    img.writeFile("bin/autoshots/_bundle_probe.png")
    let rf = open("bin/autoshots/_bundle_regs.txt", fmWrite)
    rf.writeLine("probe")
    for pal in 0 ..< 16:
      var row = ""
      for c in 0 ..< 16:
        row.add &" {snes.cgram[pal * 16 + c]:04X}"
      rf.writeLine(row)
    rf.close()
    let tf = open("bin/autoshots/_scanline_probe.txt", fmWrite)
    for l in 0 ..< 224:
      tf.writeLine(&"line {l}")
    tf.close()
    let us = (getMonoTime() - t0).inMicroseconds
    sumUs += us
    if us > maxUs: maxUs = us
  echo &"bundle write n={Nb} avg={sumUs.float/Nb.float/1000.0:.2f}ms max={maxUs.float/1000.0:.2f}ms"
  removeFile("bin/autoshots/_bundle_probe.png")
  removeFile("bin/autoshots/_bundle_regs.txt")
  removeFile("bin/autoshots/_scanline_probe.txt")

  # OpenAL stream path (no window): queue silence at ~60Hz
  slappyInit()
  let ss = newStreamingSource(frequency = 32000, channels = 2, bits = 16)
  var pcm = newSeq[uint8](BytesPerFrame)
  for _ in 0 ..< 3:
    ss.queueData(pcm)
  sleep(30)

  maxUs = 0
  sumUs = 0
  const Nq = 600  # ~10s at 60Hz
  for i in 0 ..< Nq:
    ss.pump()
    let t0 = getMonoTime()
    ss.queueData(pcm)
    let us = (getMonoTime() - t0).inMicroseconds
    sumUs += us
    if us > maxUs: maxUs = us
    sleep(16)
  echo &"OpenAL queueData n={Nq} avg={sumUs.float/Nq.float:.1f}us max={maxUs}us ({maxUs.float/1000.0:.2f}ms)"

  sleep(200)  # force underrun
  let t1 = getMonoTime()
  for _ in 0 ..< 10:
    ss.queueData(pcm)
  ss.pump()
  echo &"post-underrun 10x queue: {(getMonoTime()-t1).inMicroseconds}us"

  ss.close()
  slappyClose()
  echo "DONE probe_audio_skip_io"

main()
