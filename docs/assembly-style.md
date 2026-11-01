# Assembly coding and documentation style

Annotated assembly should let a reader follow the game's behavior from top to
bottom. Explain each operation where it happens. Keep the calling contract easy
to find, and keep detailed reverse-engineering evidence in the topic reference.
These rules apply to new and edited `asm/*.asm`; improve older files when working
on their routines rather than requiring a repository-wide formatting sweep.

## Routine contracts

Start with the purpose and original file/SNES or file/APU addresses, followed by
a compact calling contract. Aim for about five to ten comment lines. Include what a caller
needs to use the entry safely:

- Entry convention: JSL/RTL, JSR/RTS, or fall-through/shared tail.
- Inputs and results, including carry/status when it distinguishes outcomes.
- Required register widths, data bank, direct-page setup and decimal mode.
- Preserved registers and important side effects or failure behavior.
- A pointer to the existing topic document for evidence and detailed layouts.

Put a separate short contract beside each additional callable entry. Do not
collect several entry points' contracts into one long file preamble. For a
shared tail or a region ending in fall-through, name the next entry and explain
the connection at that boundary.

Use these terms consistently:

| Term | Meaning |
|---|---|
| A, X, Y | Accumulator and index registers; state which values they carry. |
| M16/X16 | 16-bit accumulator/index execution; M8/X8 means 8-bit execution. |
| D / DP | Direct-page base register / addresses relative to that base. |
| DBR | Data bank used by absolute memory operands. |
| PBR | Program bank; near calls and jumps stay in this bank. |
| Entity ID / entity offset | Slot number / doubled byte offset into word arrays. |
| File / SNES | Headerless ROM offset / CPU bus address; always identify which. |

Write "decimal clear" explicitly; `D` alone could mean the direct-page register.
Distinguish register status from the `.a16`/`.i16` assembler hints: a hint changes
encoding assumptions, while REP/SEP change runtime execution.

## Explain the body in logical blocks

Separate meaningful operations with one blank line. Put a short comment directly
above a group when its purpose is not evident from names. Typical blocks are
scratch setup, resource lookup, allocation, record initialization and cleanup.
Long straight-line code needs these breaks even if it contains no branch labels.

Use inline comments for the meaning of a memory field, a constant or a callee.
Explain a surprising constraint or flag dependency at the instruction that relies
on it. Do not make a reader scroll to the header to discover what an address means.
Avoid paraphrasing instructions, such as "load A" or "increment Y", or adding a
comment to every line. Comment the reason, the game-level operation, or a field's
role. Small, self-explanatory groups need no extra narration.

For example, this excerpt retains the original numeric operands while exposing
the ownership and failure behavior:

```asm
    ; Reserve enough records for both sprite-definition variants.
    JSL $C01A9D             ; Find free definition storage.
    STA $1F                ; Saved allocation result.

waitForDefinitionSpace:
    ; Failure spins on the saved result; this loop does not retry allocation.
    LDA $1F
    CMP #$7FFF
    BEQ prepareConstructor
    BCS waitForDefinitionSpace

prepareConstructor:
    LDA #$0001
    STA $0A4A              ; New sprites use rendering queue 1.
```

## Names, operands and layout

- Keep labels in column one and indent instructions and directives four spaces.
  Use uppercase mnemonics and hexadecimal digits, lowercase width directives,
  and camelCase labels consistent with the existing source.
- Prefer labels describing intent: `lookupResource`, `unlinkFreeEntity`, or
  `returnEntity`. Keep local names short enough to read in branch operands.
  Label meaningful entries and branch destinations; do not label every block.
- Align inline comments within the surrounding block when useful. Keep lines
  near 80 columns; avoid decorative rulers, giant banners and rigid padding.
- Identify hardware registers, WRAM fields and known callees by meaningful names
  in nearby comments when the operand must remain numeric. Include a field's
  units where important: bytes, words, raw IDs, doubled offsets or VRAM words.
- Use supported symbolic operands where their meaning and encoding are proven.
  The current front end supports local code labels, but not general named memory
  constants, include files or cross-file symbol imports. Do not write illustrative
  EQU expressions into build source or extend the assembler merely to format a
  routine. Hex digit width can select the addressing mode; preserve it.
- Retain every required width directive, including hints after callees that
  restore widths. Explain a non-obvious width or inherited-flag dependency locally.
- Write structural code-pointer tables as `.word` entries with the dispatch index
  and known target role beside each entry. Keep table aliases and shared entries
  visible. Do not hide pointer structure in long, unexplained `.byte` rows.
- Explain unresolved values by their observed use and mark the unknown meaning
  with a specific TODO. Do not invent game-level names for unknown fields.

## SPC700 source

Use `.spc.asm` for uploaded SPC700 code; ordinary `.asm` selects the 65816
assembler. Both follow the contracts, logical blocks and evidence rules above.
Distinguish the APU execution address from the ROM file offset holding its upload
payload. Start each SPC source with `.org $APUaddress`: it sets label and branch
addresses without emitting padding. The manifest still controls ROM placement.

Use Sony destination-first operands: `MOV $12,#$34` stores the immediate into
direct-page byte `$12`. `$12` selects direct page and `$0012` or `!$12` selects
absolute where available. Preserve those widths; ports `$F2/$F3` may deliberately
use absolute instructions. Indexed forms use `+X`/`+Y`, `[$12+X]` or `[$12]+Y`;
bit operands use `$1234.5`, with `/` for supported inverted-bit forms.

SPC700 has fixed eight-bit registers and a YA word pair, so it needs no 65816
M/X hints. State the runtime PSW direct-page flag requirement instead: page zero
or page one. Use local labels for branches; numeric cross-file calls identify
the callee in a nearby comment. `.byte`/`.word` describe structural data only;
write executable instructions as mnemonics. Numeric arithmetic and local labels
are supported; macros, includes, EQU and cross-file symbol imports are not.

Before adoption, run `tests/test_spc_asm.nim`, the relevant driver behavior tests
and the vanilla byte-identical rebuild. CPU/port checks run without speakers;
byte identity does not establish complete musical or DSP timing correctness.

## Source comments and research evidence

The assembly explains the routine as it is: how to call it, what its blocks do,
and why unusual details matter. Topic references explain how the conclusion was
established: disassembly offsets, caller/callee relationships, structure tables,
commands, test coverage and unresolved hypotheses. The manifest tracks adoption.

Keep one authoritative explanation of each mechanism. Preserve unique evidence
in the relevant existing topic document before removing it from a header. Do not
replace a long header with a new per-routine report. Test-case totals, migration
history, dates and lists of former filenames do not belong in routine preambles.
Comments must remain useful without the PR discussion or the author's workspace.

Existing topic references:

- [Scripts and entity lifecycle](scripts.md).
- [Graphics, sprite resources and OAM](graphics.md).
- [World map](world-map.md).
- [RNG](prng.md).
- [Audio](audio.md).

## Verification

Readability edits preserve the original instructions, addressing modes, layout
and entry contracts. Do not combine them with optimization or speculative fixes.
Labels and whitespace may change; the assembled bytes must not.

Run `make compare` and require `BYTE-IDENTICAL`. Run the relevant existing tests
when a contract, label, width hint or operand changes; do not add tests that merely
count comment lines or enforce superficial formatting. Review the source itself:
can a reader identify the purpose of each phase without memorizing the header?
Preserve all existing behavioral checks and the independent byte-comparison gate.
