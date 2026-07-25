# Leveling & EXP

How experience, level-ups, and stat growth work.

## EXP tables — level cap is 99

✅ **decomp-verified:** per-character EXP-requirement tables at file `0x158F51`
(SNES `$D58F51`), u32 little-endian per level, **99 entries per character**,
four characters back-to-back (Ness, Paula, Jeff, Poo). Verified byte-exact
(`docs/decompilation.md`). The final table ends at `0x159587`, immediately
before the stat-growth records at `0x159589` — there is no level-100 entry.

Sample (Ness, from the ROM): L2=4, L3=17, L4=44, L5=109 … the curve steepens
to ~8.2M for the top levels; the last character's table tops out at 9,993,637.

"EXP to next level" = `table[level] − current EXP`. Current EXP is a u32 at
character-record offset `+$06` (✅ exposed live via `get_party_vitals`).

## The level-up routine

✅ **decomp-verified (control flow):** the stat-gain code around `$C032EC`
(file `0x32EC`):

1. Looks up the character's level in the **selector table at `0x158F23`**
   (leading zeros, then `01 a1 01 a2 …`) which maps level → growth block.
2. Indexes the **growth records at `0x159589`**: `0x5E`-byte records, offset
   computed as `block × 0x5E + const` via the 8×16 hardware-multiply helper
   `$C08FF7` ([[../snes-asm]] `hw_multiply.nim`).
3. Field-select constants `0x1C / 0x21 / 0x29 / 0x3C` pick HP/PP-target vs
   stat-gain fields inside the record.

🟡 **remaining detail:** the exact per-field/per-character byte layout inside
the `0x5E` record (mixed u16/u8) is not fully mapped — last open item in
`docs/decompilation.md`. Consequently we can't yet *predict* a specific
level-up's stat gains from ROM data alone.

Stat gains are applied with 8-bit arithmetic — see [[stats]] for the 255
rollover this implies.

## HP / PP

HP-max and PP-max are u16 targets computed at level-up from vitality/IQ via
the growth record (the `$C08FF7` multiply above). Current/rolling HP-PP live
elsewhere in the record (`+$45` rolling, `+$47` current — the famous rolling
HP meter). 🟡 The exact target formula (vit×k? table lookup?) is not yet
pinned — needs the record layout above.

## Related

- [[stats]] — storage width and rollover.
- [[known-bugs]] — EXP underflow on simultaneous defeat (community).
- `docs/decompilation.md` — offsets, verification status, open items.
- `docs/bestiary.md` — enemy EXP yields (u32 at enemy-record `+0x04`).
