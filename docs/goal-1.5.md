# Goal 1.5: The Adoption Campaign (historical)

> ## SUPERSEDED — historical record
>
> Phase 2 ([`decompilation-phase2.md`](decompilation-phase2.md)) replaced the
> Nim `snesAsm` / `generated/*` representation with ca65-convention **`.asm`**
> and a JSON **manifest**.
>
> - `generated/*.nim` — **deleted** (M2.5).
> - Adopted explained routines — **ported** to `asm/*.asm` (M5); assembled via
>   `asm_parse.nim` → `assemble()`.
> - Evidence rules **survive** (below).
>
> Do not implement the Nim adoption campaign described in the body. Use phase 2
> gates instead.

## Evidence rules (still in force)

These apply to every name and claim in the phase-2 flow:

1. **Evidence-earned names** — trace data, disassembly at a named file offset,
   or a byte-level argument. A wrong name is a lie; it does not land.
2. **Gold-gated** — every adopted / `reproduce` region must reassemble
   byte-identical to gold at its fixed offset (`rom_rebuild` / targeted tests).
3. **No copyrighted content in git** — only our expression (annotated asm,
   format docs, tools, the manifest). Extracted bytes stay under `extracted/`.

## What Goal 1.5 was

After Goal 1 proved `assemble(disassemble(bytes)) == bytes` for traced code,
`generated/` held ~1.3M lines of machine Nim scaffold. Goal 1.5 replaced spans
with hand-named `snes_src` modules using a `snesAsm` macro — still gold-gated,
still honest progress on the **comprehension** axis.

That improved readability but **not** compile cost: the macro lowered to the
same statement shape as the scaffold (~25 KB compiler memory per line). Phase 2
keeps the evidence and the names, drops the Nim statement stream.

## Migration status

| Then | Now |
|------|-----|
| `snes_src/*.nim` + `snes_asm.nim` | `asm/*.asm` + `adopted.nim` loader |
| `generated/code_bankXX.nim` | deleted; residual is `copy` blobs |
| `make compare` via bank assemble | `rom_extract` + `rom_rebuild` |
| Progress as map % | Build × Comprehension ([`terms.md`](terms.md)) |

## Related

- [`decompilation-phase2.md`](decompilation-phase2.md)
- [`goal.md`](goal.md)
- [`terms.md`](terms.md)
