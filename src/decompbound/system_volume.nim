## Optional per-process PulseAudio/PipeWire volume control for the jukebox.
##
## Loads libpulse.so.0 at runtime so the product has no header or link
## dependency. Native OpenAL PipeWire sink-inputs omit application.process.id;
## that PID lives on the referenced pa_client_info proplist instead.

import
  std/[dynlib, monotimes, tables, times]

const PaChannelsMax* = 32

type
  PaSampleSpec* {.bycopy.} = object
    format*: cint
    rate*: uint32
    channels*: uint8
  PaChannelMap* {.bycopy.} = object
    channels*: uint8
    map*: array[PaChannelsMax, cint]
  PaCVolume* {.bycopy.} = object
    channels*: uint8
    values*: array[PaChannelsMax, uint32]
  PaClientInfo* {.bycopy.} = object
    index*: uint32
    name*: cstring
    ownerModule*: uint32
    driver*: cstring
    proplist*: pointer
  PaSinkInputInfo* {.bycopy.} = object
    index*: uint32
    name*: cstring
    ownerModule*: uint32
    client*: uint32
    sink*: uint32
    sampleSpec*: PaSampleSpec
    channelMap*: PaChannelMap
    volume*: PaCVolume
    bufferUsec*: uint64
    sinkUsec*: uint64
    resampleMethod*: cstring
    driver*: cstring
    mute*: cint
    proplist*: pointer
    corked*: cint
    hasVolume*: cint
    volumeWritable*: cint
    format*: pointer
  PaMainloop = pointer
  PaMainloopApi = pointer
  PaContext = pointer
  PaOperation = pointer
  PaContextNotifyCb = proc(c: PaContext, userdata: pointer) {.cdecl, gcsafe, raises: [].}
  PaContextSuccessCb = proc(c: PaContext, success: cint, userdata: pointer) {.cdecl, gcsafe, raises: [].}
  PaContextSubscribeCb = proc(c: PaContext, t: cuint, idx: uint32,
      userdata: pointer) {.cdecl, gcsafe, raises: [].}
  PaClientInfoCb = proc(c: PaContext, info: ptr PaClientInfo, eol: cint,
      userdata: pointer) {.cdecl, gcsafe, raises: [].}
  PaSinkInputInfoCb = proc(c: PaContext, info: ptr PaSinkInputInfo, eol: cint,
      userdata: pointer) {.cdecl, gcsafe, raises: [].}
  OwnedStream = object
    index: uint32
    volume: PaCVolume
    muted: bool
    hasVolume: bool
    writable: bool
  SystemVolume* = ref object
    available*: bool
    percent*: int
    muted*: bool
    lastError*: string
    processId: int
    closed: bool
    pinned: bool
    dirty: bool
    busy: bool
    needsReconnect: bool
    writeSerial, observedSerial, listSerial, pendingWrites: int
    retryAt: MonoTime
    mainloop: PaMainloop
    context: PaContext
    clients: Table[uint32, int]
    owned: seq[OwnedStream]
    pendingOwned: seq[OwnedStream]

const
  LibPulseName = "libpulse.so.0"
  PulseContextName = "decompbound"
  ProcessIdKey = "application.process.id"
  PaVolumeNorm* = 0x10000'u32
  PaInvalidIndex = 0xFFFF_FFFF'u32
  PaContextNoautospawn = 0x0001'u32
  PaContextReady = 4.cint
  PaContextFailed = 5.cint
  PaContextTerminated = 6.cint
  PaSubscribeSinkInput = 0x0004'u32
  PaSubscribeClient = 0x0020'u32
  SubscribeMask = PaSubscribeSinkInput or PaSubscribeClient
  MaxPercent = 100
  DefaultPercent = 100
  RetrySeconds = 2

var
  pulseLib: LibHandle
  pulseLoaded: bool
  paMainloopNew: proc(): PaMainloop {.cdecl, gcsafe, raises: [].}
  paMainloopFree: proc(m: PaMainloop) {.cdecl, gcsafe, raises: [].}
  paMainloopIterate: proc(m: PaMainloop, blocking: cint, retval: ptr cint): cint {.cdecl, gcsafe, raises: [].}
  paMainloopGetApi: proc(m: PaMainloop): PaMainloopApi {.cdecl, gcsafe, raises: [].}
  paContextNew: proc(mainloop: PaMainloopApi, name: cstring): PaContext {.cdecl, gcsafe, raises: [].}
  paContextUnref: proc(c: PaContext) {.cdecl, gcsafe, raises: [].}
  paContextSetStateCallback: proc(c: PaContext, cb: PaContextNotifyCb,
      userdata: pointer) {.cdecl, gcsafe, raises: [].}
  paContextErrno: proc(c: PaContext): cint {.cdecl, gcsafe, raises: [].}
  paContextGetState: proc(c: PaContext): cint {.cdecl, gcsafe, raises: [].}
  paContextConnect: proc(c: PaContext, server: cstring, flags: cuint,
      api: pointer): cint {.cdecl, gcsafe, raises: [].}
  paContextDisconnect: proc(c: PaContext) {.cdecl, gcsafe, raises: [].}
  paStrerror: proc(error: cint): cstring {.cdecl, gcsafe, raises: [].}
  paContextSubscribe: proc(c: PaContext, mask: cuint, cb: PaContextSuccessCb,
      userdata: pointer): PaOperation {.cdecl, gcsafe, raises: [].}
  paContextSetSubscribeCallback: proc(c: PaContext, cb: PaContextSubscribeCb,
      userdata: pointer) {.cdecl, gcsafe, raises: [].}
  paContextGetClientInfoList: proc(c: PaContext, cb: PaClientInfoCb,
      userdata: pointer): PaOperation {.cdecl, gcsafe, raises: [].}
  paContextGetSinkInputInfoList: proc(c: PaContext, cb: PaSinkInputInfoCb,
      userdata: pointer): PaOperation {.cdecl, gcsafe, raises: [].}
  paContextSetSinkInputVolume: proc(c: PaContext, idx: uint32,
      volume: ptr PaCVolume, cb: PaContextSuccessCb,
      userdata: pointer): PaOperation {.cdecl, gcsafe, raises: [].}
  paContextSetSinkInputMute: proc(c: PaContext, idx: uint32, mute: cint,
      cb: PaContextSuccessCb, userdata: pointer): PaOperation {.cdecl, gcsafe, raises: [].}
  paOperationUnref: proc(o: PaOperation) {.cdecl, gcsafe, raises: [].}
  paProplistGets: proc(p: pointer, key: cstring): cstring {.cdecl, gcsafe, raises: [].}
  paCvolumeScale: proc(v: ptr PaCVolume, maxVolume: uint32): ptr PaCVolume {.cdecl, gcsafe, raises: [].}

proc loadSymbol[T](name: string, dest: var T): string =
  ## Resolve one PulseAudio C symbol from the loaded libpulse.so.0.
  let p = pulseLib.symAddr(name)
  if p.isNil:
    return LibPulseName & " is missing " & name
  dest = cast[T](p)

proc loadPulseApi(): string =
  ## Load libpulse.so.0 and every function pointer this module calls.
  if pulseLoaded:
    return ""
  pulseLib = loadLib(LibPulseName)
  if pulseLib.isNil:
    return LibPulseName & " is unavailable"
  result = loadSymbol("pa_mainloop_new", paMainloopNew)
  if result.len > 0: return
  result = loadSymbol("pa_mainloop_free", paMainloopFree)
  if result.len > 0: return
  result = loadSymbol("pa_mainloop_iterate", paMainloopIterate)
  if result.len > 0: return
  result = loadSymbol("pa_mainloop_get_api", paMainloopGetApi)
  if result.len > 0: return
  result = loadSymbol("pa_context_new", paContextNew)
  if result.len > 0: return
  result = loadSymbol("pa_context_unref", paContextUnref)
  if result.len > 0: return
  result = loadSymbol("pa_context_set_state_callback", paContextSetStateCallback)
  if result.len > 0: return
  result = loadSymbol("pa_context_errno", paContextErrno)
  if result.len > 0: return
  result = loadSymbol("pa_context_get_state", paContextGetState)
  if result.len > 0: return
  result = loadSymbol("pa_context_connect", paContextConnect)
  if result.len > 0: return
  result = loadSymbol("pa_context_disconnect", paContextDisconnect)
  if result.len > 0: return
  result = loadSymbol("pa_strerror", paStrerror)
  if result.len > 0: return
  result = loadSymbol("pa_context_subscribe", paContextSubscribe)
  if result.len > 0: return
  result = loadSymbol("pa_context_set_subscribe_callback", paContextSetSubscribeCallback)
  if result.len > 0: return
  result = loadSymbol("pa_context_get_client_info_list", paContextGetClientInfoList)
  if result.len > 0: return
  result = loadSymbol("pa_context_get_sink_input_info_list", paContextGetSinkInputInfoList)
  if result.len > 0: return
  result = loadSymbol("pa_context_set_sink_input_volume", paContextSetSinkInputVolume)
  if result.len > 0: return
  result = loadSymbol("pa_context_set_sink_input_mute", paContextSetSinkInputMute)
  if result.len > 0: return
  result = loadSymbol("pa_operation_unref", paOperationUnref)
  if result.len > 0: return
  result = loadSymbol("pa_proplist_gets", paProplistGets)
  if result.len > 0: return
  result = loadSymbol("pa_cvolume_scale", paCvolumeScale)
  if result.len > 0: return
  pulseLoaded = true
  result = ""

proc unrefOperation(op: PaOperation) =
  ## Drop this client's pa_operation reference after an async request.
  if not op.isNil:
    paOperationUnref(op)

proc pulseError(control: SystemVolume): string =
  ## Read the current PulseAudio errno as a diagnostic string.
  if control.context.isNil:
    return "PulseAudio context is unavailable"
  let msg = paStrerror(paContextErrno(control.context))
  if msg.isNil or msg[0] == '\0':
    return "PulseAudio error"
  $msg

proc parseProcessId(value: cstring): int =
  ## Parse a Pulse property PID, returning -1 when the value is missing or not digits.
  result = -1
  if value.isNil or value[0] == '\0':
    return
  var
    n = 0
    i = 0
  while true:
    let c = value[i]
    if c == '\0':
      return n
    if c < '0' or c > '9':
      return -1
    let digit = ord(c) - ord('0')
    if n > (high(int) - digit) div 10: return -1
    n = n * 10 + digit
    inc i

proc processIdOf(proplist: pointer): int =
  ## Read application.process.id from a Pulse property list.
  if proplist.isNil:
    return -1
  parseProcessId(paProplistGets(proplist, ProcessIdKey))

proc contextState(control: SystemVolume): cint =
  ## Return the Pulse context state, or failed when no context exists.
  if control.context.isNil:
    return PaContextFailed
  paContextGetState(control.context)

proc contextIsReady(control: SystemVolume): bool =
  ## True when the Pulse context can run introspection and volume writes.
  contextState(control) == PaContextReady

proc volumePercent(volume: PaCVolume): int =
  ## Convert the loudest channel to a rounded percent of PA_VOLUME_NORM.
  if volume.channels == 0:
    return 0
  var maxVol = 0'u32
  let n = min(volume.channels.int, PaChannelsMax)
  for i in 0 ..< n:
    if volume.values[i] > maxVol:
      maxVol = volume.values[i]
  int((maxVol.uint64 * 100'u64 + (PaVolumeNorm div 2)) div PaVolumeNorm)

proc applyOwnedState(control: SystemVolume) =
  ## Publish percent and mute from the currently owned sink-inputs only.
  control.available = false
  if control.owned.len == 0:
    return
  var
    loudest = 0
    allMuted = true
    sawVolume = false
  for stream in control.owned:
    if stream.hasVolume and stream.writable: control.available = true
    if stream.hasVolume:
      let value = volumePercent(stream.volume)
      if not sawVolume or value > loudest:
        loudest = value
      sawVolume = true
    if not stream.muted:
      allMuted = false
  if sawVolume:
    control.percent = loudest
  control.muted = allMuted

proc clearOwned(control: SystemVolume) =
  ## Drop cached sink-input indexes so a failed server cannot be written later.
  control.available = false
  control.owned.setLen(0)
  control.pendingOwned.setLen(0)
  control.clients.clear()

proc belongsToProcess(info: ptr PaSinkInputInfo, control: SystemVolume): bool =
  ## Match this process by PID on the sink-input, else via its Pulse client.
  let direct = processIdOf(info.proplist)
  if direct >= 0:
    return direct == control.processId
  if info.client != PaInvalidIndex:
    let clientPid = control.clients.getOrDefault(info.client, -1)
    if clientPid == control.processId:
      return true
  false

proc scaledVolume(volume: PaCVolume, target: uint32): PaCVolume =
  ## Scale a copy so the loudest channel equals target, keeping channel balance.
  result = volume
  if result.channels == 0:
    return
  if paCvolumeScale(addr result, target).isNil:
    let n = min(result.channels.int, PaChannelsMax)
    for i in 0 ..< n:
      result.values[i] = target

proc startSinkInputList(control: SystemVolume) {.gcsafe, raises: [].}
proc startClientList(control: SystemVolume) {.gcsafe, raises: [].}

proc onSubscribeDone(c: PaContext, success: cint, userdata: pointer) {.cdecl, gcsafe, raises: [].} =
  ## Record a subscribe failure without treating success as a volume change.
  let control = cast[SystemVolume](userdata)
  if control.closed:
    return
  if success == 0:
    control.lastError = pulseError(control)

proc onEvent(c: PaContext, t: cuint, idx: uint32, userdata: pointer) {.cdecl, gcsafe, raises: [].} =
  ## Mark client and sink-input server changes so the next poll refreshes.
  let control = cast[SystemVolume](userdata)
  if control.closed:
    return
  control.dirty = true

proc onClientInfo(c: PaContext, info: ptr PaClientInfo, eol: cint,
    userdata: pointer) {.cdecl, gcsafe, raises: [].} =
  ## Index each client's process id, then list sink-inputs once the list ends.
  let control = cast[SystemVolume](userdata)
  if control.closed:
    return
  if eol < 0:
    control.lastError = pulseError(control)
    control.busy = false
    clearOwned(control)
    return
  if eol > 0:
    startSinkInputList(control)
    return
  if info.isNil:
    return
  let pid = processIdOf(info.proplist)
  if pid >= 0:
    control.clients[info.index] = pid

proc onSinkInputInfo(c: PaContext, info: ptr PaSinkInputInfo, eol: cint,
    userdata: pointer) {.cdecl, gcsafe, raises: [].} =
  ## Collect this process's sink-inputs after the client PID map is complete.
  let control = cast[SystemVolume](userdata)
  if control.closed:
    return
  if eol < 0:
    control.lastError = pulseError(control)
    control.busy = false
    clearOwned(control)
    return
  if eol > 0:
    control.owned = move(control.pendingOwned)
    applyOwnedState(control)
    control.observedSerial = control.listSerial
    control.busy = false
    return
  if info.isNil:
    return
  if not belongsToProcess(info, control):
    return
  control.pendingOwned.add(OwnedStream(
    index: info.index,
    volume: info.volume,
    muted: info.mute != 0,
    hasVolume: info.hasVolume != 0,
    writable: info.volumeWritable != 0))

proc startSinkInputList(control: SystemVolume) =
  ## Request the sink-input list after the client list has finished.
  if control.closed or not contextIsReady(control):
    control.busy = false
    return
  control.pendingOwned.setLen(0)
  let op = paContextGetSinkInputInfoList(control.context, onSinkInputInfo,
      cast[pointer](control))
  if op.isNil:
    control.lastError = pulseError(control)
    control.busy = false
    clearOwned(control)
    return
  unrefOperation(op)

proc startClientList(control: SystemVolume) =
  ## Refresh clients first so PipeWire streams can be matched by client PID.
  if control.closed or control.busy or not contextIsReady(control):
    return
  control.busy = true
  control.listSerial = control.writeSerial
  control.dirty = false
  control.clients.clear()
  let op = paContextGetClientInfoList(control.context, onClientInfo,
      cast[pointer](control))
  if op.isNil:
    control.lastError = pulseError(control)
    control.busy = false
    clearOwned(control)
    return
  unrefOperation(op)

proc subscribe(control: SystemVolume) =
  ## Listen for client and sink-input changes on a ready context.
  paContextSetSubscribeCallback(control.context, onEvent, cast[pointer](control))
  let op = paContextSubscribe(control.context, SubscribeMask, onSubscribeDone,
      cast[pointer](control))
  if op.isNil:
    control.lastError = pulseError(control)
    return
  unrefOperation(op)

proc onState(c: PaContext, userdata: pointer) {.cdecl, gcsafe, raises: [].} =
  ## Track context readiness and request reconnect after iterate returns.
  let control = cast[SystemVolume](userdata)
  if control.closed:
    return
  let state = paContextGetState(c)
  if state == PaContextReady:
    control.available = false
    control.lastError = ""
    control.needsReconnect = false
    control.dirty = true
    subscribe(control)
  elif state == PaContextFailed or state == PaContextTerminated:
    control.available = false
    control.needsReconnect = true
    control.retryAt = getMonoTime() + initDuration(seconds = RetrySeconds)
    control.lastError = pulseError(control)

proc teardownContext(control: SystemVolume) =
  ## Disconnect the current context and forget owned stream indexes.
  control.available = false
  control.busy = false
  control.dirty = false
  control.needsReconnect = false
  control.pendingWrites = 0
  control.observedSerial = -1
  clearOwned(control)
  if not control.context.isNil:
    paContextSetStateCallback(control.context, nil, nil)
    paContextSetSubscribeCallback(control.context, nil, nil)
    paContextDisconnect(control.context)
    paContextUnref(control.context)
    control.context = nil

proc startConnect(control: SystemVolume) =
  ## Begin a non-blocking Pulse connection without autospawning a daemon.
  if control.closed or control.mainloop.isNil or not control.context.isNil:
    return
  if getMonoTime() < control.retryAt: return
  control.retryAt = getMonoTime() + initDuration(seconds = RetrySeconds)
  let api = paMainloopGetApi(control.mainloop)
  if api.isNil:
    control.lastError = "pa_mainloop_get_api failed"
    return
  control.context = paContextNew(api, PulseContextName)
  if control.context.isNil:
    control.lastError = "pa_context_new failed"
    return
  paContextSetStateCallback(control.context, onState, cast[pointer](control))
  let rc = paContextConnect(control.context, nil, PaContextNoautospawn, nil)
  if rc < 0:
    control.lastError = pulseError(control)
    paContextUnref(control.context)
    control.context = nil

proc openSystemVolume*(processId: int): SystemVolume =
  ## Open optional Pulse volume control for this process id, never blocking.
  result = SystemVolume(
    available: false,
    percent: DefaultPercent,
    muted: false,
    lastError: "",
    processId: processId,
    clients: initTable[uint32, int]())
  GC_ref(result)
  result.pinned = true
  let loadError = loadPulseApi()
  if loadError.len > 0:
    result.lastError = loadError
    return
  result.mainloop = paMainloopNew()
  if result.mainloop.isNil:
    result.lastError = "pa_mainloop_new failed"
    return
  startConnect(result)

proc poll*(control: SystemVolume) =
  ## Drive the Pulse mainloop once without blocking the audio loop.
  if control.closed or control.mainloop.isNil:
    return
  if control.context.isNil:
    startConnect(control)
    if control.context.isNil:
      return
  var retval: cint = 0
  let rc = paMainloopIterate(control.mainloop, 0.cint, addr retval)
  if rc < 0 or control.needsReconnect:
    let err = if control.lastError.len > 0: control.lastError else: pulseError(control)
    teardownContext(control)
    control.lastError = err
    startConnect(control)
    return
  if contextIsReady(control) and control.dirty and not control.busy and control.pendingWrites == 0:
    startClientList(control)

proc writesSettled*(control: SystemVolume): bool =
  ## Require completed writes and a subsequent list snapshot before adopting mixer state.
  control.available and control.pendingWrites == 0 and
    control.observedSerial == control.writeSerial

proc onWriteDone(c: PaContext, success: cint, userdata: pointer) {.cdecl, gcsafe, raises: [].} =
  ## Release the write barrier and request causally fresh readback, including rejected writes.
  let control = cast[SystemVolume](userdata)
  if control.closed or c != control.context: return
  if control.pendingWrites > 0: dec control.pendingWrites
  if success == 0: control.lastError = pulseError(control)
  control.dirty = true

proc setPercent*(control: SystemVolume, percent: int) =
  ## Set only this process's current sink-input volumes, preserving mute and balance.
  if not control.available or not contextIsReady(control):
    let detail =
      if control.lastError.len > 0: control.lastError
      else: "system volume is unavailable"
    raise newException(ValueError, detail)
  if percent < 0 or percent > MaxPercent:
    raise newException(ValueError, "percent must be in 0..100")
  inc control.writeSerial
  let target = uint32((percent.uint64 * PaVolumeNorm.uint64 + 50'u64) div 100'u64)
  for stream in control.owned:
    if not stream.writable or not stream.hasVolume:
      continue
    var volume = scaledVolume(stream.volume, target)
    inc control.pendingWrites
    let op = paContextSetSinkInputVolume(control.context, stream.index,
        addr volume, onWriteDone, cast[pointer](control))
    if op.isNil:
      dec control.pendingWrites
      control.lastError = pulseError(control)
    else:
      unrefOperation(op)
  control.dirty = true

proc setMuted*(control: SystemVolume, muted: bool) =
  ## Set only this process's current sink-input mute flags, preserving volume and balance.
  if not control.available or not contextIsReady(control):
    let detail =
      if control.lastError.len > 0: control.lastError
      else: "system volume is unavailable"
    raise newException(ValueError, detail)
  let muteFlag = if muted: 1.cint else: 0.cint
  inc control.writeSerial
  for i in 0 ..< control.owned.len:
    inc control.pendingWrites
    let op = paContextSetSinkInputMute(control.context, control.owned[i].index,
        muteFlag, onWriteDone, cast[pointer](control))
    if op.isNil:
      dec control.pendingWrites
      control.lastError = pulseError(control)
    else:
      unrefOperation(op)
  control.dirty = true

proc close*(control: SystemVolume) =
  ## Release Pulse objects; safe to call more than once.
  if control.closed:
    return
  control.closed = true
  control.available = false
  control.busy = false
  control.dirty = false
  control.needsReconnect = false
  clearOwned(control)
  if not control.context.isNil:
    paContextSetStateCallback(control.context, nil, nil)
    paContextSetSubscribeCallback(control.context, nil, nil)
    paContextDisconnect(control.context)
    paContextUnref(control.context)
    control.context = nil
  if not control.mainloop.isNil:
    paMainloopFree(control.mainloop)
    control.mainloop = nil
  if control.pinned:
    GC_unref(control)
    control.pinned = false
