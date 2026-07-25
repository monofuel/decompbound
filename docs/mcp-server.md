# decompbound MCP server (Goal 5)

Playthrough **co-pilot**: an LLM in chat can ask about *your* current EarthBound
run. This is **not** Goal 4 (LLM *plays* the game via Lua).

Built on [MCPort](https://github.com/monofuel/MCPort) (same stack as the FFXIV
MCP tool). Strictly **read-only** — no joypad control, no WRAM writes.

## Two modes

| Mode | When | Source | How |
|------|------|--------|-----|
| **In-process (live)** | `make play` is running | Live WRAM party stats | HTTP MCP starts *inside* the player on `localhost:4343` |
| **Standalone (offline)** | Game closed | Last battery save (`.srm`) | `make mcp` / `src/tools/decompbound_mcp.nim` |

Same tool name (`get_party_vitals`), same port default (**4343** — avoids FFXIV
MCP on 4242). Clients register one HTTP MCP URL; while you play, answers are
live; when the game is closed, start the standalone server to query the last
phone/save-file battery image.

### In-process (live) — preferred while playing

`play.nim` starts the MCP HTTP server at launch (Mummy on its own threads).
Once per emulated frame the main loop copies a small party-vitals snapshot into
a lock-guarded in-memory struct; MCP handlers read **only** that snapshot
(never raw emulator arrays off-thread). No disk handoff, no separate process.

```bash
make play
# startup line:
#   decompbound MCP on http://localhost:4343/mcp  (live WRAM, in-process)
```

If port 4343 is already taken, play logs one warning and continues **without**
MCP (the game never crashes over the co-pilot).

`get_party_vitals` returns `source: "live-wram"` plus `frameCount`.

### Standalone (offline fallback)

When the game is not running:

```bash
make mcp
# or: nim r src/tools/decompbound_mcp.nim
# stdio transport: nim r src/tools/decompbound_mcp.nim --stdio
```

HTTP endpoint: `http://localhost:4343/mcp`.

Default battery path: `bin/Earthbound (U) [!].srm`. Override with env
`DECOMPBOUND_SRM` or the tool argument `srm_path`.

`get_party_vitals` returns `source: "battery_sram"` — last in-game save only
(SRAM updates on phone save, not mid-fight). Save in-game so the `.srm` is
fresh before asking about HP/PP.

## Tools (MVP)

| Tool | What |
|------|------|
| `get_party_vitals` | Names, levels, EXP, current/max HP and PP, full stat blocks (offense/defense/speed/guts/luck/vitality/IQ — `stats` with equipment, `statsBase` without), and per-character `inventory` (14 slots; occupied slots with item id + ROM-decoded name + equipped flag) |

Item names decode at runtime from the ROM item table (`$D55000`, `0x27`-byte
records — `src/decompbound/item_table.nim`); no copyrighted strings in source.

**Live path:** overworld WRAM character table at `$99CE` (stride `$5F`, same
layout as the battery char table). See `src/decompbound/party_wram.nim` and
`docs/sram-format.md`. Persist-block base `$97F5` maps slot data (`+$20`) so
roster `$988B` / money `$9831` / char0 `$99CE` line up with the `.srm` slot.

**Standalone path:** active battery slot via `src/decompbound/party_sram.nim`.

**In-battle live HP** via battler ptr table `$4DC8` is a follow-up (overworld
live stats are what ship today).

## Threading (live mode)

| Thread | Role |
|--------|------|
| Main (play frame loop) | Emulation; `publishLiveParty` → lock, copy report, unlock |
| Mummy worker(s) | HTTP + tool handlers; `copyLiveParty` only |

Lock hold time is a small struct/seq copy. No input/RNG consumption on the MCP
path — replays stay deterministic.

## Roadmap (same product)

- In-battle HP/PP via `$4DC8` battler structs
- Status ailments, money/ATM, Escargo Express storage
- ROM-derived item/PSI lookup tables for grounded advice
  (“what heals sunstroke”, “where rock candy can come from *given this bag*”)

## Copyright

Do not commit `.srm`, save-states, or F12 PNGs. The MCP process reads them
locally only (standalone); live mode never writes party data to disk.
