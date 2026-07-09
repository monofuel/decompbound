# LLM Plays EarthBound — a scripted agent harness

**Status:** two-clock harness BUILT and PLAYING (`src/tools/llm_ai.nim` — qwen
writes Lua, windowed + labeled state). Much of the learning-agent **evolution**
below is now built too: persistent skills (`walkTo`/`escapeMenu`/`winBattle`),
the notes brain, isolated SRAM, and the `tg_pct` milestone metric. **Async watch
mode** (`--watch-async`, default windowed) keeps the fast Lua loop stepping while
qwen thinks; `--sync-llm` (default headless) still pause-for-consistency.
See [Where it actually stands](#where-it-actually-stands--what-works-whats-next)
for the honest state of the code. Off the critical path; sanctioned fun.
Awareness of pre-training / seed / notes leakage: [llm-contamination.md](llm-contamination.md).  
**Campaign / story percents (tg → Pokey → knock → Buzz Buzz → Sunrise MVP):** [llm-sequence.md](llm-sequence.md).  
**n=1 touch grass (IRL):** [media/IMG_20260520_201351_568.jpg](media/IMG_20260520_201351_568.jpg).

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

## Milestone metric: "touch grass %" (tg_pct)

The first-milestone progress score for the agent: **get Ness out of his house**
("touch grass"). Computed by `touchGrassPercent` in `src/tools/touch_grass.nim`
from the player's live world position; fed to the LLM every slow tick as
`tg_pct` + `current_room`, logged to `bin/llm_ai_log.txt`, and printed as
`TOUCH GRASS ACHIEVED` at 100.

**Ground truth: the player is entity slot 24.** Entity world positions live in
parallel word arrays at `7E:0B8E + slot*2` (X) and `7E:0BCA + slot*2` (Y); the
party leader's render slot is **24** (X at `7E:0BBE`, Y at `7E:0BFA`), verified
by live instruction trace: the per-frame projection at `$C04E15/$C04E1D`
(`STA $0B8E,X / $0BCA,X`) runs with X=0x30 for the walking player; slot 28 is
the second party member. Slot 0 is just the first map NPC/object — reading it
(the original implementation) watched *furniture* that never moves, which
masqueraded for days as "movement is frozen headless". The game was fine.

Tiers (calibrated from `bin/states/*.state` captures + a live scripted
walk-out):

| tg_pct | meaning | captured player pos |
|---|---|---|
| 0 | title / naming / pre-game (zero or tiny pos) | (0,0) |
| 25 | Ness's bedroom (game start) | (1FB8,0452) |
| 75 | anywhere else inside the house (hall, stairs, living room) | e.g. (1DE8,03E8), (1D30,0150) |
| 50 | battle (box around 0580-0600 x 0900-09A0) or unknown | (05C3,0945) |
| 100 | outside — not indoor band, not battle box | (0A60,0158) Onett; (057F,1B0F) Twoson |

**Proven end-to-end** (2026-07-07, headless): a scripted waypoint walk from
`bin/states/game_start.state` drives 25 → 75 → 100 in ~13s of game time. The
verified route out (also seeded into `bin/states/llm_notes.txt` for the agent):
bedroom west door (walk to `1F00,0450`) → hall west (`1D40,03E8` then
`1CC0,03E8` = stairwell) → downstairs arrival `(1D30,0150)` → east across the
sitting room (`1E61,0178`) → the **east-wall front door** (`1E85,0150` →
`1EC0,0148`) → outside at `(~0A60,0158)`.

Gotchas the hard way:
- **A opens the command menu and freezes movement.** Don't spam A while
  walking; tap B to close an accidental menu.
- King the dog sleeps at `(~1D48,0178)` and body-blocks; route around him.
- Room transitions teleport the player (pos jumps > 0x80 in one frame).
- ~~**Known issue: force-blank after front door**~~ **FIXED 2026-07-08:** save-state
  v1 dropped APU timers; music driver hung on `$FD` so `$2140` never acked and
  `INIDISP` stayed `$80`. Cold-boot `make play` was fine; llm-ai load-state was
  not. Timers restored on load (v2 + v1 recovery).
- Known issue: loading a save-state captured mid-house resumes with a stale
  duplicate player object from an earlier room receiving d-pad input
  (object/slot identity vs save-state interaction; needs a dig).

## Where it actually stands — what works, what's next

The sections above are the vision + design; this is the honest state of the code
as of the last update. Keep this section current — it's the first thing to read.

### What works now

- **Two-clock loop** (`src/tools/llm_ai.nim`): a Lua `update()` drives `joy1`
  every frame; qwen (`qwen3.6-35b-a3b` via LM Studio on azem) rewrites the policy
  every `--llm-interval` frames and hot-reloads it.
- **Sandbox**: read-only `mem.read`, `screen.text()`, `pad`, `frame()`,
  `sim.setSpeed()` — no memory-write binding exists, and an instruction-count
  hook caps runaway scripts.
- **Persistent skills** (`bin/states/llm_skills.lua`, loaded before the policy):
  `walkTo(x, y)` (reactive, d-pad only, stuck-wiggle), `escapeMenu()` (B out of
  overworld menus), `winBattle()`. Seeded from `touch_grass.nim` on first run.
- **Persistent brain**: `bin/states/llm_notes.txt` (parsed `-- NOTE:` lines,
  reloaded into every prompt) + isolated `--save-srm` battery save (never the
  user's real `.srm`).
- **Milestone metric**: `tg_pct` (see the section above) — 25 → 75 → 100 proven
  end-to-end with a scripted walk. Next story gates (Pokey → knock → Buzz Buzz →
  Sunrise MVP): [llm-sequence.md](llm-sequence.md).
- **Menu-blindness fix** (commit `8865a94`): rich state reports
  `menu_open`/`which_menu`; the prompt + skills forbid pressing A while walking
  (A opens the command ring and freezes movement — the single biggest thing that
  used to strand qwen in the bedroom).
- **Watch mode**: `make llm-ai` runs windowed at `--speed 60` with
  `--watch-async`, loading **`bin/states/llm/bedroom.state`** only (never human
  `slot1–4`). Deterministic seed policy walks bedroom→outside (tg 25→100);
  qwen may refine. Always-on display: `make llm-ai-display` (long frame cap;
  wrap in a shell loop to restart).

### SPEED: async watch mode (shipped)

The two-clock design's promise is that the **fast Lua loop runs at emulator
speed** and the LLM is only *occasional*. That is now the default for windowed
runs.

**What shipped** (`src/tools/llm_ai.nim`):

- **Worker thread + channels** — provider call (HTTP or mock) runs off the main
  thread; main owns Lua + SNES only. `pollAndApplyResult` every frame hot-swaps
  the policy string when the result lands.
- **`--watch-async`** (default when **not** `--headless`): while LLM is
  in-flight, keep stepping frames with the *current* policy at `--speed` pacing;
  no freeze. Title bar shows `thinking (async)`. End-of-run log prints
  `frames_during_pending=N` (must be >0 under async).
- **`--sync-llm` / `--pause-llm`** (default when `--headless`): pause frame
  advance until the response applies — deterministic apply-at-snapshot for
  milestone / CI runs that need the policy to land on the state it was computed
  for.
- **`--verbose` / `-v`**: full multi-KB prompt + request JSON dump. Quiet by
  default (one-line `LLM_REQUEST: chars=...` only).

**Consistency tradeoff:** async means the policy may apply several seconds (and
many frames) after the summary snapshot it was written for — fine for watching,
less ideal for repeatable headless milestone runs. Use `--sync-llm` when you need
the old pause-for-consistency behavior.

### House decoration / always-on play

Goal: one (or more) window(s) on a spare display where qwen hammering EarthBound
is ambient furniture. Practical recipe:

1. Azem LM Studio with `qwen3.6-27b@q6_k` (or whatever `PolicyModel` is).
2. `make llm-ai-display` — windowed, 60 fps, async think, LLM bedroom fixture.
3. Always-on restart loop (preferred): `make llm-ai-display-loop` →
   `scripts/llm_display_loop.sh` restarts forever, logs `bin/llm_display.log`,
   echoes last `max_touch_grass` between restarts. Dry-run:
   `make llm-ai-display-loop DRY_RUN=1`.
4. Optional second instance: another terminal / another machine with a different
   `--load-state-path` under `bin/states/llm/` (never share human play slots).

State hygiene: all LLM savestates under `bin/states/llm/`; your `make play`
Ctrl+1–4 slots stay personal. Seed `NavHousePolicy` is pure waypoints (no battle
focus) — battle is a separate fixture track. Empty/broken qwen Lua keeps the
prior working policy (`pollAndApplyResult` + provider `return currentLua`).
After tg 100 the seed auto-switches to `ExploreOnettPolicy` (street walk cycle)
so the window does not idle at the door.

**Verify async path (mock, no key):**
```

nim r src/tools/llm_ai.nim -- --mock --headless --frames 80 --llm-interval 20 \
  --speed 0 --watch-async
```
Expect exit 0 and `frames_during_pending=` greater than 0.

**Still useful knobs:** raise `--llm-interval` so qwen is queried less often;
keep `--speed 60` for watch, `0` for headless grind.

### Milestone reports (proposed)

Rather than a single opaque `tg_pct` number scrolling past, have the harness emit
a short **report each time the agent crosses a milestone** — e.g. *exit Ness's
room* (25 → 75), *walk down the hallway / reach the downstairs*, *step outside*
(→ 100). Each report captures:

- the milestone name + the frame and wall-clock it was reached (or "not reached");
- the `tg_pct` transition and the player pos at the crossing;
- the policy Lua that achieved it, and any `-- NOTE:` the agent wrote that tick;
- **the git commit hash** (`git rev-parse --short HEAD`) so every report is pinned
  to the exact harness + metric code that produced it.

Recording the commit hash is the load-bearing part: it makes runs **comparable
across commits** — "did the menu-fix commit actually make *step outside*
reachable?" becomes a diff of two reports, not a memory. Write them under
`bin/llm_reports/<milestone>_<commit>.md` (gitignored, like the other run
artifacts). This turns a run from a wall of stdout into a diffable record and
makes "is the agent getting better?" an answerable question.

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
