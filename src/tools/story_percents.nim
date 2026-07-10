## Prologue campaign story-percent metrics for llm-ai (docs/llm-sequence.md).
## Field names match harness logs: pokey_pct, pokey_knock_pct, buzzbuzz_pct, sunrise_pct.

import
  ../decompbound/snesbus,
  ./touch_grass

const
  # Outdoor meteor / north-hill objective (slot-24 world pos).
  # Verified from onett_start (probe_pokey_north / probe_pokey_grid / probe_pokey_approach):
  #   House exit (0x0A60,0x0158). Pure Up re-enters Ness house.
  #   Left clear to X~0x0A48, then north corridor along X~0x0A38 to crest (0x0A18,0x00C0).
  #   Northernmost outdoor from this fixture: Y~0x00B8 (X~0x0A28..0x0AE8). Hard wall —
  #   cannot go further north; no outdoor Pokey entity in this band.
  # TODO(magic): pin real meteor-site screen box + Pokey outdoor coords once story
  # opens the hill (likely post knock) or a deeper route is found. Do NOT use Minch
  # indoor 0x1C00..0x1D00 — that is Picky inside Pokey's house, wrong objective.
  OutdoorMaxX* = 0x1C00
  # Widened 2026-07-09: the REAL route (probe_meteor_route, navTo) dips slightly
  # south then takes the WEST lower path (X~0x09B8..0x09E9) before winding
  # north — the old 0x0A00 floor zeroed pokey_pct mid-climb.
  HillBandMinX* = 0x0980
  HillBandMaxX* = 0x0B10
  # On the approach/climb: west lower path sits at Y~0x018E; climb entry
  # 0x0145; anything at/below this in the band counts as "heading to the hill".
  NorthHillMaxY* = 0x01A0
  # Crest / north plateau reachable from onett_start (NOT confirmed meteor site).
  # probe_pokey_approach: free roam minY=0x00B8; crest stop ~0x00C0.
  # Graded as 60 only as "north hill crest" interim — meteor is further and gated.
  # TODO(magic): replace with true meteor screen when coords known.
  CrestMaxY* = 0x00C8
  CrestMinY* = 0x00A8
  # Pokey outdoor approach — UNKNOWN until meteor is reachable.
  # Placeholder far north so 90 never fires on house/Minch coords.
  # TODO(magic): real Pokey slot coords at meteor crash site.
  PokeyOutdoorX* = 0x0000
  PokeyOutdoorY* = 0x0000
  PokeyOutdoorRadius* = 0x28
  WindowHeader0* = 0x8650  ## First text/window slot; 0xFF = free (probe_pokey_dlgflag).
  EventFlagsBase* = 0x988B
  # TODO(magic): sticky "talked to Pokey at meteor" event bit — none found yet;
  # previous indoor pre/post talk (wrong NPC) also had no clean flag flip.

proc pokeyPercent*(snes: SnesBus): int =
  ## Pokey %: walk north from Ness house to outdoor meteor and talk to Pokey.
  ## Story win: reach Pokey at the meteorite crash site (outdoors, north of house).
  ## Graded (outdoor only; Minch-indoor grading removed):
  ##   30 = heading north up the hill (Y below door band, hill X band)
  ##   60 = north hill crest / furthest outdoor north from onett_start (Y~0x00B8..0x00C8)
  ##       — interim; true meteor screen TBD (story-gated or unmapped from fixture)
  ##   90 = adjacent to outdoor Pokey (coords TBD — currently never)
  ##   100 = talked to Pokey: adjacent + $8650 != 0xFF (no sticky flag yet)
  let tg = touchGrassPercent(snes)
  let idx = PlayerSlot * SlotIndexStride
  let px = readU16(snes, WorldXBase + idx)
  let py = readU16(snes, WorldYBase + idx)

  # Indoor (Ness or Minch) is never Pokey % progress for this objective.
  if px >= OutdoorMaxX:
    return 0
  if tg < 100:
    return 0

  # Hill / crest X band only (avoid grading random Onett streets west of Minch road).
  let inHillBand = px >= HillBandMinX and px < HillBandMaxX
  if not inHillBand:
    return 0

  # 90/100: outdoor Pokey adjacency (disabled until RE pins coords != 0).
  if PokeyOutdoorX != 0 or PokeyOutdoorY != 0:
    let pdx = abs(px - PokeyOutdoorX)
    let pdy = abs(py - PokeyOutdoorY)
    if pdx + pdy <= PokeyOutdoorRadius:
      # TODO(magic): sticky met-Pokey flag when script RE finds one.
      if readU8(snes, WindowHeader0) != 0xFF:
        return 100
      return 90

  # 60: north crest plateau (reachable end of hill from onett_start).
  if py >= CrestMinY and py <= CrestMaxY:
    return 60

  # 30: on the northward hill approach (north of door step, still outdoor).
  if py <= NorthHillMaxY:
    return 30

  0

proc pokeyKnockPercent*(snes: SnesBus): int =
  ## Pokey-knocking %: return home; knock / meteor invite chain accepted.
  ## Story win: party is on the meteor path (not still idling post-Pokey-visit).
  ## TODO: RE knock/script trigger state; coords alone may not fire the beat.
  discard snes
  0

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
