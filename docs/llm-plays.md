# LLM Plays EarthBound — a scripted agent harness

**Status:** base two-clock harness BUILT (`src/tools/llm_ai.nim` — LLM writes Lua,
qwen via azem, windowed + labeled state). The learning-agent **evolution** below
(skills + notes + pause-to-think) is designed, not built. Off the critical path;
sanctioned fun.

Give an LLM a way to *play* the game: it authors **Lua** that can read game
memory (read-only), see the screen, and press buttons — but never write game
memory and never escape to the host. The LLM watches the result and revises its
script. Music is out of scope for now (the agent plays deaf).

The nice part: the three capabilities the LLM needs already exist in the
emulator loop. This is mostly a **sandbox + a scripting bridge**, not new
emulation.

- **Read memory** — WRAM is a flat array (`snes.bus.mem[0x7E0000 + addr]`),
  SRAM is `snes.sram[...]`. A read-only accessor is a one-liner.
- **See the screen** — `play.nim` already renders `frameImage` (a pixie
  `Image`) every loop. Expose its pixels to Lua, or dump a PNG for the LLM.
- **Press buttons** — `play.nim` synthesizes the joypad each frame and sets
  `snes.joy1`. A Lua `pad.press("A")` just ORs bits into that same byte.

## Why Lua, and why it's the right shape

The instinct might be "just have the LLM emit button presses each frame." That
doesn't work: an LLM API call *per frame* (60/s) is infeasible on latency and
cost. The winning shape is a **two-clock design**:

- **Fast loop (Lua, every frame, no LLM):** the LLM-authored script *is the
  policy*. It runs at emulator speed with the sandboxed read+input API and
  makes moment-to-moment decisions ("hold Right until `$xx` changes, then press
  A"). No network, no LLM, runs as fast as the emulator.
- **Slow loop (LLM, occasional):** every N frames (or when the script signals
  "stuck"), the harness sends the LLM a screenshot + a named memory readout +
  the current script + any error, and the LLM **rewrites or patches the Lua
  policy**, which hot-reloads. "LLM writes the bot, bot plays, LLM revises the
  bot" — cost-feasible and genuinely emergent.

Lua is the right substrate for this because (a) it's a natural sandbox — the API
surface *is* the security boundary, (b) emulator-scripting-in-Lua (BizHawk,
mGBA, FCEUX) is deep prior art the LLM already knows, and (c) there is a proven,
minimal Nim↔Lua embedding *technique* to copy (see below).

**Target: Lua 5.3, embedded in-process, self-contained in this repo.** This
harness lives entirely inside decompbound — it does not depend on or reuse any
other project. (5.3, not 5.4, purely as the house version preference; nothing
we need here differs between them — both have the integer subtype + `<< >> & |
~` bitwise ops that make memory masking clean.)

A trivial **direct mode** (Lua policy that just applies buttons the LLM handed
it that turn) falls out for free — useful for bootstrapping and debugging
before the full authored-policy loop exists.

## Embedding Lua: reuse the noulith pattern

The Nim↔Lua embedding *technique* to copy (not the code, not the version) is the
one in `~/Documents/Projects/Racha/noulith`: add the official Lua source as a
**git submodule** (`https://github.com/lua/lua.git`), build a static
`liblua.a`, and bind it with a hand-rolled ~53-line FFI
(`{.passL: "lua/liblua.a".}`). noulith's submodule currently checks out a **5.4**
tree; for our target we pin the same submodule to the **`v5.3`** branch. The
mechanism is identical — only the branch differs.

**Link statically** (`liblua.a`), not a shared `.so`. Rationale: the
[Raspberry Pi goal](raspberry-pi.md) wants a self-contained binary we can drop
onto a Pi game box without matching a system `liblua` on the target — static
Lua is cheap insurance for that, and it's exactly the case noulith's static
embed was built for. (Shared-lib via `pkgs.lua5_3` + `--passL:-llua5.3` is the
easy alternative if we ever decide the Pi target is dead; for a dev-shell-only
tool it'd be less setup. But with the Pi on the table, static wins.)

**The one real gap:** noulith's FFI only binds `newstate` / `openlibs` /
`loadbuffer` / `pcall` — enough to *run* a fire-and-forget script, not enough to
expose an API back to it or read results. We need to extend it with:

- **Register Nim callbacks** as Lua functions (`lua_pushcclosure` /
  `lua_register` / `luaL_setfuncs`) — this is how `mem.read8` etc. reach Nim.
- **Marshal values** — push args (`pushinteger`/`pushstring`/`pushboolean`) and
  read results (`tointegerx`/`tolstring`/`toboolean`/`type`), plus stack
  management (`gettop`/`settop`/`pushvalue`).
- **A debug hook** (`sethook` with a count mask) to interrupt a runaway script
  after N instructions, so an LLM-authored infinite loop can't hang the
  emulator.

Alternatives considered and rejected: **LuaJIT** (faster + FFI, but 5.1
semantics and a heavier build — the FFI would also *weaken* the sandbox);
**nim-lang/lua** (only 5.0–5.2, deprecated, needs Nim 1.2). The proven
static-`liblua.a` embed technique wins; we just point it at a Lua 5.3 tree.

## The sandbox (this is the load-bearing part)

"Read but not write memory" and "can't touch the host" are both enforced the
same way: **the LLM's script can only do what we bind.**

1. **No write binding, ever.** We simply never register a memory-write
   function. There is no `mem.write` in the API, so the script cannot alter game
   state — read + input only, by construction.
2. **Reads are WRAM/SRAM only — not live MMIO.** Reading some MMIO registers has
   *side effects* on real hardware and in our bus (e.g. reading `$2139/$213A`
   increments the VRAM address; reading `$4210` RDNMI clears the NMI flag). So
   the read API serves WRAM (`$7E:0000–$7F:FFFF`) and SRAM only — pure,
   repeatable, side-effect-free. This keeps "read" honest.
3. **Sandbox Lua itself.** Do **not** `openlibs()` wholesale — that opens `os`,
   `io`, `package`, `require`, `loadfile`, `dofile`, giving the script the host
   filesystem, network, and arbitrary code loading. Open only `base` + `math` +
   `string` + `table`, and nil out anything dangerous that base pulls in
   (`dofile`, `loadfile`, `load` of files). The LLM-authored script is untrusted
   input; treat it like one.
4. **Bounded CPU time** via the debug hook above (item 3 in the FFI list).

## The Lua API (sketch, read + input only)

```lua
-- called by the harness every frame; the LLM authors this
function on_frame(ctx)
  local hp = mem.read16(0x...)         -- WRAM/SRAM only, side-effect-free
  if hp < 20 then
    pad.press("A")                     -- ORs into joy1 for the next frame
  else
    pad.hold("Right", 4)               -- hold Right for 4 frames
  end
end

-- exposed to the script:
--   mem.read8(addr) / mem.read16(addr)   -- WRAM ($7E-$7F) + SRAM, read-only
--   screen.width / screen.height
--   screen.pixel(x, y) -> r, g, b         -- from frameImage
--   pad.press(btn) / pad.hold(btn, n)     -- btn: "A".."Y","L","R","Up".."Right","Start","Select"
--   frame() -> n                          -- current frame number
```

Named memory fields (HP/PP/money/EXP/party position…) come from the same map
`sram_info.nim` builds and the save-report app (`docs/apps.md`) widens — so the
readout the LLM sees is human-legible, not raw hex.

## Components

1. **Extend the Lua FFI** (reuse noulith's `lua54.nim`): register callbacks,
   marshal values, install the instruction-count debug hook.
2. **Sandboxed API bindings** in Nim: `mem` / `screen` / `pad` as above,
   read + input only, over the existing `snes.bus.mem` / `snes.sram` /
   `frameImage` / `snes.joy1`.
3. **Policy runner** in a `src/tools/llm_play.nim` loop: load the LLM's script
   once, call `on_frame` each frame, catch Lua errors and surface them (don't
   crash the emulator).
4. **LLM bridge:** at the decision cadence, dump `frameImage` to PNG + a named
   memory readout + the current script + last error, POST to an LLM (curly —
   the HTTP lib noulith already uses), receive a new/patched script, hot-reload
   it.
5. **Headless mode** (no window) so the agent can run fast and unattended, and
   so runs are reproducible.

## Definition of done

- [ ] An LLM-authored Lua script runs in a sandbox that **can** read WRAM/SRAM,
      read screen pixels, and press buttons, and **provably cannot** write game
      memory or reach the host (no `os`/`io`/`package`, no write binding).
- [ ] The emulator calls the policy each frame; a runaway/infinite-loop script
      is interrupted by the debug hook, not a hang.
- [ ] A full loop works end-to-end: the LLM observes (screenshot + memory
      readout), (re)writes the Lua policy, and the agent makes visible progress
      — e.g. walks Ness out of his room, or wins a Starman Jr. battle.
- [ ] Runs headless for unattended sessions.

## Evolution: an agent that learns (skills + notes + pause-to-think)

The design above is "the LLM rewrites *one* policy each tick" — and that base
harness is built (`src/tools/llm_ai.nim`). The next step is bigger: an agent that
**accumulates skills and knowledge across sessions** and grinds toward the ending
on its own. Leave it running; it plays, builds tools, takes notes, saves progress,
and picks up smarter each restart. Inspiration: the agent-with-tools shape
(coworlds / mettascope) — *technique only*, no shared code (this harness stays
self-contained, per the house rule).

### Two layers

**Layer 1 — Skills (Lua, deterministic, full-speed).** A persistent, growing
library of tested routines the agent builds: `walkTo(x, y)`, `talkTo(npc)`,
`navigateMenu(path)`, `winBattle()`, `useItem(name)`, `fleeEnemy()`. Each runs at
emulator speed over many frames and owns the *real-time* execution — including the
time-sensitive bits (rolling battle HP, enemy chase, timed inputs), because Lua
reacts per-frame with no LLM in the loop.

**Layer 2 — Strategy (the LLM, occasional).** Observe → plan → act, where "act" is
a **Lua chunk**. One uniform interface: a chunk may call a skill, *define a new
skill*, press a button one-off, or write a note. A one-off (`pad.press("A")`) is
just an inline chunk; a skill is a named function it registers and reuses. This is
the load-bearing idea — the tool library isn't fixed, the agent grows it.

### The persistent brain (survives restarts)

- **Skill library** — `skills.lua` (or a dir), loaded at boot: the agent's muscle
  memory.
- **Notes** — accumulated game knowledge, e.g. *"exit Talla Rama's maze → talk to
  the monkey → get the trout-flavored yogurt machine."* One fact per note with a
  topic key (retrievable; all-in-context until it grows, then embed + search).
- **SRAM** — the actual battery save (already built: `--save-srm`, isolated to
  `bin/states/llm_ai.srm`, never the user's real `.srm`).
- **Milestone save-states** — snapshot before something risky, roll back on
  failure. Exactly what the state-screenshot core (`docs/state-screenshots.md`)
  provides.

### The clock: pause-to-think

The unit of decision is a **skill, not a frame.** The agent picks a skill; the
skill runs at full emulator speed until it finishes or hits a decision point;
*then* control returns to the agent. So the honest, efficient model is
**pause-to-think**: run the game flat-out while a skill executes, and **pause the
emulation while the LLM plans the next action.**

For a *bot* (unlike a human spectator) pausing is legitimate — EarthBound's
real-time pressure only exists *during* an action (a chase, a battle), which a
skill owns end-to-end; between actions you're standing on the overworld deciding
where to go, and freezing there costs nothing. This sidesteps "the game runs for
10 s while the LLM thinks" entirely. Two run modes fall out:

- **Autonomous** — full-speed, headless, pause-to-think, persist everything, grind
  for hours.
- **Watch** — windowed + 60 fps, the LLM call async in the background so the
  emulation never freezes (for spectating).

### How it composes with the rest of the project

- **Reading the game** — the labeled state summary already exists (HP/PP, position,
  sector, in-battle, menu-open). The **text-decode track** (`docs/scripts.md`) can
  let the agent *read dialogue* — huge for an RPG: follow the story instead of
  guessing.
- **`walkTo` pathfinding** — needs walkability data we don't have yet. Ship a
  **reactive v1** (head toward target, detect "stuck," try around) — enough for open
  areas, no RE needed — and add real A* later once we RE the collision map (the
  trace tool can find it: watch what the game reads when Ness bumps a wall).
- **Anti-looping / honesty** — a **progress metric** from SRAM (party size, items,
  level, story flags, sectors seen). The agent sees whether an action advanced it;
  after K skills with no progress → "I'm stuck" → try something new / note it / roll
  back a save-state. Keeps an unattended run from spinning forever.

### Open decisions (defaults proposed; confirm before building)

1. **Clock** — pause-to-think for the bot (proposed); async/60 fps reserved for the
   watch mode.
2. **Action interface** — every agent action is a Lua chunk (proposed), vs
   structured tool-calls with Lua only inside skill bodies.
3. **Notes** — one-fact-per-file with topic keys (proposed, scales), vs a single
   growing `notes.md` (simpler).
4. **v1 target** — bedroom → first battle won (proposed): small enough to prove the
   full loop (skill-building + notes + progress), real enough to be exciting.

### Definition of done (evolved harness)

- [ ] The agent expresses actions as Lua chunks; can call, define, and reuse skills.
- [ ] Skill library + notes + SRAM persist across sessions and reload at boot.
- [ ] Pause-to-think autonomous mode runs headless for hours, unattended.
- [ ] A progress metric detects "stuck" and the agent recovers (new plan / rollback).
- [ ] v1: from a cold start with an empty brain, the agent reaches + wins its first
      battle, and the skills/notes it wrote survive a restart.
- [ ] North star: unattended, it makes real, measurable story progress across many
      sessions.

## Sibling: the LLM that *rewrites* the game

This harness makes an LLM *play* EarthBound. Its sibling, `docs/llm-remix.md`,
makes an LLM *rewrite* it (regenerate the writing, patch it in). They compose:
the playing agent can **playtest** the rewriting agent's remix — one LLM writes
the game, the other checks it doesn't break.

## Non-goals (for now)

- **Audio to the LLM** — the agent plays deaf; music/SFX are out of scope.
- **Write access to game memory** — never. Read + input only is the whole point.
- **A general emulator scripting console** — this is scoped to the LLM-agent
  use case, not a full BizHawk-style Lua environment (though the FFI work would
  make one easy later).

**Scope:** new `src/tools/llm_play.nim` + a reused/extended Lua FFI (noulith
pattern) + an LLM HTTP bridge. Off the critical path; parallel-safe with
everything in `docs/goal.md` and the other apps in `docs/apps.md`.
</content>
