## DO NOT use this to overwrite annotated asm/*.asm.
##
## The first M5 pass disassembled bytes and **wiped RE comments**. Annotated
## sources are hand-curated (or re-ported from snes_src git history with
## comment preservation). Re-export from live bytes is only for emergency
## recovery of *machine* text — it is not the evidence-preserving path.
##
## To refresh a region after editing .asm: rely on gold round-trip tests.
## Historical snes_src lives at git commit before M5 delete (parent of
## `phase2 M4–M5: adopted code as ca65 .asm`).

import std/strformat

proc main() =
  ## Refuse to clobber annotated assembly by default.
  echo "export_adopted_asm: refused."
  echo "Annotated asm/*.asm is the source of truth (comments/evidence)."
  echo "Disassembly re-export stripped RE notes once — do not repeat."
  echo &"Edit asm/<name>.asm directly; gate with tests/test_rng.nim etc."
  quit(1)

main()
