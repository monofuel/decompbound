# EarthBound PRNG — the reference

The single home for RNG knowledge: routine, seed, oracle, advancement
schedule, and manipulation mechanics. Drop-roll specifics and the Sword of
Kings campaign live in [sword-of-kings.md](sword-of-kings.md); this doc is
the general mechanism. Started 2026-07-27 after live F8-HUD play produced
major advancement discoveries.

## Generator and verified calling contract

The routine at SNES `$C08E9A`, file `0x008E9A`, occupies 56 bytes. Its
annotated source is [earthboundRandom.asm](../asm/earthboundRandom.asm);
[rng_oracle.nim](../src/decompbound/rng_oracle.nim) implements the same arithmetic
as `advanceSeed(seed) -> (value, seed)`.

The game stores the little-endian seed in WRAM `$0024`–`$0027`, initialized
at `$C08121` to `$56781234`. A call updates the seed and returns a byte in A.
The native-mode contract requires **decimal arithmetic disabled** and a data
bank mapping absolute `$0024`/`$0026` to the intended WRAM. Input accumulator
and index widths may vary. PHP/PLP restore processor status; X/Y, DBR, direct
page, and the caller's stack depth are preserved. The routine does not clear
the decimal flag itself, so restoring flags does not mean its result is
independent of them.

Write the seed as two 16-bit words `lo` and `hi`. In binary arithmetic:

1. Multiply the low byte of `hi` by the low byte of `lo` using the SNES
   unsigned 8×8 multiplier.
2. Form `(lowByte(lo) << 8) | lowByte(hi)`, add `$006D`, and store the low
   16 bits as the new `hi`. This is **not** simply `oldHi + $006D`.
3. Rotate the product right twice through carry, starting with the carry from
   that addition. Keep the rotated product for the return-value calculation.
4. Add its low two bits to the old `lo`; rotate that sum right through the
   addition's carry. If the rotation shifts out a one, force bit 15 on. Store
   this as the new `lo`.
5. Rotate the saved product right twice more, starting with the carry left by
   the sum rotation. Return its low byte.

The bit rotations are 65816 rotate-through-carry operations. The sum's carry
and shifted-out bit affect the new low seed word. For the return value, carry
bits inserted at the top are discarded by the final byte mask: it simplifies
to `(product >> 4) & 255`, the product's bits 4 through 11. The integration
test also checks this independent expression. Same seed and call sequence
give the same results; input timing can change which calls occur before a
game decision.

## Verification

`nim r tests/integration_rng.nim` assembles the annotated routine and compares
it with the original ROM. It then calls the **ROM routine** through the CPU and
SNES multiplier using synthetic WRAM seeds:

- All 65,536 combinations of the multiplier input bytes.
- Ten boundary values for each seed word, across all 128 processor-status
  combinations with decimal clear: 12,800 additional calls.
- A decimal-mode counterexample, checking that the binary oracle contract
  does not accidentally get generalized to decimal arithmetic.

Each binary call compares both updated seed and full A against the oracle,
checks return/stack behavior, and checks preserved registers/status. This is
78,336 binary-mode calls, not exhaustive coverage of all 32-bit seeds. The test
requires the user's ROM and fails if it is missing; it needs no save-state.

`nim r tests/e2e_rng_oracle.nim` separately checks at least 50 calls encountered
while running the game, preferring a local state or otherwise cold booting.
That existing test skips when its default ROM is absent, so inspect the output
before treating a zero exit status as evidence. Both checks passed on 2026-09-10.

## Advancement schedule

Advancement depends on executed game code, not a universal draws-per-frame rule.
The measurements below are from the documented Stonehenge/menu experiments;
they are not guarantees for every place, party, or window configuration.

### Menu contexts measured by probe_rng_reconcile

Earlier probe and live observations differed because menu type and window
focus differed. In these measured contexts the RNG call is reached through
`$C12DD5`; the recorded stack parent identifies the consumer. This does not
prove every path through that service routine consumes exactly one draw:

| Menu context | Action | Advances | L1 parent | Period |
|---|---|---:|---|---|
| Free overworld | idle | 0 | — | — |
| **B-status window (type 0x0A)** | dwell | **1/frame** | `$C13CB4` input-wait loop | 1f — THE spinner |
| Pure command menu (`$8654=FF`) | dwell / cursor | 0 / 0 | — | dwell-safe |
| A-cmd menu + side window (`$8654=00`) | open | 2 | `$C11B29` | — |
| A-cmd + side window | dwell | 1 per **62f** | `$C11B29` blink/redraw | the "≥1/s" tick |
| A-cmd + side window | cursor nav | +1/input | `$C11B29` | — |
| Status screen once focused | dwell | 0 | — | dwell-safe |

The B-window "spinner" is the `$C13CB1` wait loop calling `$C12DD5`
unconditionally every iteration while it polls for a face button. That service
routine makes an unconditional direct RNG call before checking its other work. The old "close B = 64" was this same
free-run measured for 64 frames of window-wait, not a distinct cost.

### Other historical measurements

`probe_rng_advances.nim` also recorded the following in its specific
overworld and battle states on 2026-07-27. These results have not been
re-measured in this consolidation and are not universal action costs.

| Context/action | Measured advances | Attribution |
|---|---:|---|
| Walking for 60 frames | 0–1 | `$C02823`, direction/context dependent |
| Dialogue visible for 60 frames | About 50 | Return site `$C12DDB` |
| Battle command menu dwell | 0 | Observed battle-menu context |
| Battle cursor input over 60 frames | 5 | Return site `$C12DDB` |
| Battle attack window over 180 frames | 101–131 | Mixed callers |

## The manipulation interface (the big one)

The live discoveries combine into a complete human seed-dialing console:

- **Coarse spin:** open the stat menu with B → the seed free-runs at
  ~60 advances/second. Hold to fast-forward through seed space; close to
  stop. Effectively a re-roll/randomize lever when you're in a bad seed
  neighborhood.
- **Fine step:** menu navigation = exactly +1 per input; A-toggle = +1
  per press. Step to an exact target seed.
- **Read-out:** F8 HUD shows the live seed hex + advance counter.
- **Park:** overworld idle = 0 — the seed holds still while you think
  (menus closed).

With a target seed from the recipe tooling ("get the seed to X, then
execute the fixed kill script"), the human procedure is: spin close with
the B-stat menu, fine-step with navigation, confirm on the HUD, go.

Caveat for recipes: the ≥1/s menu-open tick means fine-stepping should
be done briskly or with menus closed between steps. Use the measured window
context above; verify a new context before assuming its dwell rate.

## Drop rolls (summary — details in sword-of-kings.md)

- Enemy table `$D59589`, stride `0x5E`; drop freq enum `+0x57` (0=1/128,
  1..6 = 1/64..1/2 via masks `$7F..$01`, ≥7 = always), drop item `+0x58`.
- Roll = `JSL $C08E9A` + `AND #mask`, success only on 0. Sites `$C24DDC`
  and `$C264B1`.
- **TIMING SETTLED — the roll fires at BATTLE START (✅ dynamic,
  2026-07-27):** from monofuel's overworld capture next to a Starman
  (slot230), walking into the enemy executed battle-init `$C2B6FA` at
  frame 190 and **`$C24DDC` two frames later** — no victory, no fight.
  Result stored in `$AA10` at init (0 = the 127/128 miss). Community
  knowledge + monofuel's memory were RIGHT; the static caller-chain read
  ("victory path") was wrong — dynamic PC-watch beats static walks in
  this fragmented bank. Jeff's Spy mid-battle steal now fully coheres:
  it grants `$AA10` when the init roll succeeded ("if they have it").
- **Headless battle entry WORKS via overworld bump** (this path does not
  hit the phase-3 abort that blocks other entry attempts) — full
  engage→roll pipelines are now automatable from overworld F12s.
- Recipe anchor: the PRE-BATTLE overworld seed. Manipulation console
  (spinner + fine-step above) dials the seed; the bump triggers the
  roll ~2 frames into init. Engage-check-flee loop viable: read `$AA10`
  (or overlay announce) after the swirl; 0 → flee and re-dial.

## Tooling index

| Tool | What |
|------|------|
| `src/decompbound/rng_oracle.nim` | pure `advanceSeed` |
| `src/probes/probe_rng_advances.nim` | action→advances measurement |
| `src/probes/probe_drop_table.nim` | enemy drop table dump |
| `src/probes/probe_spy_roll.nim` | Spy semantics referee |
| F8 HUD (play) | live seed/advances/EXP/formation |
| `tests/integration_rng.nim` | assembly identity and synthetic-seed CPU differential checks |
| `tests/e2e_rng_oracle.nim` | observed calls during game execution |

## Service routine frontier: `$C12DD5`

Static inspection on 2026-09-10 established a 109-byte routine spanning file
`[0x012DD5, 0x012E42)`. It forces 16-bit registers, calls the generator at
`$C12DD7`, then replaces A with service state. It is not a random-byte-return
wrapper. Its early exits test bytes at DBR:`$968C` (clear then exit) and
DBR:`$9622` (exit without clearing). The longer path tests further state and
calls several services before returning with a 16-bit accumulator.

The input loop at `$C13CB1` calls it, reads `$006D`, and tests button masks
`$00A0` and `$A000`; the latter zero result loops back. The blink/window path
also calls it at `$C11B26`. These call sites explain why menus can advance RNG
without making an explicit random choice.

Reproduce the static inspection using our disassembler:

```sh
nim r src/tools/disasm.nim 'bin/Earthbound (U) [!].smc' 0x12DD5 8
nim r src/tools/disasm.nim 'bin/Earthbound (U) [!].smc' 0x12DEA 12
nim r src/tools/disasm.nim 'bin/Earthbound (U) [!].smc' 0x13CA1 22
```

Restart at `$C12DEA` in 16-bit mode: linear disassembly otherwise inherits the
8-bit mode from an early-exit branch that does not reach that address.

**Next question:** trace the longer service path for additional RNG consumers
and establish the higher-level record lifecycle that sets these flags. Do not
adopt this routine as fully explained until its state and callee contracts are
known. The historical 59-call-site count came from retired generated banks;
it is not a freshly verified complete inventory of callers.

### Early-exit flags and adopted setters

The persistent gate byte at `$7E9622` suppresses work **after** the RNG draw.
[clearServiceSuppression.asm](../asm/clearServiceSuppression.asm) at `$C3E4CA`
clears that byte; [setServiceSuppression.asm](../asm/setServiceSuppression.asm)
at `$C3E4D4` writes one. They occupy 10 and 12 bytes respectively and are now
reproduced from annotated source. Both require native mode and the intended
WRAM data bank; both return with 16-bit registers and carry clear. The setter
changes only A's low byte to one, retaining its high byte. Neither touches the
adjacent `$9623` byte.

The caller at `$C3E4E0` clears suppression, invokes `$C12DD5`, then sets
suppression again. That enables one service invocation, but does not guarantee
that invocation takes its long path: the independent `$968C` gate can still
skip it. The flag names describe their tested effect in this service, not a
complete explanation of every consumer elsewhere in the game.

`$968C` is a one-shot gate: nonzero skips service work and is cleared. One
confirmed writer is `$C11672`. Its enclosing path first rejects `$8958 == $FFFF`,
then selects a record via
`$8650 + $52 * word[$88E4 + 2 * word[$8958]]`; when the record's word at
`+$2B` is `$FFFF`, it writes `$FF` to `$968C`. The other branch calls the
persistent setter at `$C11685`. The record-field meaning remains unresolved;
this evidence does not justify naming the flag "window closed".

`nim r tests/integration_rng_service.nim` exercises all 65,536 pairs of gate
bytes against the original ROM with synthetic WRAM and DBR `$7E`. It verifies
one RNG draw before either early exit, byte clearing/preservation, and entry
into the longer path when both are zero. It stops at that path's entry rather
than assuming its behavior. It also checks both adopted setters byte-for-byte
against the ROM and executes 2,048 setter calls across all native processor
statuses and four accumulator inputs, checking flags, register preservation,
stack balance, and neighboring-byte preservation.

These checks passed on 2026-09-10. They validate gate behavior and setter
contracts, not the unresolved long service path or the selected record's
higher-level semantics. The old map research attribution of `$C3E4CA` as a
graphics loader was incorrect; the complete routine only clears suppression.

### Complete-call observation of the normal service path

`src/probes/probe_service_rng.nim` follows a service invocation until both its
saved JSL return address and returned stack depth match. It counts RNG entries
while that invocation is active, including nested calls, rather than inferring
ancestry from fixed offsets farther up the stack. Calls still active at the
observation boundary are reported separately. Counts include any interrupt
activity during the invocation; the probe does not claim interrupt isolation.
Entry matching uses the canonical `$C0`/`$C1` addresses; execution through ROM
aliases such as RNG entry `$808E9A` is not counted. These are observed invocation
intervals, not proof that every counted draw descends from the service call.

On 2026-09-10, using 533 APU ticks per frame and 150 CPU instructions per
scanline:

| Local state / input | Frames | Completed services | Pending | Result |
|---|---:|---:|---:|---|
| `slot210.state`, idle | 180 | 0 | 0 | No service entries observed |
| `slot219.state`, idle | 180 | 0 | 0 | No service entries observed |
| `slot210.state`, held B (`8000`) | 180 | 179 | 1 | Every completed call took the long path and consumed one draw |

For the B case both gate bytes were zero. Watched calls included `$C107AF`,
`$C2109F`, `$C213AC`, `$C1FF2C`, `$C2038B`, and `$C1004E`. The latter took its
normal `$C088B1 → $C09466 → $C08B26 → $C08756` path. The one pending call
also contributed service-entry counts, so these totals are 180 rather than
179. All 180 observed RNG entries returned to `$C12DDB`.

```sh
nim r src/probes/probe_service_rng.nim bin/states/slot210.state 180
nim r src/probes/probe_service_rng.nim bin/states/slot219.state 180
nim r src/probes/probe_service_rng.nim bin/states/slot210.state 180 8000
```

This explains the measured B-window draw rate through complete-call evidence.
It does not prove other entity callbacks or the alternate `$9643` frame path
consume no additional draws. The probe remains useful for those open contexts.
The normal path also led to the verified
[OAM initializer](graphics.md#oam-build-initialization).
