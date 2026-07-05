# Feature (tabled): EarthBound message text to STDOUT

**Status:** TABLED (2026-07-04). Design captured; not yet implemented.

## Goal

Echo EarthBound's in-game message/dialogue text to stdout as the game plays —
a live text-log of the script scrolling in the terminal alongside `make play`.

## Why it's worth doing

- **Decomp understanding.** Reading the text engine's output means we actually
  understand EB's text subsystem — squarely the point of the project.
- **Debugging superpower.** Correlate the story text with the auto-capture
  frames (`bin/autoshots/` + `registers.log`): "the text said X while the
  screen showed Y." Makes scene bugs far easier to pin down.
- **Accessibility / novelty.** A readable transcript of a playthrough.

## Approach (the clean one): hook the text-print routine

The game's text engine reads encoded script bytes from ROM and, for each
printable character, calls a routine that renders it into the text window. Hook
that routine in our emulator:

1. Find the **text-print routine** address (and bank).
2. In the CPU step loop, when `cpu.pbr:cpu.pc == printRoutine`, read the
   character byte (from `A`, or the relevant WRAM/stack location the routine
   uses), **decode** it, and echo to stdout.
3. The hook itself is easy — we already step the CPU one instruction at a time,
   so it's a PC compare + a memory/register read. No perf concern (one compare
   per instruction, or install it as an optional debug hook).

The **hard part is the reverse engineering**, two pieces:

### 1. Find the print routine

EB's text engine is a well-studied subsystem; the character-print routine is
findable via disassembly (the same kind of dig grok did for the red-static
analysis — see docs/red-snow.md). Look for the routine that consumes script
bytes and writes font tiles to the text-window VRAM / text buffer.

### 2. Decode EB's character encoding

EB does **not** use ASCII:
- Printable characters are byte values **offset** from ASCII (there's a
  character table). Map byte -> char via that table.
- **Control codes** do line breaks, pauses/waits, "insert player/party-member
  name," insert item/PSI names, prompts, window control, etc.

**First version:** decode the printable characters + newlines; skip or annotate
control codes (e.g. print `[wait]`, `[name]`). **Polished version:** handle name
substitution and inline item/PSI names so the log reads like real dialogue.

## Alternative (not preferred): OCR the text-window VRAM

Read the dialogue-window tilemap from VRAM each frame and map tile index ->
character via the font layout. Downsides: needs the font tile->char map, only
captures on-screen text, must dedup across frames and handle
one-character-at-a-time reveal + scrolling. The routine hook is cleaner because
it captures the *semantic* stream once, as processed.

## Difficulty

- Hook: easy (an afternoon).
- RE (routine + character table + common control codes): the real work — a
  focused reverse-engineering dig, achievable, comparable to the red-static
  analysis.

## Next steps when we pick this up

1. Delegate to grok (analysis only): find the text-print routine address+bank,
   the character encoding table (byte->char, and the ASCII offset), and the
   common control codes (line break, wait, name-insert). Cite disassembly
   addresses/bytes, like the red-static analysis.
2. Add an optional stdout text-log hook in the CPU loop (behind a `--text-log`
   flag on play.nim, or always-on to stdout).
3. Iterate: printable chars + newlines first, then name/item substitution.

## Related

- [[red-snow]] docs/red-snow.md — example of the grok disassembly-dig workflow.
- Auto-capture (`bin/autoshots/`) in `src/tools/play.nim` — the visual/register
  history this text log would correlate with.
