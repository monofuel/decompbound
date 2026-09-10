# Project goals

The canonical top-level plan is **[GOAL.md](../GOAL.md)** at the repository root.
It defines the objective, current baseline, acceptance criteria, and investigation
loop for these five goals:

1. Rebuild the ROM byte-identically.
2. Understand all game code.
3. Understand scripting.
4. Understand graphics, including the world map.
5. Understand audio.

This numbering supersedes the historical goal scheme. Emulator development,
TAS replay, asset viewers, and agent play support these goals. The phase-2
assembly/manifest direction remains in effect; native Nim reimplementation is
outside the current scope.

Implementation references:

- [Phase-2 build plan](decompilation-phase2.md): assembler, extraction, rebuilding.
- [Terms](terms.md): Build × Comprehension axes and evidence vocabulary.
- [Known issues](issues.md): emulator bugs and investigations.
- [Human verification](human-verify.md): checks requiring play, sight, or hearing.
- [Historical Goal 1](goal-1.md) and [adoption campaign](goal-1.5.md): prior work
  and surviving evidence rules, using the old numbering.
