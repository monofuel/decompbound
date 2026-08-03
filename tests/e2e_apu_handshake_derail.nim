## Referee lock for the APU sound-handshake derail (inn-sleep lock class).
## Replays monofuel's deterministic repro: without the $214x port-catchup fix,
## the CPU derails at frame ~1666 (RTI to bank $20) when the inn-sleep sound
## change floods the handshake and the SPC lags. Asserts the CPU stays in
## plausible code banks the whole replay.
## Skips quietly when the user ROM or the repro replay are absent (CI).

import
  std/os,
  ../src/decompbound/[cpu, snesbus, save_state, replay]

const
  RomPath = "bin/Earthbound (U) [!].smc"
  # Repro replay pair (local session dir or the private secret archive).
  ReproCandidates = [
    "bin/sessions/20260710-222520/20260710-222525.tas",
    "../decompbound_secret/repros/inn_lock_20260710/20260710-222525.tas",
  ]

proc readRom(p: string): seq[uint8] =
  ## ROM bytes minus optional copier header.
  var d = cast[seq[uint8]](readFile(p))
  if d.len mod 1024 == 512: d = d[512 .. ^1]
  d

proc badPc(pbr: uint8, pc: uint16): bool =
  ## Executing outside plausible code: ROM banks $C0-$FF and the $40-$7D
  ## mirrors are fine; system banks only run code in their upper (ROM) half.
  let bank = pbr.int
  if bank >= 0xC0: return false
  if bank >= 0x40 and bank <= 0x7D: return false
  if (bank <= 0x3F) or (bank >= 0x80 and bank <= 0xBF): return pc < 0x8000
  if bank == 0x7E or bank == 0x7F: return false
  true

proc frame(snes: SnesBus, c: var Cpu) =
  ## One play-faithful frame; raises via badPc check handled by caller.
  var l = 0
  var s = 0
  while l < 262:
    if l == 224 and (snes.nmitimen and 0x80) != 0: c.nmiPending = true
    for i in 0 ..< 150:
      c.step(snes.bus)
      doAssert not badPc(c.pbr, c.pc),
        "CPU derailed to " & $c.pbr & ":" & $c.pc & " (APU handshake regression)"
      if c.stopped: break
    if l < 224: snes.runHdma()
    for k in 0 ..< 2: (discard snes.tickApu(); inc s)
    inc l
    if l >= 262: (snes.initHdma(); break)
  while s < 533: (discard snes.tickApu(); inc s)

proc main() =
  ## Replay the repro; assert no derail through the inn-sleep event.
  var reproPath = ""
  for cand in ReproCandidates:
    if fileExists(cand): reproPath = cand; break
  if not fileExists(RomPath) or reproPath.len == 0:
    echo "[test_apu_handshake_derail] skipped (ROM or repro replay absent)"
    return
  let (hdr, deltas) = parseReplay(reproPath)
  if not fileExists(hdr.startStateRef):
    echo "[test_apu_handshake_derail] skipped (repro start state absent)"
    return
  let rom = readRom(RomPath)
  let snes = newSnesBus(rom)
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(hdr.startStateRef)), snes, c)
  let lastF = (if deltas.len > 0: deltas[^1].frame else: 0) + 900
  for f in 0 .. lastF:
    snes.joy1 = joyAtFrame(deltas, f)
    frame(snes, c)
  echo "[test_apu_handshake_derail] ok: no derail through inn-sleep (", lastF + 1, " frames)"

when isMainModule:
  main()
