## Save-state timer serialization (v2) + v1 recovery path.
## ROM-free timer snapshot tests always run; gold-ROM round-trip is optional.

import
  std/[os, strformat],
  decompbound/[apu, cpu, save_state, snesbus]

proc enableTimer0(apu: Apu, target: uint8 = 0x10) =
  ## Program FA then F1 bit0 like the EB driver.
  discard apu.spc.writeHook(0x00FA, target)
  discard apu.spc.writeHook(0x00F1, 0x01)

proc countFdTicks(apu: Apu, samples: int): int =
  ## Count $FD overflows over `samples` of runSample (poll every sample).
  result = 0
  for _ in 0 ..< samples:
    discard apu.runSample()
    let v = apu.spc.readHook(0x00FD)
    if v > 0:
      result += v

block timerSnapshotRoundTrip:
  ## Snapshot must restore enable/target/accum so free-run rate survives.
  let apu = newApu()
  enableTimer0(apu, 0x10)
  discard countFdTicks(apu, 200)
  let snap = apu.getTimerSnapshot(0)
  doAssert snap.enabled
  doAssert snap.target == 0x10
  # Wipe timers as if a bad load left them off.
  discard apu.spc.writeHook(0x00F1, 0x00)
  doAssert not apu.timer0Enabled()
  apu.setTimerSnapshot(0, snap)
  doAssert apu.timer0Enabled()
  let ticks = countFdTicks(apu, 3200)
  doAssert ticks >= 47 and ticks <= 53,
    &"after snapshot restore got {ticks} $FD ticks (want~50)"

block recoverTimersAfterLoadReenablesT0:
  ## v1 load path: T0 was never in the blob; recover from $53 / default $10.
  let apu = newApu()
  apu.spc.ram[][0x53] = 0x10
  doAssert not apu.timer0Enabled()
  apu.recoverTimersAfterLoad()
  doAssert apu.timer0Enabled()
  doAssert apu.getTimerSnapshot(0).target == 0x10
  let ticks = countFdTicks(apu, 640)
  doAssert ticks >= 8 and ticks <= 12,
    &"recoverTimers free-run got {ticks} want~10 in 640 samples"

block serializePreservesTimersWhenRomPresent:
  ## Full bus serialize/deserialize keeps T0 enabled (v2 blob).
  const Gold = "bin/Earthbound (U) [!].smc"
  if not fileExists(Gold):
    echo "[test_save_state] no gold ROM; skipping full serialize round-trip"
  else:
    var data = cast[seq[uint8]](readFile(Gold))
    if data.len mod 1024 == 512:
      data = data[512 .. ^1]
    let snes = newSnesBus(data)
    var cpu = snes.resetCpu()
    # Boot with play-like APU ticks so timers are programmed by the driver.
    const InstrPerLine = 150
    for frame in 0 ..< 120:
      for l in 0 ..< 262:
        if l == 224 and (snes.nmitimen and 0x80) != 0:
          cpu.nmiPending = true
        for i in 0 ..< InstrPerLine:
          cpu.step(snes.bus)
        for k in 0 ..< 2:
          discard snes.tickApu()
      for _ in 0 ..< 9:
        discard snes.tickApu()
    # Ensure T0 is on (driver or recover) before snapshot.
    if not snes.apu.timer0Enabled():
      snes.apu.recoverTimersAfterLoad()
    doAssert snes.apu.timer0Enabled(), "T0 should be on after boot/recover"
    let before = snes.apu.getTimerSnapshot(0)
    let blob = serializeState(snes, cpu)
    # Corrupt live timers, then deserialize should restore them (v2).
    discard snes.apu.spc.writeHook(0x00F1, 0x00)
    doAssert not snes.apu.timer0Enabled()
    deserializeState(blob, snes, cpu)
    doAssert snes.apu.timer0Enabled(), "v2 deserialize must restore T0 enable"
    let after = snes.apu.getTimerSnapshot(0)
    doAssert after.target == before.target,
      &"target {after.target} vs {before.target}"
    echo &"[test_save_state] serialize ok: blob={blob.len} T0 target={after.target:02X}"
