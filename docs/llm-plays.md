# LLM Plays EarthBound — a scripted agent harness

**Status:** NOT STARTED. Design doc. Off the critical path; sanctioned fun.

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
