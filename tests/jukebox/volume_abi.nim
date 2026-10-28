include ../../src/decompbound/system_volume

const PulseCflags = staticExec("pkg-config --cflags libpulse")
{.passC: PulseCflags.}
{.compile: "pulse_abi.c".}
proc pulseAbi(field: cuint): csize_t {.cdecl, importc: "jukebox_pulse_abi".}

proc fakeProperty(properties: pointer, key: cstring): cstring {.cdecl, gcsafe, raises: [].} =
  ## Supply synthetic PID metadata without connecting to a real server.
  cast[cstring](properties)

proc main() =
  ## Compare actual C headers with Nim layouts before exercising callback metadata.
  let sizes = [sizeof(PaSampleSpec), sizeof(PaChannelMap), sizeof(PaCVolume),
    sizeof(PaClientInfo), sizeof(PaSinkInputInfo), offsetOf(PaSinkInputInfo, client),
    offsetOf(PaSinkInputInfo, volume), offsetOf(PaSinkInputInfo, mute),
    offsetOf(PaSinkInputInfo, proplist), offsetOf(PaSinkInputInfo, hasVolume),
    offsetOf(PaSinkInputInfo, volumeWritable), offsetOf(PaClientInfo, proplist),
    offsetOf(PaCVolume, values)]
  for i, size in sizes:
    doAssert pulseAbi(i.cuint).int == size, "Pulse ABI mismatch at field " & $i
  paProplistGets = fakeProperty
  var control = SystemVolume(processId: 42, clients: initTable[uint32, int]())
  control.clients[7] = 42
  control.clients[8] = 99
  var info = PaSinkInputInfo(client: 7)
  doAssert belongsToProcess(addr info, control), "Native PipeWire PID should resolve through the client."
  info.client = 8
  doAssert not belongsToProcess(addr info, control)
  info.proplist = cast[pointer](cstring("42"))
  doAssert belongsToProcess(addr info, control), "Direct Pulse stream PID should match."
  info.client = 7
  info.proplist = cast[pointer](cstring("99"))
  doAssert not belongsToProcess(addr info, control), "A different explicit stream PID must not be overridden."
  doAssert parseProcessId(cstring("99999999999999999999999999999999")) == -1
  var volume = PaCVolume(channels: 2)
  volume.values[0] = PaVolumeNorm div 2
  volume.values[1] = PaVolumeNorm
  doAssert volumePercent(volume) == 100
  volume.values[0] = (PaVolumeNorm * 37 + 50) div 100
  volume.values[1] = volume.values[0]
  doAssert volumePercent(volume) == 37
  control.owned.add OwnedStream(index: 1, volume: volume, hasVolume: true, writable: true)
  applyOwnedState(control)
  doAssert control.available and control.percent == 37
  control.clearOwned()
  doAssert not control.available
  control.applyOwnedState()
  doAssert not control.available
  echo "Pulse ABI: all struct sizes/offsets, exact PID ownership, readiness and volume conversion passed."

when isMainModule: main()
