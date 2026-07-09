## Pre-breakage slot load: deserialize via shipped save_state and step like play.
## Guards the live-CPU path (not the 00:5FFF corpse pattern from poisoned F12s).
## Skips when slot file is absent (CI without local saves).

import
  std/[os, strformat],
  decompbound/[cpu, save_state, snesbus]

const
  GoldMasterRom = "bin/Earthbound (U) [!].smc"
  SlotPath = "bin/states/slot1.state"
  InstrPerLine = 150
  SamplesPerFrame = 533
  Frames = 60

proc readRomFile(filepath: string): seq[uint8] =
  ## Load ROM bytes, strip optional 512-byte copier header.
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512:
    start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0 ..< result.len:
    result[i] = data[start + i].uint8

proc stepPlayFrame(snes: SnesBus, cpu: var Cpu) =
  ## One frame matching src/tools/play.nim CPU/APU budget.
  var smp = 0
  for l in 0 ..< 262:
    if l == 224 and (snes.nmitimen and 0x80) != 0:
      cpu.nmiPending = true
    for i in 0 ..< InstrPerLine:
      cpu.step(snes.bus)
      if cpu.stopped:
        break
    if snes.apu != nil:
      for k in 0 ..< 2:
        discard snes.tickApu()
        inc smp
  if snes.apu != nil:
    while smp < SamplesPerFrame:
      discard snes.tickApu()
      inc smp

block slot1StaysLive:
  ## Load slot1 through the real deserialize path; CPU must remain live.
  if not fileExists(GoldMasterRom) or not fileExists(SlotPath):
    echo "[test_slot_load] no gold ROM or slot1; skipping"
  else:
    let snes = newSnesBus(readRomFile(GoldMasterRom))
    var cpu = snes.resetCpu()
    let data = cast[seq[byte]](readFile(SlotPath))
    deserializeState(data, snes, cpu)
    doAssert not cpu.stopped, "slot1 load left CPU in STP"
    doAssert not (cpu.pbr == 0x00'u8 and cpu.pc == 0x5FFF'u16),
      "slot1 load is the 00:5FFF corpse pattern"
    for f in 0 ..< Frames:
      stepPlayFrame(snes, cpu)
      doAssert not cpu.stopped, &"STP during slot1 run at frame {f}"
      doAssert not (cpu.pbr == 0x00'u8 and cpu.pc == 0x5FFF'u16),
        &"00:5FFF corpse at frame {f}"
    echo &"[test_slot_load] ok: PC={cpu.pbr:02X}:{cpu.pc:04X} after {Frames}f"
