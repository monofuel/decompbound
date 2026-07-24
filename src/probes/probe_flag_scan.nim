## Compare event-flag-ish WRAM across llm fixtures.
import
  std/[os, strformat, strutils, tables, sequtils, algorithm],
  ../decompbound/[cpu, snesbus, save_state, policy],
  ../tools/[touch_grass, story_percents]

proc r8(snes: SnesBus, off: int): uint8 =
  snes.bus.mem[0x7E0000 + off]

proc main() =
  let rom = "bin/Earthbound (U) [!].smc"
  let snes = newSnesBus(policy.readRomFile(rom))
  var c = snes.resetCpu()
  let fixtures = @[
    "bedroom.state", "pre_knock_bed.state", "in_bedroom.state", "post_knock.state",
    "pokey_done.state", "home_natural_entry.state", "onett_start.state"
  ]
  var snaps: Table[string, seq[uint8]]
  for f in fixtures:
    let p = "bin/states/llm/" & f
    if not fileExists(p): continue
    deserializeState(cast[seq[byte]](readFile(p)), snes, c)
    var buf = newSeq[uint8](0x400)
    for i in 0 ..< 0x400:
      buf[i] = r8(snes, 0x9800 + i)
    snaps[f] = buf
    echo f, " knock=", pokeyKnockPercent(snes), " tg=", touchGrassPercent(snes),
      " room=", currentRoomLabel(snes)
  # Bytes that differ between pre_knock_bed and post_knock in $9800..
  if snaps.hasKey("pre_knock_bed.state") and snaps.hasKey("post_knock.state"):
    echo "--- pre_knock_bed vs post_knock ($9800+) ---"
    for i in 0 ..< 0x400:
      let a = snaps["pre_knock_bed.state"][i]
      let b = snaps["post_knock.state"][i]
      if a != b:
        echo fmt"  7E:{0x9800+i:04X} {a:02X}->{b:02X}"
  # Bytes unique: pre_knock has X, bedroom has Y (post-meteor markers)
  if snaps.hasKey("pre_knock_bed.state") and snaps.hasKey("bedroom.state"):
    echo "--- pre_knock_bed vs cold bedroom (story markers) ---"
    for i in 0 ..< 0x400:
      let a = snaps["pre_knock_bed.state"][i]
      let b = snaps["bedroom.state"][i]
      if a != b:
        # only show if also stable across in_bedroom if present
        echo fmt"  7E:{0x9800+i:04X} cold={b:02X} preknock={a:02X}"

when isMainModule: main()
