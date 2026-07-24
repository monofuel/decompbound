# decompbound MCP server (Goal 5)

Playthrough **co-pilot**: an LLM in chat can ask about *your* current EarthBound
save. This is **not** Goal 4 (LLM *plays* the game via Lua).

Built on [MCPort](https://github.com/monofuel/MCPort) (same stack as the FFXIV
MCP tool). Strictly **read-only** — no joypad control, no WRAM writes.

## Run

From the repo root:

```bash
make mcp
# or: nim r src/tools/decompbound_mcp.nim
# stdio transport: nim r src/tools/decompbound_mcp.nim --stdio
```

HTTP endpoint: `http://localhost:4343/mcp` (port **4343** so it does not clash
with FFXIV MCP on 4242).

Default battery path: `bin/Earthbound (U) [!].srm`. Override with env
`DECOMPBOUND_SRM` or the tool argument `srm_path`.

Register in a client as an HTTP MCP server pointing at that URL (or launch the
stdio binary). Save in-game so the `.srm` is fresh before asking about HP/PP.

## Tools (MVP)

| Tool | What |
|------|------|
| `get_party_vitals` | Names, levels, current/max HP and PP from the active battery-save slot |

Source: offsets in `docs/sram-format.md` / `src/decompbound/party_sram.nim`.
This is **battery SRAM**, not live mid-battle WRAM — save the game for
up-to-date numbers.

## Roadmap (same product)

- Live snapshot while `make play` is running (or last F12 / slot state)
- Inventory, status ailments, money/ATM
- ROM-derived item/PSI lookup tables for grounded advice
  (“what heals sunstroke”, “where rock candy can come from *given this bag*”)

## Copyright

Do not commit `.srm`, save-states, or F12 PNGs. The MCP process reads them
locally only.
