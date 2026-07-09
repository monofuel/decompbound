## Prologue campaign story-percent metrics for llm-ai (docs/llm-sequence.md).
## Scaffold next to touchGrassPercent: stubs return 0 until WRAM/flag heuristics exist.
## Field names match harness logs: pokey_pct, pokey_knock_pct, buzzbuzz_pct, sunrise_pct.

import
  ../decompbound/snesbus

proc pokeyPercent*(snes: SnesBus): int =
  ## Pokey %: reached Pokey's place and completed the "Pokey visited" interaction.
  ## Story win: first social destination after touch grass (neighbor / Pokey's house).
  ## TODO: RE visit/talk flags or pos+dialogue heuristic; fixture planned post-tg100 / onett_start.
  discard snes
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
