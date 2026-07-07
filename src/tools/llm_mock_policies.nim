## Pure mock policy strings for llm_ai verification scenarios.
## Separated so nav and battle paths can be selected independently without
## polluting the main harness or requiring ad-hoc drivers.

const
  NavHousePolicy* = """-- NOTE: escapeMenu+walkTo+winBattle preloaded; A opens menus, B cancels; walk d-pad ONLY; winBattle on in_battle
-- DETERMINISTIC WALK-OUT (verified): from the bedroom (game_start slot 4), the exit is
-- to the LEFT (down the stairs) -> reliably reaches the house interior (tg 75) EVERY run,
-- independent of qwen. The old target (0x1EC0,0x0150) headed UP into the dresser and stayed
-- stuck at 25. This is the consistency fix: real, repeatable progress on the seed alone.
-- TODO(house-nav): the multi-level house->front-door->outside (tg 100) path is not yet
-- mapped (upstairs hall renders black headless; needs a captured hall state to see it).
-- qwen refines from the tg-75 start at realtime; the default guarantees the bedroom exit.
function update()
  if escapeMenu() then return end
  if mem.read(0x4DBA) ~= 0 then winBattle(); return end
  local px = mem.read(0x0BBE) + 256*mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256*mem.read(0x0BFB)
  if px >= 0x1F00 and px < 0x2000 and py <= 0x0600 then
    walkTo(0x1000, 0x0600)   -- bedroom: LEFT, out the door + down the stairs (verified -> tg 75)
  else
    walkTo(0x0700, 0x1B0F)   -- house interior: press toward the exit (front door is south/out)
  end
end
"""

  BattlePolicy* = """function update()
  winBattle()
end
"""

proc selectMockPolicy*(loadStateSlot: int): string =
  ## Key scenario to --load-state per strategist recommendation.
  ## slot1 (documented battle start) -> pure winBattle
  ## others (bedroom/house) -> nav + guarded winBattle
  if loadStateSlot == 1:
    BattlePolicy
  else:
    NavHousePolicy
