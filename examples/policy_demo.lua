-- examples/policy_demo.lua
-- Milestone 2b hand-written demo policy (not LLM generated).
-- Drives the game visibly: holds Right for first ~120 frames (even/odd toggles
-- to prove set works), then releases and occasionally presses A.
-- The runner logs when joy1 carries the Right bit to prove plumbing.
-- update() is called by llm_play every emulated frame.

function update()
  local f = frame()
  print("policy: frame=" .. tostring(f))

  if f < 120 then
    -- toggle on even frames to exercise pad.set(bool)
    if f % 2 == 0 then
      pad.set("Right", true)
    else
      pad.set("Right", false)
    end
  else
    pad.set("Right", false)
    if (f % 4) == 0 then
      pad.press("A")
    end
  end
end
