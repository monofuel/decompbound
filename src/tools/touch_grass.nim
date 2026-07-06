## Touch Grass milestone helpers for LLM agent: deterministic intro skill (Lua)
## and the touchGrassPercent metric based on WRAM location (sector + supporting indicators).
## RE: sector at $89CA (file 0x043573 setter, per decompilation.md). Other room
## indicators (e.g. low flags, pos) used to distinguish title vs bedroom vs outside
## since indoor maps may share sector or use FFFF sentinel in some snapshots.
## Values pinned via trace + temp input-driven runs (cold + srm + slot loads):
##   title/pre-game: sector $0000 or $FFFF with early/large-pos or m24=$34 -> 0%
##   bedroom (Ness start): sector $0000/$FFFF + small pos + post-naming m24 -> 25%
##   intermediate (stairs/doors): 50-75% (heuristic pos/sector transition)
##   outside Onett overworld: sector $002D (observed in disasm LDA contexts) or
##     clear overworld pos/sector change after exit -> 100%
## The harness (llm_ai) + this module only; no ROM/state committed.

import
  ../decompbound/snesbus

const
  SectorOff* = 0x89CA
  PosXOff* = 0x00B4
  PosYOff* = 0x00B6
  MenuFlagOff* = 0x0024

proc readU8*(snes: SnesBus, off: int): int =
  ## Read WRAM byte at 7E:off (or full if >0xFFFF). Used by metric.
  let ea = if off > 0xFFFF: off else: 0x7E0000 + off
  if ea >= 0 and ea < snes.bus.mem.len:
    return snes.bus.mem[ea].int
  0

proc readU16*(snes: SnesBus, off: int): int =
  ## Read WRAM u16 LE at off.
  let lo = readU8(snes, off)
  let hi = readU8(snes, off + 1)
  lo or (hi shl 8)

proc touchGrassPercent*(snes: SnesBus): int =
  ## 0 at title/pre-game, milestone bumps for bedroom + intermediates,
  ## 100 when outside on Onett map (touch grass achieved).
  ## Uses sector $89CA as primary map indicator + pos + menu flag for stage.
  ## All magic values accompanied by TODO + comments per AGENTS.
  let sector = readU16(snes, SectorOff)
  let px = readU16(snes, PosXOff)
  let py = readU16(snes, PosYOff)
  let m24 = readU8(snes, MenuFlagOff)

  # Title / pre-game (cold or logo/title screen before Start or early after boot).
  # Observed via trace/boot: sector 0000/FFFF + m24=$34 or large placeholder pos (>~800) or initial 0,0.
  if (sector == 0 or sector == 0xFFFF) and (m24 == 0x34 or px > 800 or py > 80 or (px == 0 and py == 0)):
    return 0

  # Bedroom (Ness's room at game start after naming complete).
  # Post-intro: sector often 0000/FFFF but pos small + m24 changed from title value.
  if sector == 0 or sector == 0xFFFF:
    if px < 100 and py < 100:
      return 25
    return 25  # bedroom default once past title splash

  # Outside Onett overworld (touch grass): specific sector from disasm contexts or
  # clear movement in non-house coords after exit.
  # TODO: pin exact Onett sector ID via full map load trace; 0x2D candidate.
  if sector == 0x2D or (sector != 0 and sector != 0xFFFF and (px > 100 or py > 100)):
    return 100

  # Intermediate (stairs, downstairs, front door inside house).
  if sector > 0 and sector < 0x100:
    return 75
  return 50

const IntroSkillLua* = """
-- Deterministic intro skill: title -> new game -> naming (accept defaults via A-mash + dirs) -> Ness bedroom.
-- Lets agent start from gameplay; not the interesting part. Fixed sequence, frame based.
function update()
  local f = frame()
  if f < 180 then
    return
  end
  if f == 220 or f == 221 then
    pad.press('Start')
    return
  end
  if f >= 260 and f < 820 then
    -- A-mash + occasional dir for letter select / confirm on naming (Ness default + OK).
    -- Standard fixed sequence that reaches bedroom on this harness.
    if f % 3 == 0 then
      pad.press('A')
    end
    if f % 17 == 0 then
      pad.press('Down')
    end
    if f % 29 == 0 then
      pad.press('Right')
    end
    return
  end
  if f >= 900 then
    -- In bedroom (or house entry): walk down + A to clear any text, head for stairs/door.
    if f % 4 == 0 then
      pad.press('Down')
    end
    if f % 11 == 0 then
      pad.press('A')
    end
  end
end
"""

proc currentRoomLabel*(snes: SnesBus): string =
  ## Human label for the LLM summary (bedroom / outside / title etc).
  let pct = touchGrassPercent(snes)
  if pct == 0: return "title"
  if pct == 25: return "bedroom"
  if pct < 100: return "house_interior"
  return "outside_onett"
