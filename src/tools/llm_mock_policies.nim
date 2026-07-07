## Pure mock policy strings for llm_ai verification scenarios.
## Separated so nav and battle paths can be selected independently without
## polluting the main harness or requiring ad-hoc drivers.

const
  NavHousePolicy* = """-- NOTE: (mock) escapeMenu+walkTo+winBattle preloaded; A opens menus, B cancels; walk d-pad ONLY; winBattle on in_battle
function update()
  if escapeMenu() then return end
  if mem.read(0x4DBA) ~= 0 then winBattle(); return end
  -- Stable target for the whole nav: the front door area. walkTo is reactive and will head the dominant direction.
  -- Combined with walkTo's room-jump reset and the high-level regression boost + immediate safe policy on rollback,
  -- this prevents getting trapped re-targeting bedroom after crossing.
  -- LLM policies should do similar: pick door target once you see house pos.
  walkTo(0x1EC0, 0x0150)
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
