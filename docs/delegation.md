# Delegating decompbound work via agnt

decompbound is unusually safe to delegate: the harness grades everything
mechanically (byte-match against gold, `make test`, vector sweeps), so a
delegated task either verifies or it doesn't — a weaker/cheaper model
cannot fake its way to green. This doc covers how to hand work to
subscription agents through monofuel's `agnt` wrapper.

**Current policy: target grok only.** The SuperGrok Heavy subscription is
effectively unlimited, cheap, and fast. Local models (opencode/Azem) join
later once kernel sandboxing lands in agnt; claude-code is the orchestrator
and stays on judgment work, especially when Fable quota is tight.

## The wrapper

```
agnt grok "task..."          # read-only (investigate/report) - DEFAULT
agnt -w grok "task..."       # write mode (full-auto edits in cwd)
agnt list                    # recent task logs (~/.agnt/tasks/)
```

- Run from the decompbound repo root so relative paths and the Makefile work.
- **Grok's read-only (plan) mode is broken headless** (2026-07-04): any
  tool-using task returns empty output. Use `agnt -w grok` with "analysis
  only, do not modify files" in the prompt; verify with `git status` after.
  Plan mode was permission-layer-only anyway (no kernel sandbox).
- Every run logs prompt/result/stderr under `~/.agnt/tasks/<timestamp>/`.
- Known grok failure mode: a dead MCP server can make it exit 0 with empty
  stdout. An empty result is a failed run, not a null finding - check
  stderr before believing it.
- grok CLI serves two models: grok-build (default, advanced coding) and
  composer 2.5. Both are fair game; log which one ran when comparing.

## Task shapes that delegate well (verification-backed)

1. **Region investigation** (read-only): "Run `make disasm OFF=0x... N=...`
   and describe what this routine does, what memory it touches, and what
   evidence supports that." Costs nothing but grok quota.
2. **Frontier jump-table resolution** (read-only): give it one entry from
   `src/decompbound/generated/frontier.md` plus surrounding disassembly;
   ask for the table location, entry count, and target list. Verify by
   disassembling the claimed targets before trusting.
3. **Adoption tickets** (write, docs/goal-1.5.md): "Adopt region X: name it
   <evidenced name>, write the curated module, update the registry,
   delete the generated file. `make test` must pass." The per-region gold
   test is the gate; a wrong adoption cannot land green.
4. **Mechanical sweeps** (write): regenerate regions after tooling changes,
   fix a lint finding across generated modules, run and summarize the full
   vector sweeps.

## Task shapes that stay on claude-code

- Emulator correctness and protocol debugging (the APU upload capture
  class of problem) - failure modes there reward "makes assumptions
  instead of looking things up," which is grok's documented weakness.
- Anything changing the verification harness itself (compare.nim, tests,
  the opcode table). The referee does not get subcontracted.
- Naming without evidence. Delegated names must arrive with trace data or
  byte-level reasoning attached, per goal-1.5's evidence rule.

## Prompt template

Delegated prompts should be self-contained - grok gets no conversation
history. Include:

```
You are working in the decompbound repo (Earthbound decompilation in Nim).
Read docs/goal.md and docs/goal-1.5.md first.
Task: <one specific, bounded task>
Verification: <the exact command(s) that must pass, e.g. make test>
Report: <what to output - findings, diffs, evidence>
Do not modify: src/decompbound/opcodes.nim, compare.nim, tests/ (the referee).
```

## After every delegated run

- Verify the result against the harness yourself; never merge on grok's
  self-report.
- Surprising failures or successes get logged as dated incidents in the
  racha_notes model field notes (`AI/models/grok.md` /
  `cursor_composer.md`), per the agnt calling-agent protocol. Routine runs
  stay in `~/.agnt/tasks/`.
