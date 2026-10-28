include ../../src/decompbound/system_volume

const PulseCflags = staticExec("pkg-config --cflags libpulse")
{.passC: PulseCflags.}
{.compile: "pulse_abi.c".}
proc pulseAbi(field: cuint): csize_t {.cdecl, importc: "jukebox_pulse_abi".}

proc fakeProperty(properties: pointer, key: cstring): cstring {.cdecl, gcsafe, raises: [].} =
  ## Supply synthetic PID metadata without connecting to a real server.
  cast[cstring](properties)

proc muteAbi(callback: pointer): cint {.cdecl, importc: "bestiary_pulse_mute_abi".}

proc fakeMute(c: PaContext, index: uint32, mute: cint, cb: PaContextSuccessCb,
    userdata: pointer): PaOperation {.cdecl, gcsafe, raises: [].} =
  ## Exercise a full C integer mute parameter through the native function-pointer ABI.
  if c == cast[PaContext](1) and index == 17 and mute == 0x01020304.cint:
    cast[PaOperation](2)
  else: nil

proc fakeReady(c: PaContext): cint {.cdecl, gcsafe, raises: [].} =
  ## Provide a ready synthetic context for failed-write paths.
  PaContextReady

proc fakeErrno(c: PaContext): cint {.cdecl, gcsafe, raises: [].} =
  ## Provide a deterministic native error code.
  1

proc fakeError(code: cint): cstring {.cdecl, gcsafe, raises: [].} =
  ## Preserve a recognizable asynchronous failure message.
  cstring("synthetic rejected write")

proc fakeScale(v: ptr PaCVolume, target: uint32): ptr PaCVolume {.cdecl, gcsafe, raises: [].} =
  ## Exercise the adapter's documented volume-scaling fallback.
  nil

proc fakeVolumeFailure(c: PaContext, index: uint32, volume: ptr PaCVolume,
    cb: PaContextSuccessCb, userdata: pointer): PaOperation {.cdecl, gcsafe, raises: [].} =
  ## Reject queuing a volume operation without scheduling a callback.
  nil

proc fakeMuteRejected(c: PaContext, index: uint32, mute: cint,
    cb: PaContextSuccessCb, userdata: pointer): PaOperation {.cdecl, gcsafe, raises: [].} =
  ## Exercise an operation rejected by the server's completion callback.
  cb(c, 0, userdata)
  cast[PaOperation](2)

proc fakeUnref(operation: PaOperation) {.cdecl, gcsafe, raises: [].} =
  ## Retire a synthetic operation without calling the native library.
  discard

proc verifyFailedWrites() =
  ## Require acknowledgement and fresh metadata even when a write fails or is rejected.
  paContextGetState = fakeReady
  paContextErrno = fakeErrno
  paStrerror = fakeError
  paCvolumeScale = fakeScale
  paContextSetSinkInputVolume = fakeVolumeFailure
  paContextSetSinkInputMute = fakeMuteRejected
  paOperationUnref = fakeUnref
  var value = PaCVolume(channels: 1)
  value.values[0] = PaVolumeNorm
  let control = SystemVolume(available: true, context: cast[PaContext](1),
    owned: @[OwnedStream(index: 17, volume: value, hasVolume: true, writable: true)])
  control.setPercent(42)
  doAssert control.pendingWrites == 0 and not control.writesSettled
  doAssert control.lastError == "synthetic rejected write"
  control.pendingOwned = control.owned
  control.listSerial = control.writeSerial
  onSinkInputInfo(control.context, nil, 1, cast[pointer](control))
  doAssert control.writesSettled and control.percent == 100
  control.setMuted(true)
  doAssert control.pendingWrites == 0 and not control.writesSettled
  doAssert not control.muted
  control.pendingOwned = control.owned
  control.listSerial = control.writeSerial
  onSinkInputInfo(control.context, nil, 1, cast[pointer](control))
  doAssert control.writesSettled and not control.muted

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
  doAssert muteAbi(cast[pointer](fakeMute)) == 1
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
  verifyFailedWrites()
  echo "Pulse ABI: all struct sizes/offsets, exact PID ownership, readiness and volume conversion passed."

when isMainModule: main()
