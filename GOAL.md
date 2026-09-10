# Objective

Fully understand the US EarthBound ROM: how its code works, how its scripts
express game behavior, and how its graphics and audio are stored and used.
Rebuild the original ROM byte-for-byte throughout that work.

The product is an explained game, backed by reproducible evidence and our own
source. The emulator, viewers, probes, dashboards, and agent player are tools for
reaching that outcome. Supporting work counts toward these goals when it answers
a named reverse-engineering question or removes a concrete obstacle to answering
one. Playing the game successfully proves useful emulator behavior; it does not
prove that we understand the game code it executes.

This is the canonical top-level goal document. The numbers below supersede the
older Goal 1 / 1.5 / 2 / 3 / 4 / 5 scheme in historical documents. Detailed
research stays in the existing topic docs; no separate ideas notebook is needed.

## Goals and current baseline

Baseline checked on 2026-09-10, after adopting the service-suppression setters on
`decomp/rng-contract-2026-09-10`. Earlier unfinished work remains preserved on
`review/pending-2026-09-10`.

| Goal | Outcome | Current state |
|---|---|---|
| **1. Rebuild identically** | Reconstruct every original byte from our source and the user's local extraction. | **Met; maintain.** `make compare` printed `BYTE-IDENTICAL`. |
| **2. Understand all code** | Explain every game routine, its contracts, and its role in the larger system. | **Early.** 38 assembly regions, 2,048 bytes, formally marked explained and reproduced. Additional research lives outside that inventory. |
| **3. Understand scripting** | Explain the script languages, their interpreters, and how scripts cause game behavior. | **Partial.** Text decoding and entity action-script machinery exist; complete semantics and a whole-ROM script inventory remain open. |
| **4. Understand graphics** | Explain and browse the game's graphics, including the assembled world map. | **Partial.** Rendering/compression tools exist; a complete asset catalog and faithful browse-all viewer do not. |
| **5. Understand audio** | Explain the sound driver, music, effects, instruments, and playback behavior. | **Partial.** Emulator playback and annotated upload/song-selection routines exist; full driver and content interpretation remain open. |

The manifest currently covers 3,145,728 bytes in 57 regions. Of those bytes,
2,048 (0.0651%) are `reproduce` / `explained`; 3,143,680 are `copy` / `unknown`.
This denominator is the **whole ROM**, including data and assets, not executable
code alone. It is not a percentage of functions understood. Recompute from
[manifest.json](manifest.json) when updating this baseline.

## Goal 1 — Rebuild the ROM identically

Reconstruct the user's original ROM with the same layout and every byte intact.
Assemble understood routines from source, extract the remaining regions locally,
and compute the SNES header checksum during the build.

**Done when:**

- [x] The manifest accounts for the complete ROM without gaps or overlaps.
- [x] Extraction and rebuilding work with the user's supplied ROM.
- [x] The rebuilt ROM compares byte-for-byte equal to that ROM.

Asset hygiene remains a standing requirement, checked on every proposed commit;
the successful rebuild is not a certification of historical repository contents.

**Standing gate:** run `make compare` after changes to assembly, codecs, the
manifest, extraction, or rebuilding. Also run the tests relevant to the change.
Keep the comparison independent of the implementation being evaluated.

Copying an unexplained region satisfies this goal. It earns no comprehension
credit under Goals 2–5. Decoding assets for browsing is separate from how their
original bytes enter the vanilla build.

References: [phase-2 build plan](docs/decompilation-phase2.md),
[manifest](manifest.json), [terms](docs/terms.md).

## Goal 2 — Understand all code

Explain all executable game code: the main 65816 program and the uploaded SPC700
sound-driver code. Goal 5 owns the detailed audio investigation; its code findings
also contribute here. Assembly is the game-source target; Nim is the language of
our emulator and tools. A native Nim rewrite is not a completion requirement.

Understanding includes routine boundaries, inputs and outputs, register and
memory effects, callers, control flow, data structures, and why the routine exists.
Name fields and functions from evidence. Explain meaningful constants and mark
unresolved interpretations explicitly.

**Done when:**

- [ ] Executable regions are distinguished from data with evidence, including
  indirect dispatch targets, overlays/uploads, and paths outside normal play.
- [ ] Every routine has an accurate name, a documented contract, annotated source,
  and references to its callers and relevant structures.
- [ ] Subsystem explanations connect individual routines into game behavior:
  startup, input, overworld, battles, inventory, saves, progression, rendering,
  script execution, and audio control.
- [ ] Explained routines reproduce their original bytes, and behavioral claims
  have targeted checks or reproducible traces beyond byte matching alone.
- [ ] All executable regions are covered; unresolved boundaries and reachable
  dispatch targets are tracked rather than silently excluded from the denominator.

**Examples already worth building on:** the RNG generator and pure seed oracle,
controller polling, hardware multiplication, SRAM mirror check, graphics-register
setup, action-script fetch/dispatch, APU uploads, and song selection. Even an
adopted routine can retain specific open questions; track those before declaring
its subsystem fully understood.

Game-rule tables belong with their consumers: enemy/item records, EXP and growth,
formation data, drop rules, and other non-script data need layouts and semantics,
not just addresses. Their contents continue to come from the user's ROM.

References: [annotated assembly](asm/), [RNG reference](docs/prng.md),
[data research hub](docs/decompilation.md), [adoption evidence rules](docs/goal-1.5.md).

## Goal 3 — Understand scripting

Explain the distinct bytecode systems used for dialogue/events and entity actions,
including their execution state and interaction with the game engine. Script
interpretation is part of Goal 2; script formats and behavior belong here.

**Done when:**

- [ ] Inventory each script language, its entry points, pointers, and boundaries.
- [ ] Document every opcode/control code, operand width, branch/call rule, and
  side effect; unknown instructions are reported explicitly.
- [ ] Explain flags, waits, conversations, movement, battles, item transfers,
  party changes, and other script-controlled behavior through traced examples.
- [ ] Provide local extraction into a readable, structured representation with
  offsets, cross-references, and an index for browsing.
- [ ] Validate interpretation against the game's own execution and byte-preserving
  parse/encode checks across the inventoried scripts. Retaining opaque payloads
  can preserve bytes, but does not complete their explanation.

Dialogue text, event sequences, and extracted script bodies remain local assets.
Commit interpreter code, format descriptions, structural facts, and synthetic
tests; do not commit the game's script content.

References: [scripts](docs/scripts.md), [action-script module](src/decompbound/action_script.nim).

## Goal 4 — Understand graphics

Explain how graphics are located, decoded, arranged, colored, animated, and sent
to the PPU. Include battle enemies, overworld characters, backgrounds, fonts/UI,
tilesets, palettes, and the world map with its rooms and arrangements.

**Done when:**

- [ ] Inventory all graphics classes and their pointer tables, lengths, formats,
  compression, palettes, arrangements, and animation references.
- [ ] Explain the game routines that load and compose each class, including
  palette selection, layering, transformations, and battle-background effects.
- [ ] Browse enemy sprites and other assets by identity, with correct palettes
  and assembly of tiles, rather than requiring guessed offsets.
- [ ] Browse the assembled world map and interiors, with tileset/sector links;
  distinguish visual layout from collision, doors, and event behavior.
- [ ] Verify decoded assets and scene composition against local game execution,
  with representative scene checks and recorded human verification where needed.
- [ ] Document the encoding of every class. Claim byte-exact re-encoding only
  where comparison with the original compressed representation proves it.

The current sprite and map tools export PNGs from manually selected offsets and
use synthetic palettes. Those are investigation tools, not complete asset
browsers. Likewise, `decode(encode(raw)) == raw` proves decoded-content fidelity;
it does not establish that an encoder recreates the original compressed bytes.
Keep the original-byte rebuild path until that stronger claim is verified.

References: [graphics](docs/graphics.md), [battle backgrounds](docs/battle-backgrounds.md),
[bestiary plan](docs/bestiary.md), [map/data research](docs/decompilation.md).

## Goal 5 — Understand audio

Explain the complete path from a game event or song ID to sound: main-CPU
commands, package uploads, SPC700 driver execution, sequences, instruments,
BRR samples, sound effects, and DSP settings.

**Done when:**

- [ ] Inventory songs, sound effects, packages, sequences, instruments, and sample
  references, including which resources are shared or replaced.
- [ ] Explain the driver code, command protocol, timing, sequence instructions,
  loops, pitch/envelopes, mixing, and echo behavior used by the game.
- [ ] Browse and play the inventoried songs, effects, and instruments from the
  user's ROM, with identities and source references rather than anonymous bytes.
- [ ] Validate decoding and driver behavior against traced uploads, port traffic,
  and playback; record audible checks in the human-verification checklist.
- [ ] Verify byte-preserving parsing and encoding for package, sequence, and
  instrument structures; distinguish preserved opaque fields from explained ones.
- [ ] Document preservation and re-encoding limits per format. WAV exports are
  for listening; BRR-to-WAV-to-BRR is not presumed byte-identical.

An emulator that plays the soundtrack does not by itself explain the uploaded
program or sequence language. The generic `view_export` audio sample currently
writes package bytes as PCM noise; it is a plumbing demonstration, not a decoded
song or sample. Use actual driver/DSP playback as evidence.

References: [audio research](docs/audio.md), [song loader](asm/loadSong.asm),
[APU upload routine](asm/uploadApuPackages.asm).

## Investigation loop

At each checkpoint, name the goal, the region or mechanism under investigation,
the current hypothesis, and the next evidence needed to accept or reject it.
Prefer a small question that can reach a conclusion over a broad tool-building
project without an acceptance criterion.

1. Inspect existing source and evidence first. Resolve stale documentation before
   repeating an investigation that a newer module or probe already settled.
2. State one bounded question and its expected observable behavior.
3. Gather evidence from our disassembler, emulator, traces, and the user's ROM.
   Community documentation can suggest hypotheses; derive and verify the claim
   independently with our own tooling.
4. Produce an explanation and the smallest source/tool change needed to express
   it. Keep temporary digs in `src/probes/`; graduate reusable logic with tests.
5. Run the appropriate byte and behavioral gates. Record offsets, commands,
   evidence scope, and remaining uncertainty in the relevant topic document.
6. End with an accepted explanation, a concrete revised hypothesis, or a rejected
   claim with a reusable reason. Update the manifest only for regions actually
   promoted, then re-run the vanilla gate.

Parallel investigations may target independent regions or subsystems. Give each
worker a bounded question and verification bar; the conductor reviews the diff
and verifies results before integration. Follow [delegation.md](docs/delegation.md).

## Progress and prioritization

Goal 1 stays green while Goals 2–5 advance in parallel. Work on code consumers and
associated data together where that produces stronger evidence. Default to
converting existing research into verified explanations before building another
viewer or dashboard without a named question to answer.

Report three things separately:

- **Build:** whole-ROM identity and the share regenerated versus copied.
- **Understanding:** explained routines/formats, evidence coverage, and unresolved
  questions. Use the manifest's Build × Comprehension axes for claimed bytes.
- **Usability:** whether someone can inspect scripts, browse assets, or hear audio
  faithfully. A working viewer is useful evidence, not automatic comprehension.

Do not invent percentages where a complete inventory or denominator is missing.
Track work and evidence in the linked topic docs; use [issues](docs/issues.md) for
bugs and [human verification](docs/human-verify.md) for checks requiring eyes/ears.
The dated baseline above is a snapshot, not a substitute for running the gates.

Emulator fixes, playthroughs, TAS replay, and agent experiments remain supporting
work. Tie them to a goal or a concrete blocker. ROM hacking, relocation, and
native reimplementation are outside these five goals unless explicitly added.

## Leave the code better than you found it

Repository maintenance is part of completing work on each goal. Accumulated stale
docs, abandoned probes, and unverified test scaffolding make the next investigation
harder. When working in an area, leave its code, documentation, and verification
clearer and more trustworthy. Prefer deletion and consolidation over adding another
layer. Keep cleanup bounded to the work at hand; larger cleanups need their own
scope and verification criteria.

- **Documentation:** check claims against current source and evidence. Keep one
  authoritative explanation per topic. Move still-useful findings into it, remove
  obsolete or duplicate documents, and repair incoming links. Preserve unique
  offsets, reasoning, and reproducible evidence before removing an old report;
  git history can retain superseded plans and session narration.
- **Probes:** finish the investigation, not just the script. Record the conclusion
  and reproduction method in the relevant topic doc. Promote reusable logic into
  product modules with appropriate tests, then remove redundant probes. Retain a
  probe only when it still answers an open question or provides a useful way to
  reproduce evidence; state its purpose, inputs, and invocation.
- **Tests:** inspect what each test actually exercises and run it before claiming
  coverage. A test file's existence, successful compilation, or a skipped fixture
  is not evidence that behavior passed. Replace placeholders and assertions that
  only mirror implementation details with meaningful checks where needed. Exercise
  real caller/helper interactions when the claim is about integration.
- **Test discovery:** put retained checks in the appropriate unit, integration,
  or end-to-end suite, with explicit input requirements and reproducible commands.
  Remove duplicate or obsolete scaffolding only after establishing what coverage
  it provides and what replaces it, if anything. Never delete or weaken a failing
  assertion merely to make the suite green; the referee remains independent.
- **Completion:** review the surrounding docs, probes, and tests for leftovers
  introduced or superseded by the change. Report what was run, what was skipped,
  and remaining uncertainty. Leave an explicit issue for relevant cleanup too
  large to finish in scope, rather than quietly treating scaffolding as complete.

## Repository and verification rules

- The user supplies the ROM. Never commit ROM slices, extracted assets/scripts,
  screenshots, save-states, SRAM, or audio/memory dumps. Use ignored `extracted/`
  or `bin/` outputs; keep live F12 captures in the user's screenshot archive.
- Preserve unfinished changes on review branches; integrate verified work in
  focused commits. A pushed WIP commit is preservation, not acceptance.
- Treat assembly names, format claims, and completion checkmarks as claims that
  need evidence. Full-game play and byte identity answer different questions.
- Keep scope and numbering here; keep implementation detail in topic docs. Older
  docs may retain historical numbering and retired paths, so verify against code.

Useful gates: `make compare`, `nim r tests/test_manifest.nim`,
`nim r tests/test_progress_report.nim`, `nim r tests/integration_rng.nim`, and
`nim r tests/integration_action_script_fetch.nim`. Select further tests for the
subsystem being changed. Write progress reports outside tracked documentation
unless intentionally updating it, for example:

```sh
nim r src/tools/progress_report.nim --out /tmp/decompbound-progress.md
```
