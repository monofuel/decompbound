import
  std/strutils,
  decompbound/[apu, spc700],
  ./engine/rebuilt_rom

type
  UploadBlock = object
    destination: int
    data: seq[uint8]
  PortWrite = tuple[address: uint16, value: uint8]
  Host = ref object
    blocks: seq[UploadBlock]
    inputs: array[4, uint8]
    writes: seq[PortWrite]
    stage, blockIndex, byteIndex, token, flags: int
    readyDelay, firstDelay, staleDelay, glitches, dataAcks, headerAcks: int
    gatePassed: bool
    observeAck: proc(address: int, value: uint8)

const
  DriverPayload = 0x260042
  DriverStart = 0x0500
  DriverLength = 16779
  ReceiverOrigin = 0xEE1
  ReturnAddress = 0x4000'u16
  FinalDestination = 0x6ABC
  AwaitGreeting = 0
  AwaitHeaderAck = 1
  TransferData = 2
  Completed = 3
  RetainedStatus = PswH or PswV or PswP or PswI or PswB

proc offerHeader(host: Host, token: int) =
  ## Offer destination and continuation flag before presenting its header token.
  let destination = if host.blockIndex < host.blocks.len:
    host.blocks[host.blockIndex].destination else: FinalDestination
  host.token = token and 255
  host.inputs[0] = host.token.uint8
  host.inputs[1] = (if host.blockIndex < host.blocks.len: host.flags else: 0).uint8
  host.inputs[2] = (destination and 255).uint8
  host.inputs[3] = (destination shr 8).uint8
  host.stage = AwaitHeaderAck

proc finishBlock(host: Host) =
  ## End a block with a forward token gap rather than an invented length field.
  let length = host.blocks[host.blockIndex].data.len
  inc host.blockIndex
  host.offerHeader((length + 2) and 255)

proc readPort(host: Host, address: uint16): int =
  ## Drive authored host inputs, including finite waits and unstable token observations.
  doAssert address in 0xF4'u16 .. 0xF7'u16
  let port = address.int - 0xF4
  if port != 0: return host.inputs[port].int
  if host.stage == AwaitHeaderAck and host.headerAcks == 0 and host.readyDelay > 0:
    dec host.readyDelay
    return 0
  if host.stage == TransferData:
    if not host.gatePassed:
      if host.firstDelay > 0:
        dec host.firstDelay
        return 1 # Hold the first-token-zero gate closed.
      host.gatePassed = true
      if host.blocks[host.blockIndex].data.len == 0:
        host.finishBlock()
      return 0
    if host.byteIndex == 0 and host.glitches == 2:
      dec host.glitches
      return 2 # First comparison negative; the second observation below is equal.
    if host.glitches == 1:
      dec host.glitches
      return host.byteIndex and 255
    if host.byteIndex == 1 and host.staleDelay > 0:
      dec host.staleDelay
      return 0 # Repeated previous token is a nonnegative mismatch, not a new header.
  host.inputs[0].int

proc writePort(host: Host, address: uint16, value: uint8): bool =
  ## Respond to actual acknowledgements without changing CPU code or registers.
  host.writes.add (address, value)
  case address
  of 0xF2, 0xF3:
    discard # Actual selection prelude may write KOFF through the original helper.
  of 0xF1:
    doAssert host.stage == Completed and value == 0x31
    host.inputs = [0'u8, 0, 0, 0] # CONTROL clears both inbound port pairs.
  of 0xF5:
    doAssert host.stage == AwaitGreeting and value == 0xBB
    host.offerHeader(0xCC)
  of 0xF4:
    case host.stage
    of AwaitGreeting:
      doAssert value == 0xAA
    of AwaitHeaderAck:
      doAssert value.int == host.token
      inc host.headerAcks
      if host.blockIndex == host.blocks.len:
        host.stage = Completed
      else:
        host.stage = TransferData
        host.byteIndex = 0
        host.gatePassed = false
        host.inputs[0] = 0
        host.inputs[1] = (if host.blocks[host.blockIndex].data.len == 0: 0
          else: host.blocks[host.blockIndex].data[0].int).uint8
    of TransferData:
      doAssert value.int == (host.byteIndex and 255)
      if host.observeAck != nil:
        host.observeAck((host.blocks[host.blockIndex].destination + host.byteIndex) and 65535,
          host.blocks[host.blockIndex].data[host.byteIndex])
      inc host.dataAcks
      inc host.byteIndex
      if host.byteIndex == host.blocks[host.blockIndex].data.len:
        host.finishBlock()
      else:
        host.inputs[0] = (host.byteIndex and 255).uint8
        host.inputs[1] = host.blocks[host.blockIndex].data[host.byteIndex]
    else:
      doAssert false, "acknowledgement after completion"
  else:
    doAssert false, "unexpected receiver port $" & address.toHex(4)
  true

proc authoredBlock(destination, length, seed: int): UploadBlock =
  ## Generate tiny synthetic payloads without copying game data.
  result.destination = destination
  for index in 0 ..< length:
    result.data.add ((index * 37 + seed) and 255).uint8

proc loaded(rom: seq[uint8]): Spc =
  ## Load original resident code and an authored native caller frame.
  result = newSpc()
  for index in 0 ..< DriverLength:
    result.ram[DriverStart + index] = rom[DriverPayload + index]
  result.sp = 0xEF
  result.ram[0x1F0] = 0
  result.ram[0x1F1] = 0x40

proc install(spc: var Spc, host: Host) =
  ## Attach only bare CPU protocol hooks, with no APU, DSP or audio device.
  spc.readHook = proc(address: uint16): int = host.readPort(address)
  spc.writeHook = proc(address: uint16, value: uint8): bool = host.writePort(address, value)

proc runTo(spc: var Spc, stop: uint16, budget: int) =
  ## Execute original instructions to a named boundary under a finite budget.
  var steps = 0
  while spc.pc != stop:
    doAssert steps < budget, "receiver budget at $" & spc.pc.toHex(4)
    spc.step()
    inc steps

proc checkTransfer(rom: seq[uint8], blocks: seq[UploadBlock], flag, seed: int,
    delayed = false) =
  ## Compare complete original receives against host block concatenation and untouched RAM.
  var spc = loaded(rom)
  let host = Host(blocks: blocks, flags: flag,
    readyDelay: (if delayed: 3 else: 0), firstDelay: (if delayed: 2 else: 0),
    staleDelay: (if delayed: 3 else: 0), glitches: (if delayed: 2 else: 0))
  spc.install(host)
  spc.pc = ReceiverOrigin.uint16
  spc.psw = seed.uint8
  spc.x = 0x93
  spc.y = 0x57
  var
    expected = spc.ram[]
    beforeAcknowledgement = spc.ram[]
    length = 0
  let memory = spc.ram
  host.observeAck = proc(address: int, value: uint8) =
    doAssert memory[address] == beforeAcknowledgement[address]
    beforeAcknowledgement[address] = value
  for upload in blocks:
    for index, value in upload.data:
      expected[(upload.destination + index) and 65535] = value
    length += upload.data.len
  expected[0x14] = (FinalDestination and 255).uint8
  expected[0x15] = (FinalDestination shr 8).uint8
  spc.runTo(ReturnAddress, 100 + length * 20 + blocks.len * 40)
  doAssert host.stage == Completed and host.headerAcks == blocks.len + 1
  doAssert host.dataAcks == length
  doAssert spc.ram[] == expected
  let
    token = if blocks.len == 0: 0xCC else: (blocks[^1].data.len + 2) and 255
    carry = if blocks.len == 0: 1 else:
      (if (blocks[^1].data.len and 255) >= token: 1 else: 0)
  doAssert spc.a == 0 and spc.x == 0x31 and spc.y.int == token and spc.sp == 0xF1
  doAssert spc.psw.int == ((seed and RetainedStatus.int) or carry)
  doAssert host.writes[^1] == (0xF1'u16, 0x31'u8)
  doAssert host.writes.len == length + blocks.len + 4

proc checkWaits(rom: seq[uint8]) =
  ## Observe finite initial/first-token waits without claiming eventual completion.
  for first in [false, true]:
    var spc = loaded(rom)
    let host = Host(blocks: @[authoredBlock(0x5000,1,19)], flags: 1,
      readyDelay: (if first: 0 else: 1000), firstDelay: (if first: 1000 else: 0))
    spc.install(host)
    spc.pc = ReceiverOrigin.uint16
    for step in 0 ..< 50: spc.step()
    doAssert spc.sp == 0xEF and host.dataAcks == 0
    if first:
      doAssert spc.pc.int in [0xEF4,0xEF7] and host.headerAcks == 1
    else:
      doAssert spc.pc.int in [0xEEB,0xEEE,0xEF0] and host.headerAcks == 0
    doAssert host.writes[^1].address != 0xF1

proc checkPrelude(rom: seq[uint8]) =
  ## Execute real prelude, complete authored receive, then continue the actual zero selector.
  var spc = loaded(rom)
  let host = Host(blocks: @[authoredBlock(0x5001,3,77)], flags: 0x80)
  spc.install(host)
  spc.pc = 0x75E
  spc.ram[8] = 0xC7
  spc.ram[4] = 0xA3
  spc.ram[0x1A] = 0xA5
  spc.runTo(0x76E, 1000)
  doAssert host.stage == Completed and spc.sp == 0xEF and spc.ram[8] == 0xC7
  doAssert spc.a == 0 and spc.x == 0x31
  spc.runTo(ReturnAddress, 60)
  doAssert spc.ram[8] == 0 and spc.ram[4] == 0 and spc.ram[0xC] == 2
  doAssert spc.ram[0x46] == 0xFA and spc.sp == 0xF1
  doAssert host.writes[0] == (0xF2'u16,0x5C'u8)
  doAssert host.writes[1] == (0xF3'u16,0xFF'u8)
  doAssert spc.ram[0x5001 .. 0x5003] == host.blocks[0].data

proc checkImage(rom: seq[uint8]) =
  ## Exercise complete synthetic transfers independently of assembler/source encoding.
  var contexts = 0
  for seed in [0,255 and not PswP.int]:
    checkTransfer(rom, @[], 1, seed)
    inc contexts
    for length in [0,1,2,3,127,128,129,254,255,256,257,511,512,513]:
      for destination in [0x5001,0x50FF]:
        checkTransfer(rom,@[authoredBlock(destination,length,seed)],1,seed,true)
        inc contexts
    checkTransfer(rom,@[authoredBlock(0xFFFE,4,19)],255,seed)
    checkTransfer(rom,@[authoredBlock(0x5000,257,19),authoredBlock(0x6101,3,71)],128,seed,true)
    contexts += 2
  for flag in 1 .. 255:
    checkTransfer(rom,@[authoredBlock(0x6000,1,flag)],flag,0)
    inc contexts
  checkWaits(rom)
  checkPrelude(rom)
  echo "complete transfer contexts=",contexts,
    "; bounded waits=2; actual075E->receiverRET->0772chain=1"

proc checkHardware(image: seq[uint8]) =
  ## Complete a receive through composed real APU hooks without advancing or mixing audio.
  for initialEnabled in 0 .. 7:
    let
      hardware = newApu()
      initial = loaded(image)
      host = Host(blocks: @[authoredBlock(0x5000,1,33)], flags: 1)
    hardware.spc.ram[] = initial.ram[]
    hardware.spc.sp = 0xEF
    hardware.spc.pc = ReceiverOrigin.uint16
    hardware.spc.iplEnabled = true
    hardware.portsOut = [7'u8,8,9,10]
    for timer in 0 .. 2:
      hardware.setTimerSnapshot(timer, TimerSnapshot(
        enabled: (initialEnabled and (1 shl timer)) != 0,
        target: (17 + timer).uint8, internal: 7, counter: 11, accum: 19))
    let
      readHardware = hardware.spc.readHook
      writeHardware = hardware.spc.writeHook
    hardware.spc.readHook = proc(address: uint16): int =
      doAssert address in 0xF4'u16 .. 0xF7'u16
      hardware.portsIn[address.int - 0xF4] = host.readPort(address).uint8
      readHardware(address)
    hardware.spc.writeHook = proc(address: uint16, value: uint8): bool =
      doAssert address in [0xF1'u16,0xF4'u16,0xF5'u16]
      let handled = writeHardware(address,value)
      discard host.writePort(address,value)
      handled
    hardware.spc.runTo(ReturnAddress, 200)
    doAssert hardware.spc.sp == 0xF1 and not hardware.spc.iplEnabled
    doAssert hardware.portsIn == [0'u8,0,0,0]
    doAssert hardware.portsOut == [3'u8,0xBB,9,10]
    doAssert hardware.dsp.writes == 0
    for timer in 0 .. 2:
      let
        state = hardware.getTimerSnapshot(timer)
        reset = timer == 0 and (initialEnabled and 1) == 0
      doAssert state.enabled == (timer == 0)
      doAssert state.target.int == 17 + timer and state.accum == 19
      doAssert state.internal.int == (if reset:0 else:7)
      doAssert state.counter.int == (if reset:0 else:11)
  echo "real APU CONTROL31 contexts=8; hooks composed; no timer advance or DSP mixing"

proc main() =
  ## Require original and independently rebuilt images; missing ROM and assertions fail naturally.
  for index, image in engineImages("bin/spc_upload_receiver_extract"):
    echo "image=", (if index == 0: "original" else: "fresh rebuild")
    checkImage(image)
    checkHardware(image)
  echo "SPC upload receiver passed across both images."

when isMainModule:
  main()
