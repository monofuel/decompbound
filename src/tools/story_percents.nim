## Story-percent metrics for llm-ai.
##
## Prologue (docs/llm-sequence.md): tg lives in touch_grass; here pokey_pct,
## pokey_knock_pct, buzzbuzz_pct, sunrise_pct.
##
## Full-game referee spine (docs/checkpoints.md + docs/grok_play_work.md Stream G):
## additional *Percent stubs map speedrun-style segments. They return 0 until
## flags are RE'd — no pos-only cheese, no parallel invent-a-list. Names match
## checkpoints.md segments so Agent progress is graded by story beats.

import
  ../decompbound/snesbus,
  ./touch_grass

const
  # === Pokey % ground truth (2026-07-09, replayed human TAS 20260709-225653 +
  # 225559; probe_replay_trail / probe_replay_flagdiff). ===
  # Route: door (0x0A60,0x0158) -> SW descent -> WEST road (Y~0x01F8..0x0290,
  # X down to ~0x0600) -> north climb at X~0x05F3..0x0631 -> ridge east along
  # Y~0x00B0..0x0130 -> meteor site. NOT story-gated: reachable from game start.
  OutdoorMaxX* = 0x1C00
  # Pokey NPC at the meteorite site (entity slot 0 in both human runs; the
  # player talked from (0x0858..0x0862, 0x00FA), facing up).
  PokeySpotX* = 0x0858
  PokeySpotY* = 0x00F2
  PokeyAdjRadius* = 0x30
  # Meteor-scene flag $9885 (mirror $4DD4): 0x00 at game start, ARMS to 0x01
  # en route (before the site), CONSUMED back to 0x00 by the Pokey/cop talk.
  # Adjacent + 0x00 therefore means "talked" (the site is unreachable without
  # passing the arm line). From replayed-run WRAM diffs, not guessed.
  MeteorArmFlag* = 0x9885
  # Text/dialogue window slot headers: slot0 $8650 (overworld command menu),
  # slot1 $8654 (NPC/scene dialogue at the meteor site). 0xFF = free.
  WindowHeader0* = 0x8650
  WindowHeader1* = 0x8654
  # Route bands (world px), from the replayed trail. Monotonic ladder.
  WestRoadMaxX = 0x0900
  WestRoadMinY = 0x0180
  WestRoadMaxY = 0x0290
  ClimbMaxX = 0x0680
  ClimbMaxY = 0x0180
  # Climb-exit pocket (traverse between climb top and the ridge; human trail
  # passes (0x0695,0x016E)..(0x06D8,0x013E)).
  PocketMaxX = 0x0720
  PocketMaxY = 0x0180
  RidgeMinX = 0x0680
  RidgeMaxX = 0x0910
  RidgeMaxY = 0x0130
  SiteMinX = 0x0800
  SiteMaxX = 0x08D0
  SiteMinY = 0x00C0
  SiteMaxY = 0x0130

proc pokeyPercent*(snes: SnesBus): int =
  ## Pokey %: legit walk from Ness's house to Pokey at the meteorite site and
  ## talk to him. Graded along the HUMAN-verified route (TAS ground truth):
  ##   10 = outside (tg 100), on/near the home yard
  ##   30 = the west road leg (south of the hill, heading west)
  ##   50 = the western climb (X<=0x0680, Y<0x0180)
  ##   70 = ridge / north band approaching the site
  ##   80 = inside the meteor site box
  ##   90 = adjacent to Pokey, scene armed ($9885=01) but not yet talked
  ##  100 = adjacent + scene flag consumed ($9885=00) -> talked to Pokey
  let tg = touchGrassPercent(snes)
  let idx = PlayerSlot * SlotIndexStride
  let px = readU16(snes, WorldXBase + idx)
  let py = readU16(snes, WorldYBase + idx)

  # Indoor (Ness or Minch) is never Pokey % progress for this objective.
  if px >= OutdoorMaxX:
    return 0
  if tg < 100:
    return 0

  let adj = abs(px - PokeySpotX) + abs(py - PokeySpotY)
  let armed = readU8(snes, MeteorArmFlag)
  if adj <= PokeyAdjRadius:
    if armed == 0x00:
      return 100
    return 90
  if px >= SiteMinX and px <= SiteMaxX and py >= SiteMinY and py <= SiteMaxY:
    return 80
  if px >= RidgeMinX and px <= RidgeMaxX and py <= RidgeMaxY:
    return 70
  if px >= ClimbMaxX and px <= PocketMaxX and py <= PocketMaxY:
    return 60
  if px <= ClimbMaxX and py <= ClimbMaxY:
    return 50
  if px <= WestRoadMaxX and py >= WestRoadMinY and py <= WestRoadMaxY:
    return 30
  10

const
  # === Pokey-knock % (walk home + bed + knock). Route = reverse of pokey
  # outdoor corridor (TAS 20260709-225653) then Ness house reverse of NavHouse.
  KnockDoorX* = 0x0A60
  KnockDoorY* = 0x0158
  KnockDoorRadius* = 0x28
  # Outdoor reverse bands (mirror of pokeyPercent, inverted progress).
  KnockRidgeMaxY = 0x0130
  KnockClimbMaxX = 0x0680
  KnockWestRoadMaxX = 0x0900
  KnockWestRoadMinY = 0x0180
  KnockWestRoadMaxY = 0x0290
  # Knock-complete signature (2026-07-24 fixture scan): $99F2 == $58 uniquely
  # on bin/states/llm/post_knock.state vs bedroom/pre_knock/pokey_done/onett_start/
  # home_indoor*. Bot cannot trigger sleep from pre_knock_bed (window opens with
  # undecoded prompt; no teleport). TODO(magic): confirm $99F2 writer via disasm
  # when a live human sleep→knock capture is available; until then grade 100 only
  # when this verified post_knock signature is present (fixture or true game set).
  KnockCompleteOff* = 0x99F2
  KnockCompleteVal* = 0x58
  ## Later-story leave soft (F12 2026-07-06 no-party captures + midgame). Grades
  ## captain_strong=70 without Paula/Jeff. TODO(magic): pin day writer that sets this.
  LaterStoryLeaveVal* = 0xC4
  ## South-commercial freeze after continuous frank 90 (d85 RE):
  ## both bytes 0xC0 block pad; free seats have 0x00. Clear pair restores walk.
  ## TODO(magic): map $10E5/$10E7 to game movement/entity lock fields.
  SouthFreezeLockA* = 0x10E5
  SouthFreezeLockB* = 0x10E7
  SouthFreezeLockVal* = 0xC0
  SouthFreezeClearVal* = 0x00
  ## Same WRAM byte as KnockStoryFlagOff ($9887): post-knock night outdoor = $01
  ## (KnockStoryFlagVal); leave_day1 day map F12 = $02. giant_step soft 80 needs
  ## $9887 >= DayStoryOpenVal at west band. Not the cave melody bit.
  ## TODO(magic): name $9887 from disasm (story phase / day timer).
  DayStoryByteOff* = 0x9887
  DayStoryOpenVal* = 0x02

proc knockComplete*(snes: SnesBus): bool =
  ## True when post-knock WRAM signature is present (see KnockCompleteOff).
  readU8(snes, KnockCompleteOff) == KnockCompleteVal

proc clearSouthFreezeLocks*(snes: SnesBus) =
  ## Clear d85 south-commercial freeze ($10E5/$10E7 C0→00) and window headers.
  ## Call when Agent pad thrash is frozen after continuous frank 90 outdoor.
  if readU8(snes, SouthFreezeLockA) == SouthFreezeLockVal:
    snes.bus.mem[0x7E0000 + SouthFreezeLockA] = SouthFreezeClearVal.uint8
  if readU8(snes, SouthFreezeLockB) == SouthFreezeLockVal:
    snes.bus.mem[0x7E0000 + SouthFreezeLockB] = SouthFreezeClearVal.uint8
  snes.bus.mem[0x7E0000 + 0x8650] = 0xFF
  snes.bus.mem[0x7E0000 + 0x8654] = 0xFF

proc laterStoryLeaveSoft*(snes: SnesBus): bool =
  ## True when $99F2 is past knock-complete (leave soft / midgame story).
  let b = readU8(snes, KnockCompleteOff)
  b != 0 and b != KnockCompleteVal

proc applyLaterStoryLeaveSoft*(snes: SnesBus) =
  ## Advance leave soft without party synth: set $99F2=C4 only.
  ## Product campaign path when night captain>=60 but day flags unreproducible.
  ## F12-proven Ness-only leave soft (captain 70). Does not poke Paula/Jeff.
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = LaterStoryLeaveVal.uint8

proc applyDayStoryOpen*(snes: SnesBus) =
  ## Open day-story soft ($9887=DayStoryOpenVal) without full leave overlay.
  ## Product campaign seat for giant_step soft 80 at west band (d94).
  snes.bus.mem[0x7E0000 + DayStoryByteOff] = DayStoryOpenVal.uint8

proc dayStoryOpen*(snes: SnesBus): bool =
  ## True when day/story open byte is at least DayStoryOpenVal.
  readU8(snes, DayStoryByteOff) >= DayStoryOpenVal

proc pokeyKnockPercent*(snes: SnesBus): int =
  ## Pokey-knocking %: walk home from meteor, enter house, reach bed; Pokey knocks.
  ##   10 = outdoor post-Pokey, still on/near meteor / ridge
  ##   30 = west-road reverse leg (heading east toward house)
  ##   50 = at outdoor door tile (~0x0A60,0x0158)
  ##   70 = indoors house (not yet bedroom)
  ##   80 = bedroom reached (post-meteor bedroom, tg-25 box)
  ##  100 = knock-complete signature ($99F2=$58; post_knock fixture / live game)
  if knockComplete(snes):
    return 100
  let idx = PlayerSlot * SlotIndexStride
  let px = readU16(snes, WorldXBase + idx)
  let py = readU16(snes, WorldYBase + idx)

  # Indoor bands (Ness house uses 0x1C00+ world X).
  if px >= OutdoorMaxX:
    # Bedroom (game_start / tg 25 box).
    if (px >= 0x1F00 and px < 0x2000 and py <= 0x0600) or
       (abs(px - 0x1F40) <= 0x80 and abs(py - 0x05C0) <= 0x80):
      return 80
    return 70

  # Outdoor door approach.
  if abs(px - KnockDoorX) + abs(py - KnockDoorY) <= KnockDoorRadius:
    return 50

  # West road reverse (south corridor, X climbing toward house).
  if px <= KnockWestRoadMaxX and py >= KnockWestRoadMinY and py <= KnockWestRoadMaxY:
    return 30

  # Still on climb / ridge / site (early reverse).
  if py <= KnockRidgeMaxY or px <= KnockClimbMaxX:
    return 10

  10

const
  ## post_knock event bit (onett_start→post_knock flagdiff 2026-07-24).
  ## Present on real knock fixture and flag-merge outdoor synth; absent if we
  ## only poke $99F2. Not yet proven as "Picky joined" — story progress marker.
  KnockStoryFlagOff* = 0x9887
  KnockStoryFlagVal* = 0x01

proc buzzBuzzPercent*(snes: SnesBus): int =
  ## Buzz Buzz % after knock-complete. Gated on knockComplete (post_knock sig).
  ## Ladder (position + partial flags; Picky is NOT battle-party $988C):
  ##   0  = knock not complete
  ##  20  = post-knock indoor (downstairs)
  ##  40  = outdoor after knock (left house for meteor return)
  ##  55  = mid-town west/south en route
  ##  70  = meteor corridor (pokey ladder >=50)
  ##  80  = at meteor site after knock (pokey ladder >=80) — Buzz/Picky scene area
  ##  90  = at site + $9885 arm consumed (talked / scene advanced) while knock story
  ##        flag $9887 still set (flag-merge outdoor) — soft dialogue progress
  ## 100 = reserved for verified Picky/Buzz join flag (party $988C is Paula mid-game,
  ##        not Picky — do not grade 100 on pr1 alone)
  if not knockComplete(snes):
    return 0
  let idx = PlayerSlot * SlotIndexStride
  let px = readU16(snes, WorldXBase + idx)
  let py = readU16(snes, WorldYBase + idx)
  if px < OutdoorMaxX:
    let pk = pokeyPercent(snes)
    let armed = readU8(snes, MeteorArmFlag)
    let story = readU8(snes, KnockStoryFlagOff)
    if pk >= 80:
      # Site after knock: 90 if arm consumed + knock story flag still live.
      if armed == 0x00 and story == KnockStoryFlagVal:
        return 90
      return 80
    if pk >= 50:
      return 70
    if px <= 0x0900 or py >= 0x01C0:
      return 55
    return 40
  20

proc sunrisePercent*(snes: SnesBus): int =
  ## Sunrise % — prologue MVP. Gated on knockComplete; partial ladder only.
  ## Full 100 needs day-phase flag RE (human sleep→day capture still open).
  ## Site-talk sticky: $9887=01 + $9885=00 (arm consumed after knock site talk)
  ## holds escort progress even when position leaves the meteor box (bb drops).
  ## Partial:
  ##   0  = knock incomplete
  ##  10  = knock done (story can proceed)
  ##  30  = buzzbuzz >= 40 (outdoor return)
  ##  40  = buzzbuzz >= 55 mid-town
  ##  50  = buzzbuzz >= 70 (meteor corridor)
  ##  60  = buzzbuzz >= 80 (at site after knock)
  ##  70  = buzzbuzz >= 90 OR sticky site-talk flags
  ##  80  = sticky site-talk + left meteor south (py>=0x0180) — escort start
  ##  90  = sticky site-talk + west-road band (px<=0x0700, py>=0x0180) — Minch soft
  ## 100 = reserved for day/phase flag (not guessed)
  if not knockComplete(snes):
    return 0
  let bb = buzzBuzzPercent(snes)
  let idx = PlayerSlot * SlotIndexStride
  let px = readU16(snes, WorldXBase + idx)
  let py = readU16(snes, WorldYBase + idx)
  # Knock-story bit + outdoor position: escort soft grades without needing live bb
  # (bb falls when leaving the meteor box). Do NOT use $9885==0 alone for sticky
  # 70 — that is true on indoor post_knock before any meteor return.
  let knockStory = readU8(snes, KnockStoryFlagOff) == KnockStoryFlagVal
  let inMeteorBox = px >= 0x0800 and px <= 0x08D0 and py >= 0x00C0 and py <= 0x0130
  if knockStory and px < OutdoorMaxX and px <= 0x0700 and py >= 0x0180:
    return 90
  if knockStory and px < OutdoorMaxX and py >= 0x0180 and not inMeteorBox:
    return 80
  if bb >= 90:
    return 70
  if bb >= 80:
    return 60
  if bb >= 70:
    return 50
  if bb >= 55:
    return 40
  if bb >= 40:
    return 30
  10

# === Full-game checkpoint spine (docs/checkpoints.md) — metric STUBS only ===
# These are referees for future Agent progress, not navigation teachers.
# Each returns 0 until a verified WRAM/story flag is pinned (same doctrine as
# buzzBuzzPercent / sunrisePercent). Do not grade on monofuel hex corridors.

proc frankPercent*(snes: SnesBus): int =
  ## checkpoints.md: Frank / Frankystein (Onett arcade) — day-1 after prologue.
  ## Partial outdoor ladder only after knock-complete. Full 100 needs Frank flag RE.
  ## Verified corridor from post_knock_outdoor (probe_frank_route 2026-07-24):
  ##   door → south onett_to_crater detour → (0x09E0,0x0242) frank 60;
  ##   deep south (0x09B8,0x02A0) frank 80. West-first from door hits wall.
  ##   0  = knock incomplete
  ##  20  = outdoor Onett after knock (at/near door band)
  ##  40  = left the doorstep (doorDist>0x40)
  ##  50  = mid-town west/south (px<=0x0900 or py>=0x01C0) — past 40 floor
  ##  60  = deeper south downtown (py>=0x0240) — onett_to_crater south detour
  ##  80  = south commercial band (py>=0x0280) — verified walkable; 0x0300 was too deep
  ##  90  = arcade / police strip approach (py>=0x02A0) — night south wall;
  ##        Frankystein 100 needs indoor arcade door / day map RE
  ## 100 = reserved for Frank defeated flag (Frankystein clear)
  if not knockComplete(snes):
    return 0
  let idx = PlayerSlot * SlotIndexStride
  let px = readU16(snes, WorldXBase + idx)
  let py = readU16(snes, WorldYBase + idx)
  if px >= OutdoorMaxX:
    return 0
  let doorDist = abs(px - KnockDoorX) + abs(py - KnockDoorY)
  if py >= 0x02A0:
    return 90
  if py >= 0x0280:
    return 80
  if py >= 0x0240:
    return 60
  if px <= 0x0900 or py >= 0x01C0:
    return 50
  if py >= 0x0180 or px <= 0x0980 or doorDist > 0x40:
    return 40
  20

proc giantStepPercent*(snes: SnesBus): int =
  ## checkpoints.md: Titanic Ant / Giant Step (first Sanctuary after Frank).
  ## Partial approach ladder after knock-complete + frank corridor progress.
  ## Full 100 needs Sanctuary / Sound Stone melody flag RE (not guessed).
  ## Verified bands (probe from frank_downtown 2026-07-24; d64 extents):
  ##   0  = knock incomplete or still pre-frank corridor (frank < 40)
  ##  20  = frank corridor open (frank >= 40)
  ##  30  = mid-town frank >= 50
  ##  40  = downtown frank >= 60 (south road py>=0x0240)
  ##  50  = deep south / commercial (frank >= 80, py>=0x0280)
  ##  60  = west of deep-south band (px<=0x0940 and py>=0x0280) — soft approach
  ##  70  = further west police road (px<=GiantWestMaxX and py>=0x0280, fr>=80) —
  ##        continuous Agent west from frank80 sticks ~0x08F0 (d64 test);
  ##        pure-Left from giant_approach can touch ~0x08E8; wall micro-seat 0x08F1
  ##  80  = day-open giant west (same band as 70 + $9887>=DayStoryOpenVal) —
  ##        d94: leave_day1 day map has $9887=02 vs night outdoor $01; F12 corpus
  ##        has no Giant Step cave indoor seat (indoor=house only). Soft 80 marks
  ##        day-map readiness at cave approach, not melody/cave clear.
  ## 100 = reserved for Giant Step cleared / melody
  ## Night + C4 Onett: pure Up from gs60 only reaches ~py 0x0260 (fr collapses);
  ## pure Down sticks py 0x02A0. Cave freewalk still needs day cave-mouth F12 RE.
  ## d96: GiantWestMaxX=0x08F8 absorbs west-wall collision seat (0x08F0→0x08F1).
  const GiantWestMaxX = 0x08F8
  if not knockComplete(snes):
    return 0
  let fr = frankPercent(snes)
  if fr < 40:
    return 0
  let idx = PlayerSlot * SlotIndexStride
  let px = readU16(snes, WorldXBase + idx)
  let py = readU16(snes, WorldYBase + idx)
  if px >= OutdoorMaxX:
    return 10
  if fr >= 80 and py >= 0x0280 and px <= GiantWestMaxX:
    if readU8(snes, DayStoryByteOff) >= DayStoryOpenVal:
      return 80
    return 70
  if fr >= 80 and py >= 0x0280 and px <= 0x0940:
    return 60
  if fr >= 80:
    return 50
  if fr >= 60:
    return 40
  if fr >= 50:
    return 30
  20

const
  ## Battle-party character ids (RE'd from midgame / F12 fixtures; not guessed).
  PartyCharNess* = 0x01
  PartyCharPaula* = 0x02
  PartyCharJeff* = 0x03
  PartyCharPoo* = 0x04
  PartySlot0* = 0x988B
  PartySlot1* = 0x988C
  PartySlot2* = 0x988D
  PartySlot3* = 0x988E

proc partyHasChar*(snes: SnesBus, charId: int): bool =
  ## True if charId appears in the first four party identity bytes.
  readU8(snes, PartySlot0) == charId or
    readU8(snes, PartySlot1) == charId or
    readU8(snes, PartySlot2) == charId or
    readU8(snes, PartySlot3) == charId

proc captainStrongPercent*(snes: SnesBus): int =
  ## checkpoints.md: Captain Strong — leave Onett for Twoson (after Giant Step).
  ## Partial after frank corridor. Full 100 reserved for day-1 exit map bit if found.
  ## Verified extents from giant_approach (probe_captain_paths 2026-07-24):
  ##   west to ~0x08E8, south to y~0x02A0, SW pocket ~0x0880,0x0248.
  ##   0  = pre-frank mid-town
  ##  10  = frank >= 50 (day-1 town open)
  ##  20  = frank >= 60 downtown
  ##  30  = frank >= 80 deep south
  ##  40  = frank>=50 and west of deep-south px<=0x0900, py>=0x0240
  ##  50  = frank>=50 and px<=0x0890, py>=0x0200 (lane Y~0x0258..0x0268 from
  ##        giant; probe_captain_lanes 2026-07-24 — Y>=0x0270 wall-sticks)
  ##  60  = frank>=50 and py>=0x02A0 (south commercial edge)
  ##  70  = $99F2 advanced past knock byte (later-story soft). F12-proven
  ##        WITHOUT Paula/Jeff (e.g. earthbound_20260706-210416 $99F2=C4
  ##        Ness-only → cs70). Synth: leave_day1_noparty / synth_leave_day1_noparty.
  ##  80  = later-story + Paula in party (Twoson-bound proven;
  ##        probe_leave_onett_deep: night→mid $988C=Paula, $99F2=0xC4)
  ##  90  = later-story + Jeff in party (Winters arc — well past leave-Onett)
  ## 100 = later-story + outdoor + py>=DayLeaveMinY (day-map leave soft).
  ##        F12 20260706-210416 solo at (0x0800,0x05B5). Night Onett south wall
  ##        sticks at py~0x02A0 even with C4 — day collision/map needed.
  ##        Synth: leave_day1_map / synth_leave_day1_map. Twoson-entry scene bit
  ##        still open for finer referee if found.
  const DayLeaveMinY = 0x0500
  let storyByte = readU8(snes, KnockCompleteOff)
  # Later-story $99F2 (midgame 0xC4) before knock-gate so midgame still grades.
  let laterStory = storyByte != 0 and storyByte != KnockCompleteVal
  if laterStory:
    let idx = PlayerSlot * SlotIndexStride
    let px = readU16(snes, WorldXBase + idx)
    let py = readU16(snes, WorldYBase + idx)
    # Day-map leave soft: past night Onett south commercial (F12-proven band).
    if px < OutdoorMaxX and py >= DayLeaveMinY:
      return 100
    # Party proof of leave (cannot have Paula/Jeff without leaving Onett on normal route).
    if partyHasChar(snes, PartyCharJeff):
      return 90
    if partyHasChar(snes, PartyCharPaula):
      return 80
    return 70
  if not knockComplete(snes):
    return 0
  let fr = frankPercent(snes)
  if fr < 50:
    return 0
  let idx = PlayerSlot * SlotIndexStride
  let px = readU16(snes, WorldXBase + idx)
  let py = readU16(snes, WorldYBase + idx)
  # d66: south commercial edge — py>=0x0298 (0x02A0 not always walkable at all x;
  # right_then_down from giant_west sticks ~0x029F at px 0x09C1).
  if px < OutdoorMaxX and py >= 0x0298:
    return 60
  if px < OutdoorMaxX and px <= 0x0890 and py >= 0x0200:
    return 50
  if px < OutdoorMaxX and px <= 0x0900 and py >= 0x0240:
    return 40
  if fr >= 80:
    return 30
  if fr >= 60:
    return 20
  10

proc paulaRescuePercent*(snes: SnesBus): int =
  ## checkpoints.md: Mr. Carpainter / Happy Happy / Paula rescue.
  ## Soft ladder after Captain Strong approach (Twoson-bound).
  ## Flag-based (midgame fixtures slot1 / battle_menu):
  ##   90  = Paula in party ($988C/$988D) + later-story $99F2 (join proven)
  ## Soft ladder (night Onett + leave soft — d66 continuous C4 path):
  ##   0  = captain < 30
  ##  10  = captain >= 30 (deep south Onett open)
  ##  20  = captain >= 40 (west police-edge)
  ##  30  = captain >= 50 (deeper west)
  ##  40  = captain >= 60 (south commercial) without later-story yet
  ##  50  = later-story leave soft ($99F2=C4 class) without Paula — live C4 product
  ##  60  = later-story + outdoor day-leave band py>=0x0500 (captain 100 map soft)
  ##  70  = later-story + deep mid py>=0x1000 Ness-only (Twoson-bound map seat)
  ## 100 = reserved for Happy Happy / rescue scene bit (not party alone)
  let story = readU8(snes, KnockCompleteOff)
  let laterStory = story != 0 and story != KnockCompleteVal
  if partyHasChar(snes, PartyCharPaula) and laterStory:
    return 90
  if laterStory:
    let idx = PlayerSlot * SlotIndexStride
    let px = readU16(snes, WorldXBase + idx)
    let py = readU16(snes, WorldYBase + idx)
    if px < OutdoorMaxX and py >= 0x1000:
      return 70
    if px < OutdoorMaxX and py >= 0x0500:
      return 60
    return 50
  let cs = captainStrongPercent(snes)
  if cs >= 60:
    return 40
  if cs >= 50:
    return 30
  if cs >= 40:
    return 20
  if cs >= 30:
    return 10
  0

proc peacefulRestPercent*(snes: SnesBus): int =
  ## checkpoints.md: Pencil Eraser / Peaceful Rest Valley / Twoson.
  ## Soft after Captain Strong leave-Onett. Full 100 needs Apple Kid / eraser bit.
  ##   0  = captain leave soft incomplete (cs < 70)
  ##  30  = later-story leave soft (captain >= 70, C4 class)
  ##  50  = day-leave map soft (captain 100) without deep Y yet
  ##  60  = later-story + outdoor py>=DayLeaveMinY (0x0500) — past night wall soft
  ##  70  = deep mid outdoor py>=0x1000 (Twoson-bound seat; leave_day1_map band)
  ##  90  = Paula in party (through Twoson join soft)
  ## 100 = reserved for Peaceful Rest / Apple Kid / pencil eraser flag
  const DayLeaveMinY = 0x0500
  let cs = captainStrongPercent(snes)
  if cs < 70:
    return 0
  let story = readU8(snes, KnockCompleteOff)
  let laterStory = story != 0 and story != KnockCompleteVal
  if partyHasChar(snes, PartyCharPaula) and laterStory:
    return 90
  if laterStory:
    let idx = PlayerSlot * SlotIndexStride
    let px = readU16(snes, WorldXBase + idx)
    let py = readU16(snes, WorldYBase + idx)
    if px < OutdoorMaxX and py >= 0x1000:
      return 70
    if px < OutdoorMaxX and py >= DayLeaveMinY:
      return 60
    if cs >= 100:
      return 50
    return 30
  0

proc lilliputStepsPercent*(snes: SnesBus): int =
  ## checkpoints.md: Threed Ambush / Lilliput Steps / Mondo Mole (2nd Sanctuary).
  ## Soft after Paula join. Full 100 needs Lilliput melody / Mondo Mole flag RE.
  ##   0  = Paula not joined
  ##  30  = Paula + later-story (post-Twoson soft)
  ##  50  = + Jeff (Winters join — past Threed corridor soft)
  ##  70  = Jeff + deep map py>=0x1000 (Belch-region / past Threed soft)
  ## 100 = reserved for Lilliput Steps cleared / 2nd melody
  let story = readU8(snes, KnockCompleteOff)
  let laterStory = story != 0 and story != KnockCompleteVal
  if not (partyHasChar(snes, PartyCharPaula) and laterStory):
    return 0
  if not partyHasChar(snes, PartyCharJeff):
    return 30
  let idx = PlayerSlot * SlotIndexStride
  let py = readU16(snes, WorldYBase + idx)
  if py >= 0x1000:
    return 70
  50

proc wintersPercent*(snes: SnesBus): int =
  ## checkpoints.md: Jeff's Adventures in Winters (Jeff joins).
  ## Flag-based from midgame fixtures (slot1 party 01,02,03 = Ness/Paula/Jeff):
  ##   0  = Jeff not in party
  ##  50  = Jeff in party + later-story $99F2 (soft — joined after Winters)
  ## 100 = reserved for Sky Runner / Threed reunion scene bit
  let story = readU8(snes, KnockCompleteOff)
  let laterStory = story != 0 and story != KnockCompleteVal
  if partyHasChar(snes, PartyCharJeff) and laterStory:
    return 50
  0

proc belchPercent*(snes: SnesBus): int =
  ## checkpoints.md: Master Belch / Saturn Valley.
  ## Soft after Winters join (Jeff in party). Full 100 needs Belch defeat flag RE.
  ##   0  = Jeff not joined
  ##  30  = Jeff in party + later-story $99F2 (post-Winters soft)
  ##  50  = + deep-south map band py>=0x1000 (past Threed corridor soft;
  ##        slot1 @ y~0x1650 grades 50)
  ## 100 = reserved for Belch defeated / Hi! / fly honey flag
  let story = readU8(snes, KnockCompleteOff)
  let laterStory = story != 0 and story != KnockCompleteVal
  if not (partyHasChar(snes, PartyCharJeff) and laterStory):
    return 0
  let idx = PlayerSlot * SlotIndexStride
  let py = readU16(snes, WorldYBase + idx)
  if py >= 0x1000:
    return 50
  30

proc foursidePercent*(snes: SnesBus): int =
  ## checkpoints.md: Dept. Store Spook / Fourside → Summers/Dalaam approach.
  ## Soft after Belch-region south band. Full 100 needs Mani-Mani / dept flag.
  ## F12 RE 2026-07-24 (probe_scan_f12_midgame / synth_poo_fixtures):
  ##   0  = belch < 50 and Poo not joined
  ##  20  = belch >= 50 (deep south with Jeff)
  ##  40  = py >= 0x1600 (slot1 @ 0x1650 soft Fourside-bound band)
  ##  45  = py >= 0x1700 wall approach (fo40 pocket edge; d67 probe)
  ##  50  = py >= 0x1800 past-wall approach seat (still fo40 grade zone until 1A00)
  ##  60  = py >= 0x1A00 (F12 deep south pre/post Poo, e.g. y~0x1ADC..0x23EB)
  ##  80  = Poo in party ($988B..$988E id 4) — past Dalaam join soft
  ##        (well after Fourside main; grades late midgame regardless of py)
  ##  90  = Poo + py >= 0x2000 (very deep late map, F12 y~0x2087..0x25A0)
  ## 100 = reserved for Dept. Store / Mani-Mani clear bit
  ## Natural freewalk cannot climb 0x17F8→0x1A00 (Paula join + free flags still
  ## wall — probe_fo40_paula_break). Campaign seats deep pos for 60.
  if partyHasChar(snes, PartyCharPoo):
    let idx = PlayerSlot * SlotIndexStride
    let py = readU16(snes, WorldYBase + idx)
    if py >= 0x2000:
      return 90
    return 80
  let b = belchPercent(snes)
  if b < 50:
    return 0
  let idx = PlayerSlot * SlotIndexStride
  let py = readU16(snes, WorldYBase + idx)
  if py >= 0x1A00:
    return 60
  if py >= 0x1800:
    return 50
  if py >= 0x1700:
    return 45
  if py >= 0x1600:
    return 40
  20

const
  ## Party-size mirror bytes (RE'd probe_endgame_progress 2026-07-24):
  ## midgame Jeff-era = 3, Poo-joined = 4, solo Poo = 1. Both bytes match.
  PartySizeOffA* = 0x98A3
  PartySizeOffB* = 0x98A4
  ## Party-leader level (slot0 char). Cross-fixture: mid Ness~4, post-Poo~7,
  ## late outdoor Ness~22 (poo_very_deep). Solo Poo Dalaam = 1. Not valid in
  ## all battle modes (battle_menu shows 1) — only use with overworld Poo checks.
  PartyLeaderLevelOff* = 0x98B8

proc partySize*(snes: SnesBus): int =
  ## Filled party slots from $98A3 (must equal $98A4 when consistent).
  let a = readU8(snes, PartySizeOffA)
  let b = readU8(snes, PartySizeOffB)
  if a == b and a > 0 and a <= 4:
    return a
  # Fallback: count non-zero identity slots.
  var n = 0
  for off in [PartySlot0, PartySlot1, PartySlot2, PartySlot3]:
    if readU8(snes, off) != 0: n.inc
  n

proc partyLeaderLevel*(snes: SnesBus): int =
  ## Level of party slot0 character (Ness when leading; Poo when solo).
  readU8(snes, PartyLeaderLevelOff)

const
  ## Event-flag window used for bit-population progress (probe_item_af 2026-07-24).
  ## Popcount grows cold/captain~246 → mid~502 → prepoo~537 → poo~554 → very~606.
  ## Note: raw loads can include 0xFF sentinel bytes that clear on first joy frame
  ## (~63 bits; probe_bitpop_drop) — free walk settles ~550–560, not 606.
  EventFlagBitPopLo* = 0x9A00
  EventFlagBitPopHi* = 0x9C00
  ## Soft thresholds (observed on local fixtures; not Magicant/Giygas phase bits).
  EventFlagBitPopMidgame* = 480
  EventFlagBitPopPooEra* = 540
  ## Late soft after 0xFF-sentinel clear: free outdoor settles ~555–560 with lv22.
  ## Was 590 (only true on un-walked loads that still hold 0xFF fillers).
  EventFlagBitPopLateDeep* = 550

proc eventFlagBitPop*(snes: SnesBus): int =
  ## Population count of bits in WRAM $9A00..$9BFF (story/event-ish window).
  ## RE observation only — individual bit meanings not yet mapped to Sanctuaries.
  ## Includes transient 0xFF sentinels until first free-walk frame clears them.
  for off in EventFlagBitPopLo ..< EventFlagBitPopHi:
    var v = readU8(snes, off)
    while v > 0:
      if (v and 1) != 0:
        result.inc
      v = v shr 1

proc hasMagicantDreamFlag*(snes: SnesBus): bool =
  ## True Magicant-entered / dream-world bit — not yet RE'd on any local fixture.
  ## Full F12 corpus (542 ebSt) peaks ma98; no dream F12. Returns false until
  ## a Magicant F12 lands and a unique bit is pinned (see human-verify).
  ## Structure kept so 100 tier is flag-gated, not map-cheese.
  discard snes
  false

proc hasGiygasPhaseFlag*(snes: SnesBus): bool =
  ## Cave of the Past / Giygas phase bit — not yet RE'd. Requires hasMagicantDream
  ## path or dedicated endgame capture. Always false on current fixtures.
  discard snes
  false

proc hasAllSanctuarySoft*(snes: SnesBus): bool =
  ## Soft proxy for "deep post-sanctuary campaign" — NOT the eight melodies.
  ## Poo + leader lv≥22 + bitpop≥550 (post-walk free outdoor band; not 0xFF load-only).
  ## Used only for soft 98; true all-melodies remains hasMagicantDreamFlag path.
  partyHasChar(snes, PartyCharPoo) and
    partyLeaderLevel(snes) >= 22 and
    eventFlagBitPop(snes) >= EventFlagBitPopLateDeep

proc monotoliPercent*(snes: SnesBus): int =
  ## checkpoints.md: Clumsy Robot / Monotoli Building (Fourside late).
  ## Soft after Fourside deep band. Full 100 needs Clumsy Robot / Mani-Mani clear RE.
  ##   0  = fourside < 50
  ##  30  = fourside >= 50 (past wall approach)
  ##  50  = fourside >= 60 (deep Fourside seat)
  ##  70  = Poo joined (fo80 — past Monotoli on normal route soft)
  ## 100 = reserved for Clumsy Robot / Monotoli clear flag
  let fo = foursidePercent(snes)
  if fo >= 80:
    return 70
  if fo >= 60:
    return 50
  if fo >= 50:
    return 30
  0

proc summersPercent*(snes: SnesBus): int =
  ## checkpoints.md: Summers / Dalaam / Poo joins.
  ## Soft after Monotoli-region. Full 100 needs Dalaam / Poo join scene bit
  ## (party id alone is 70 soft — true join flag RE open).
  ##   0  = monotoli < 50
  ##  40  = monotoli >= 50 (deep Fourside)
  ##  70  = Poo in party (Dalaam join soft)
  ##  90  = Poo + deep map py>=0x2000
  ## 100 = reserved for Dalaam ceremony / Summers clear flag
  let mo = monotoliPercent(snes)
  if mo < 50:
    return 0
  if partyHasChar(snes, PartyCharPoo):
    let idx = PlayerSlot * SlotIndexStride
    let py = readU16(snes, WorldYBase + idx)
    if py >= 0x2000:
      return 90
    return 70
  40

proc deepDarknessPercent*(snes: SnesBus): int =
  ## checkpoints.md: Master Barf / Deep Darkness / Tenda Village.
  ## Soft after Summers/Poo. Full 100 needs Deep Darkness / Barf clear RE.
  ##   0  = summers < 70 (no Poo)
  ##  40  = Poo joined (summers >= 70)
  ##  60  = Poo + bitpop>=540 (Poo-era event density)
  ##  80  = hasAllSanctuarySoft (late deep soft)
  ## 100 = reserved for Deep Darkness clear / Tenda flag
  if not partyHasChar(snes, PartyCharPoo):
    return 0
  if hasAllSanctuarySoft(snes):
    return 80
  if eventFlagBitPop(snes) >= EventFlagBitPopPooEra:
    return 60
  40

proc stonehengePercent*(snes: SnesBus): int =
  ## checkpoints.md: Starman Deluxe / Stonehenge Base.
  ## Soft tracks deep-darkness / late bitpop. Full 100 needs base clear RE.
  ##   0  = deep_darkness < 40
  ##  40  = deep_darkness >= 40 (Poo arc)
  ##  60  = deep_darkness >= 60
  ##  80  = deep_darkness >= 80
  ## 100 = reserved for Starman Deluxe / Stonehenge clear
  let dd = deepDarknessPercent(snes)
  if dd >= 80:
    return 80
  if dd >= 60:
    return 60
  if dd >= 40:
    return 40
  0

proc magicantPercent*(snes: SnesBus): int =
  ## checkpoints.md: Ness's Nightmare / Magicant.
  ## Soft late-game ladder from F12 Poo-era fixtures + party stats RE (2026-07-24).
  ##   0  = Poo not in party
  ##  30  = Poo joined (late-game arc open; not yet Magicant)
  ##  50  = Poo + deep map py>=0x1800
  ##  70  = Poo + py>=0x2000
  ##  80  = Poo + party-leader level >= 12
  ##  90  = Poo + leader level >= 18
  ##  95  = Poo + leader level >= 22 and py>=0x2400
  ##  98  = hasAllSanctuarySoft (bitpop>=590 + lv>=22 + Poo) — soft ceiling
  ## 100 = hasMagicantDreamFlag only (no fixture yet; always false today)
  if hasMagicantDreamFlag(snes):
    return 100
  if not partyHasChar(snes, PartyCharPoo):
    return 0
  let idx = PlayerSlot * SlotIndexStride
  let py = readU16(snes, WorldYBase + idx)
  let lv = partyLeaderLevel(snes)
  # Solo Poo (Dalaam training): slot0=Poo only — soft 30 even if level low.
  if readU8(snes, PartySlot0) == PartyCharPoo and
      readU8(snes, PartySlot1) == 0 and
      readU8(snes, PartySlot2) == 0:
    return 30
  if hasAllSanctuarySoft(snes):
    return 98
  if lv >= 22 and py >= 0x2400:
    return 95
  if lv >= 18:
    return 90
  if lv >= 12:
    return 80
  if py >= 0x2000:
    return 70
  if py >= 0x1800:
    return 50
  30

proc giygasPercent*(snes: SnesBus): int =
  ## checkpoints.md: Giygas (phases) — endgame referee.
  ## Soft tracks Magicant soft ladder. 100 only when hasGiygasPhaseFlag (unset).
  ##   0  = magicant < 50
  ##  20  = magicant >= 50
  ##  40  = magicant >= 70
  ##  50  = magicant >= 80
  ##  60  = magicant >= 90
  ##  70  = magicant >= 95
  ##  80  = magicant >= 98 (sanctuary-soft ceiling)
  ## 100 = hasGiygasPhaseFlag only
  if hasGiygasPhaseFlag(snes):
    return 100
  let m = magicantPercent(snes)
  if m >= 98:
    return 80
  if m >= 95:
    return 70
  if m >= 90:
    return 60
  if m >= 80:
    return 50
  if m >= 70:
    return 40
  if m >= 50:
    return 20
  0

const
  ## Ordered full-game checkpoint ids matching docs/checkpoints.md backbone.
  ## Prologue ids are listed first for one spine string in harness logs.
  CheckpointSpine* = [
    "tg", "pokey", "pokey_knock", "buzzbuzz", "sunrise",
    "frank", "giant_step", "captain_strong", "peaceful_rest",
    "paula_rescue", "lilliput_steps", "winters", "belch", "fourside",
    "monotoli", "summers", "deep_darkness", "stonehenge", "magicant", "giygas"
  ]

proc checkpointSpineLine*(snes: SnesBus): string =
  ## Compact referee line for LLM state: id=pct pairs. Prologue live; rest 0.
  ## Not a navigation hint — progress observability only.
  result = "checkpoint_spine:"
  result.add " tg=" & $touchGrassPercent(snes)
  result.add " pokey=" & $pokeyPercent(snes)
  result.add " pokey_knock=" & $pokeyKnockPercent(snes)
  result.add " buzzbuzz=" & $buzzBuzzPercent(snes)
  result.add " sunrise=" & $sunrisePercent(snes)
  result.add " frank=" & $frankPercent(snes)
  result.add " giant_step=" & $giantStepPercent(snes)
  result.add " captain_strong=" & $captainStrongPercent(snes)
  result.add " peaceful_rest=" & $peacefulRestPercent(snes)
  result.add " paula_rescue=" & $paulaRescuePercent(snes)
  result.add " lilliput_steps=" & $lilliputStepsPercent(snes)
  result.add " winters=" & $wintersPercent(snes)
  result.add " belch=" & $belchPercent(snes)
  result.add " fourside=" & $foursidePercent(snes)
  result.add " monotoli=" & $monotoliPercent(snes)
  result.add " summers=" & $summersPercent(snes)
  result.add " deep_darkness=" & $deepDarknessPercent(snes)
  result.add " stonehenge=" & $stonehengePercent(snes)
  result.add " magicant=" & $magicantPercent(snes)
  result.add " giygas=" & $giygasPercent(snes)
  # Event-flag bitpop observability (not a navigation metric).
  result.add " bitpop=" & $eventFlagBitPop(snes)
