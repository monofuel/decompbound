# Character stats

The seven stats, how they're stored, and why 255 is a cliff edge.

## The seven stats

Offense, Defense, Speed, Guts, Luck, Vitality, IQ. Each character carries two
copies in the `$5F`-byte character record (WRAM `$99CE` + `$5F`×char; same
layout persisted to SRAM — see `docs/sram-format.md`):

| Record offset | What | Status |
|---------------|------|--------|
| `+$15..$1B` | OFF/DEF/SPD/GUT/LUC/VIT/IQ **with equipment** (status-screen numbers) | ✅ parsed live by `party_wram.nim`, values match status screen on a real save |
| `+$1C..$22` | Same seven, **base** (no equipment) | ✅ same |

Derived stats HP-max/PP-max are separate **u16** fields (`+$0A` / `+$0C`), so
they do *not* share the byte-width cliff below — the storage ceiling is 65535.

🟡 **community (monofuel, 2026-07-24):** HP/PP **can exceed 999 and keep
working** — the battle/status UI only renders three digits so the display
glitches, but the underlying value is honored in combat. Consistent with the
u16 storage; the 999 "cap" is a *display* convention, not a stored clamp.
**TODO:** verify on our emulator (boost past 999, screenshot the UI glitch,
confirm damage/PSI math uses the real value) — would double as a rendering
accuracy test.

## Every stat is one unsigned byte — the 255 rollover

✅ **decomp-verified (storage + arithmetic width):**

- Storage: each stat is a single `u8` in the character record. There is no
  high byte anywhere in the record layout.
- Arithmetic: the level-up stat routine at `$C032EC` (file `0x32EC`) runs the
  stat path with an 8-bit accumulator (`SEP #$20`) and masks reads with
  `AND #$00FF`. 256 is unrepresentable; any uncapped add wraps mod 256
  (e.g. 250 + 10 → 4).

Consequences:

- A stat pushed past 255 **rolls over to near zero** — a maxed-offense
  character suddenly does scratch damage.
- Equipment adds into the same u8: base 202 + a +54 weapon wraps the
  *equipped* value even though base looks safe. Watch the **equipped** number.

✅ **live-observed (2026-07-24):** in-battle stat-boost items write to the
**equipped** block (`+$15`) — during a live rock-candy session the equipped
stats rose while the base block (`+$1C`) stayed untouched (watched via the
MCP live-WRAM feed between fights). So the rollover budget for boosting is
`255 − equipped`, and future equipment *changes* shift the danger line.

🟡 **community (not yet traced by us):** whether the *item/condiment boost*
routine lacks a clamp (`CMP`/`BCS` guard) before adding. Community consensus
(WikiBound, SDA) is there is no clamp on the SNES original — that's what makes
the rock-candy overflow possible ([[known-bugs]]) — and that it was fixed in
the GBA port. Enemies reportedly also lack the cap in places.
**TODO:** trace the in-battle stat-boost item routine and promote this to ✅.

## Level-ups can't reach the cliff on their own

Stat *growth* per level comes from the per-character growth records at file
`0x159589` (selector table `0x158F23` maps level → block) — see
[[leveling]]. Natural 1–99 growth lands well under 255; only repeated item
boosts (rock candy et al.) approach the rollover.

## Live monitoring

`get_party_vitals` (MCP, `docs/mcp-server.md`) returns `stats` (equipped) and
`statsBase` per member from live WRAM. Distance-to-rollover for any stat is
just `255 - stats.<field>` — the co-pilot can warn during a rock-candy
grinding session.

## Related

- [[leveling]] — where stat gains come from.
- [[known-bugs]] — the condiment/rock-candy glitch that makes overflow reachable.
- `docs/sram-format.md` — full character-record byte map.
