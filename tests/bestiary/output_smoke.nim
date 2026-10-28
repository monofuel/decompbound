include ../../src/decompbound/music_output

proc settle(output: MusicOutput) =
  ## Exercise real asynchronous mixer attachment while preserving requested controls.
  let deadline = getMonoTime() + initDuration(seconds = 5)
  while getMonoTime() < deadline:
    output.pump()
    if output.usingSystemVolume and not output.pendingMute and not output.pendingPercent:
      return
    if output.usingSystemVolume:
      doAssert listener.gain == 0, "Pending backend controls must retain the local silence guard."
    sleep(3)
  raise newException(AssertionDefect, "Mixer requests were not observed before the deadline.")

proc settleControl(control: SystemVolume) =
  ## Wait for actual operation acknowledgement and a subsequent native metadata snapshot.
  let deadline = getMonoTime() + initDuration(seconds = 5)
  while getMonoTime() < deadline:
    control.poll()
    if control.writesSettled: return
    sleep(3)
  raise newException(AssertionDefect, "Native control write did not settle.")

proc waitObserved(control: SystemVolume, percent: int, muted: bool) =
  ## Wait for an external writer's state without running the owning output pump.
  let deadline = getMonoTime() + initDuration(seconds = 5)
  while getMonoTime() < deadline:
    control.poll()
    if control.writesSettled and control.percent == percent and control.muted == muted: return
    sleep(3)
  raise newException(AssertionDefect, "External mixer state was not observed.")

proc main() =
  ## Check early mute/volume, reattachment, pause freeze and ownership with a private server.
  let
    path = if paramCount() > 0: paramStr(1) else: "bin/Earthbound (U) [!].smc"
    library = loadMusicLibrary(path)
    player = newMusicPlayer(library)
    output = openMusicOutput(player)
  defer: output.close()
  output.setMuted(true)
  output.setPercent(37)
  output.start(1)
  doAssert listener.gain == 0
  output.settle()
  doAssert output.volume == 37 and output.muted
  doAssert output.systemVolume.percent == 37 and output.systemVolume.muted
  doAssert listener.gain == 1
  let beforeMute = player.renderedFrames
  for tick in 0 ..< 12:
    sleep(3)
    output.pump()
  doAssert player.renderedFrames > beforeMute, "Mute should keep song time advancing."
  output.setPaused(true)
  let beforePause = player.renderedFrames
  for tick in 0 ..< 12:
    sleep(3)
    output.pump()
  doAssert player.renderedFrames == beforePause
  output.systemVolume.close()
  output.pump()
  output.setPercent(46)
  output.setMuted(true)
  output.systemVolume = openSystemVolume(getCurrentProcessId())
  output.settle()
  doAssert output.volume == 46 and output.muted
  doAssert output.systemVolume.percent == 46 and output.systemVolume.muted
  output.setMuted(false)
  output.settle()
  doAssert not output.muted and output.volume == 46
  output.setPercent(47)
  output.setPercent(46)
  doAssert not output.systemVolume.writesSettled
  doAssert listener.gain == 0
  output.settle()
  doAssert output.volume == 46
  let external = openSystemVolume(getCurrentProcessId())
  defer: external.close()
  external.settleControl()
  output.setPercent(47)
  output.systemVolume.settleControl()
  external.setPercent(48)
  external.settleControl()
  output.systemVolume.waitObserved(48, false)
  output.settle()
  doAssert output.volume == 48 and listener.gain == 1
  output.setMuted(true)
  output.systemVolume.settleControl()
  external.setMuted(false)
  external.settleControl()
  output.systemVolume.waitObserved(48, false)
  output.settle()
  doAssert not output.muted and listener.gain == 1
  output.close()
  doAssert player.state == Stopped, "Closing the owning output must release its APU."
  output.close()
  echo "Shared output: early mute/volume, actual backend readback, reattachment, pause and close passed."

when isMainModule: main()
