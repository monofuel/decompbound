## Prologue campaign story-percent metrics for llm-ai (docs/llm-sequence.md).
## Field names match harness logs: pokey_pct, pokey_knock_pct, buzzbuzz_pct, sunrise_pct.

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
  # Knock flag address filled after WRAM flagdiff (see bin/knock_re_notes.txt).
  # TODO(magic): KnockFlag* pending live RE; ladder uses pos until flag pinned.
  KnockDoorX* = 0x0A60
  KnockDoorY* = 0x0158
  KnockDoorRadius* = 0x28
  # Outdoor reverse bands (mirror of pokeyPercent, inverted progress).
  KnockRidgeMaxY = 0x0130
  KnockClimbMaxX = 0x0680
  KnockWestRoadMaxX = 0x0900
  KnockWestRoadMinY = 0x0180
  KnockWestRoadMaxY = 0x0290
  # ⚠️ The real knock flag is NOT yet RE'd. Bot-driven attempts to trigger the
  # knock from the (verified post-meteor) bedroom were inconclusive — the beat
  # is scripted, so it will replay faithfully from a HUMAN capture (queued in
  # human-verify: prologue-night breadcrumb), which we then flag-diff exactly
  # like the meteor flag $9885. Until then this metric caps at 80 (reaching the
  # bedroom, which IS position-verifiable) rather than grade 100 on a GUESSED
  # flag — no magic without verification (docs/llm-contamination.md doctrine).
  # Candidates from the pokey_free→home_indoor story diff: $9A05/$9A06/$9A0F/
  # $9A10 (00→FF post-meteor) — but those are post-METEOR, not post-KNOCK; do
  # not grade on them until a clean before/after-knock diff confirms the bit.

proc pokeyKnockPercent*(snes: SnesBus): int =
  ## Pokey-knocking %: walk home from meteor, enter house, reach bed; Pokey
  ## knocks. Monotonic POSITION ladder (verifiable); the 100 knock tier awaits
  ## the ground-truth flag (see note above — capped at 80 for now, not guessed):
  ##   10 = outdoor post-Pokey, still on/near meteor / ridge
  ##   30 = west-road reverse leg (heading east toward house)
  ##   50 = at outdoor door tile (~0x0A60,0x0158)
  ##   70 = indoors house (not yet bedroom)
  ##   80 = bedroom reached (post-meteor bedroom, tg-25 box)
  ## All magic + TODO per AGENTS; positions from the verified pokey corridor.
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

proc buzzBuzzPercent*(snes: SnesBus): int =
  ## Buzz Buzz %: meteor / Buzz Buzz sequence; Picky is with the group.
  ## Story win: Buzz Buzz joined the night adventure; party/NPC state includes Picky.
  ## TODO: RE party roster / companion flags for Buzz Buzz + Picky.
  discard snes
  0

proc sunrisePercent*(snes: SnesBus): int =
  ## Sunrise % (prologue MVP): escort brothers home, Lardna kills Buzz Buzz, leave → sunrise.
  ## Story win: (1) Pokey + Picky back at Minch home, (2) Buzz Buzz death scene played,
  ## (3) exit house and day-one Onett begins. Remorse is framing, not a WRAM bit.
  ## TODO: RE sunrise/day flag + Minch-house exit; do not cheese with pos alone.
  discard snes
  0
