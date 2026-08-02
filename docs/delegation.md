# Delegation — decompbound specifics

**What this file is:** the *decompbound* half of delegation — our verify bars,
our contended files, our task shapes. Everything harness-agnostic lives in
racha_notes and is linked, not copied.

| Question | Where it's answered |
|----------|--------------------|
| **Who** does the work — org chart, model routing, escalation, handoff contract, who may push | racha_notes `AI/delegation.md` |
| **How** children are briefed, isolated, and bounded — worktrees, parallel safety, brief template | racha_notes `AI/orchestration_patterns/harness_subagents.md` |
| **Which harness** — `agnt` flags, lane quirks | racha_notes `AI/agent_harnesses/agnt.md` |
| **This repo's** referee, hazards, and ticket shapes | ↓ this file |

Absolute path to those notes:
`/mnt/steel-chest/Monolab/Home/racha/src/racha_notes/AI/`. They live on a
mount — if it isn't available, the rules in **Non-negotiables** below still
stand on their own, because getting them wrong is unrecoverable.

---

## Why decompbound is unusually safe to delegate

**The referee is mechanical.** Byte-match against the gold ROM, `make test`,
region checks, vector sweeps — a delegated task either verifies or it doesn't.
A worker **cannot fake its way to green**, and a wrong adoption cannot land
clean. That's what makes aggressive fan-out reasonable here, and it's why the
verify bar (not the worker's confidence) is the only thing that decides.

Corollary: **work with a mechanical referee is exactly what a cheaper worker
can do safely.** Route RE digs and bounded builds to workers per the org chart;
spend the expensive session on conducting.

## Non-negotiables (true even with no notes mount)

- **Never merge, commit, or trust on a worker's self-report.** Re-run the gate
  yourself, or audit the actual command output.
- **The referee is sacred** — `src/decompbound/compare.nim`, `tests/`,
  `src/decompbound/opcodes.nim`. Never subcontracted without the conductor
  reading the diff. A broken referee poisons every future decision.
- **Copyright hygiene** — no ROM slices, save-states, SRAM, screenshots,
  extracted scripts/graphics/audio in the index. See `AGENTS.md` → Copyright
  hygiene. Agents must *refuse* requests to commit these.
- **Workers do not push.** Shipping is a conductor duty after green gates.
- **Don't leave WIP in the shared checkout** — monofuel's `make play` compiles
  whatever is in the tree. Use a worktree, or commit/stash before you stop.
- **Names must be evidence-earned** (goal-1.5 rule): trace data or byte-level
  reasoning attached, or it doesn't land. A wrong name lies to everyone after.

## The verify bars

What "green" means here, by ticket type:

| Ticket type | Verify bar |
|-------------|-----------|
| Region adoption (`docs/goal-1.5.md`) | `make test` / `nim r tests/test_regions.nim` exit 0; `make compare` "Understood" rises, never falls |
| RE dig / format claim | Disasm the claimed offsets yourself; byte-exact round-trip (`encode(decode(b)) == b`); values range-check against a sibling table |
| Emulator / rendering fix | Targeted test + sweep the **full** captured scene corpus + goldens — one or two scenes give false confidence |
| Tool / feature | Compiles via `nim r`; a real test; run against the user's actual ROM or `.srm` |
| Anything visual, audio, or window-related | Headless probe **plus** a row in `docs/human-verify.md` (Run + Pass if) — these are not headless-provable |

## Contended files — serialize or partition

Concurrent children must not both edit: the **Makefile**,
`src/decompbound/ppu.nim`, `src/decompbound/snesbus.nim`, or anything in the
referee list above. Have children verify with `nim r` / targeted tests instead
of racing on shared make targets; the conductor adds shared targets afterward.

Probes belong in `src/probes/` **only** (`AGENTS.md` → Tools vs probes) — that
path is naturally disjoint, which is why parallel digs rarely collide.

## Task shapes that delegate well

1. **Region investigation** — `make disasm OFF=0x... N=...`; describe what the
   routine does, what memory it touches, and the evidence. Parent spot-checks
   the claimed targets.
2. **Frontier jump-table resolution** — one entry from
   `src/decompbound/generated/frontier.md` + surrounding disassembly; report
   table location, entry count, target list. Parent disassembles the claimed
   targets before trusting.
3. **Adoption tickets** (`docs/goal-1.5.md`) — adopt region X under an
   evidenced name, write the curated module, update the registry, delete the
   generated file.
4. **Mechanical sweeps** — regenerate regions after tooling changes, fix a lint
   finding across generated modules, run and summarize vector sweeps.
5. **Bounded feature coding** — one ticket, one clear verify gate, worktree if
   other writers are live.

## Task shapes that stay on the conductor

Not "never delegate" — "the top session owns the decision and reads the work":

- **Emulator correctness and protocol/timing debugging** (the APU-upload class
  of bug). These reward looking things up over assuming; a child may dig, the
  conductor owns the fix call.
- **Referee changes** — see Non-negotiables.
- **Naming without evidence** — delegated names arrive with trace data attached
  or they don't land.

## Brief template (decompbound instance)

Skeleton and rationale: racha_notes `harness_subagents.md` → Briefs must be
self-contained. Filled in for this repo:

```
You are working in the decompbound repo (EarthBound SNES decompilation in Nim).
Read docs/goal.md, docs/goal-1.5.md, and AGENTS.md (copyright hygiene) first.
Task: <one specific, bounded task>
Verification: <exact commands — e.g. make test; nim r tests/test_regions.nim>
Report: findings + evidence (offsets, disasm addresses, command exit codes);
  end with a ```handoff``` block.
Do not modify: src/decompbound/compare.nim, opcodes.nim, tests/ (the referee),
  the Makefile, or docs/*.md — report suggested doc edits instead.
Constraints: probes go in src/probes/ only; no magic bytes without TODO +
  comment; only touch the files listed above; never commit ROM slices, states,
  SRAM, screenshots, or extracted assets. Do not push; commit only if this
  brief says to commit locally in your worktree.
```

## After every delegated run

- Re-run the verify bar yourself. `git status` audit even on analysis-only runs.
- Copyright-hygiene check on the diff before any commit.
- Needs human eyes (play feel, visual, audio)? → a row in
  `docs/human-verify.md`, never chat-only; monofuel will have moved on.
  Durable bugs he finds in play get promoted to `docs/issues.md`.
- Surprising failure or success → a dated incident in the racha_notes model
  field notes (`AI/models/<family>.md`). Routine runs stay in the session log.
