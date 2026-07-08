# Delegation — Grok 4.5 conductor + native sub-agents

How we fan decompbound work out without trusting self-reports. **Default path
is Grok-native.** One Grok Build / Grok 4.5 top session is the conductor; it
owns verification and fans work to built-in sub-agents (`spawn_subagent`). No
Claude layer. No `agnt` required for day-to-day work.

decompbound is unusually safe to delegate: the harness grades everything
mechanically (byte-match against gold, `make test`, vector sweeps), so a
delegated task either verifies or it doesn't — a worker cannot fake its way to
green.

**Origin / cousin:** Softmax coworld's dual-path playbook
(`coworld-playbook/docs/delegation.md`) evolved from an earlier Claude→groknard
version of *this* doc. decompbound has flipped fully onto Grok 4.5 for both
manager and workers; the Claude overflow path is gone (Max quota is not the
budget we have).

---

## Shared trust tiers

These are roles, not brand loyalty. Model names change; the tiers do not.

1. **Untrusted worker** — edits in the workspace (or analysis-only), returns a
   handoff, never owns the final merge call on narrative alone.
2. **Verifier** — runs *commands*, not vibes: `git status` / `git diff`,
   `make test`, per-region gold checks, vector sweeps, disasm spot-checks.
   The parent (or a dedicated verify child whose *output* the parent still
   audits) does this. **Never merge on a worker's self-report.**
3. **Conductor judgment** — adopt / merge / harness changes / naming without
   evidence. High stakes; surface evidence, then the top session decides.
4. **Referee stays sacred** — do not subcontract changes to the verification
   harness itself (`compare.nim`, `tests/`, the opcode table) to a throwaway
   worker without the conductor reading the diff. A broken referee poisons
   every future decision.

**Handoff contract:** workers return a single fenced ` ```handoff ` block when
the parent asks for one. Suggested fields (omit with `null` + one-line reason,
never guess):

```
```handoff
task: <restated task>
status: done | partial | blocked
evidence: <offsets, traces, disasm notes — what supports the claim>
diff_summary: <files touched / key changes, or null>
verification: <commands run and exit status, or null if not run>
blockers: <null or concrete next fact needed>
```
```

---

## Grok 4.5 rules (native conductor + sub-agents)

**Default path.** One top-level Grok 4.5 / Grok Build session *is* the
orchestrator. It owns goals and verification and fans work to **native
sub-agents** — not to Claude managers, and not to `agnt` unless dogfooding
(see below).

### Shape

```
Grok 4.5 top session  (conductor: goals, verify, merge decisions)
  ├─ subagent general-purpose  → coder / adoption / mechanical sweeps
  ├─ subagent explore          → region RE, frontier digs, codebase scouts
  ├─ subagent plan             → multi-step plans (read-only)
  └─ optional worktree isolation when parallel writers would collide
```

- **Sub-agents are enabled by default** in Grok Build (`spawn_subagent`).
  Keep them on for decompbound swarm work.
- Built-in types: `general-purpose` (full tools), `explore` (read/search, no
  edits), `plan` (read-only planning). Prefer `explore` for pure investigation
  so the child's context stays clean.
- Children get their **own context window**; the parent keeps durable decisions
  and the verification gate. Point each child at a self-contained brief (see
  prompt template below) — they inherit no chat history.
- **Worktree isolation** (`isolation: "worktree"`) for parallel coders that
  would otherwise fight over the same tree. One worktree per task; merge only
  after the parent verifies green.
- Sub-agents **inherit the parent model by default.** SuperGrok is the
  abundant lane — parallel children are expected, not exceptional.
- The parent **re-drives incomplete children** itself (no second-brand manager
  layer). Coders habitually stop at ~70% with "lmk if you want me to continue."
  The conductor's job is to refuse half-done work: read the handoff, spot
  unfinished bits, spawn a follow-up (or resume) until verified complete.

### What the Grok conductor does itself

- Session goals and what to fan out next.
- Spawn / collect handoffs / re-drive incomplete children.
- Verification gates (`make test`, gold byte-match, disasm of claimed targets).
- Merge / adopt decisions (or explicitly assign a child to *execute* a merge
  the conductor already decided — the decision stays top-level).
- Anything that changes the referee (harness / tests / opcode table) after the
  conductor has read the diff.
- **Human-facing verify queue** — when a fix needs monofuel's eyes (live play,
  "does this look right"), append a row to **`docs/human-verify.md`**. Do not
  rely on chat-only "please test this"; he will have moved on. Details in that
  file.

### What sub-agents do

Verification-backed shapes:

1. **Region investigation** (explore / analysis): run
   `make disasm OFF=0x... N=...` (or equivalent), describe what the routine
   does, what memory it touches, and what evidence supports that. Parent
   spot-checks claimed targets.
2. **Frontier jump-table resolution** (explore): one entry from
   `src/decompbound/generated/frontier.md` plus surrounding disassembly;
   report table location, entry count, and target list. Parent verifies by
   disassembling the claimed targets before trusting.
3. **Adoption tickets** (general-purpose write, docs/goal-1.5.md): adopt
   region X with an evidenced name, write the curated module, update the
   registry, delete the generated file. `make test` must pass — a wrong
   adoption cannot land green.
4. **Mechanical sweeps** (general-purpose write): regenerate regions after
   tooling changes, fix a lint finding across generated modules, run and
   summarize vector sweeps.
5. **Bounded feature coding** (general-purpose write): one ticket, clear
   verify gate, preferably a dedicated worktree if other children are live.

### Parallel safety

Workers run blind to each other. Rules:

- Do not let concurrent children edit the same shared file (e.g. `ppu.nim`,
  `snesbus.nim`, the Makefile). Serialize on contended files, or partition so
  writers touch **disjoint** paths.
- Prefer children that build/verify via `nim c -r` / `nim r` / targeted tests
  rather than racing on shared Makefile edits; the conductor adds shared
  make targets afterward if needed.
- Worktree isolation when two writers would otherwise touch overlapping paths
  (see **Worktrees** below).

### Worktrees

Use `spawn_subagent` with `isolation: "worktree"` when it reduces blast radius
or parallel clobber risk. Shared-workspace (`isolation: "none"`) is fine for
read-only explore, digs that only write under `bin/` / scratch, or a single
writer with nothing else live.

**When worktrees help**

- Two+ **write** children that might touch overlapping modules, docs, or the
  Makefile.
- Goal 1.5 adoptions, new tools, test files — anything that would fight if two
  agents edit the main tree at once.
- Risky refactors you want quarantined until green.

**When to skip them**

- Pure `explore` / analysis (no edits) — shared tree is fine.
- One writer only, or writers already partitioned onto **disjoint paths** the
  briefs enforce.
- Conductor is the only editor (children report; parent types the patch).

**How to use them**

1. Spawn write children with `isolation: "worktree"` (one worktree per task).
2. Child implements + runs its verify bar **in that worktree**.
3. Conductor **re-runs** the gate (or audits real command output), then
   brings accepted changes into the main workspace (copy/merge/cherry-pick —
   whatever the harness returns; the decision is top-level).
4. Do **not** commit or push from a child worktree as the final ship path
   unless the conductor explicitly assigned that and re-verified first.
5. Drop or leave obsolete worktrees after merge; do not leave long-lived
   divergent trees as the source of truth.

**Parallel packing example (safe wave)**

```
explore (shared)     → game-data dig        # no edits
explore (shared)     → map dig              # no edits
general-purpose + worktree → Goal 1.5 adoption
general-purpose + worktree → sram report tool
explore (shared)     → battle-BG RE notes   # analysis only
```

### Commit and push

Shipping is a **conductor** duty after gates are green. Workers produce diffs
and handoffs; they do not own "it's on origin/master now" from self-report.

**Before any commit**

1. Re-run the ticket's verify bar yourself (`make test`, `nim r tests/...`,
   disasm spot-check of claimed offsets, tool against a real `.srm` / ROM path
   as appropriate). **Never commit on a worker's "tests pass" alone.**
2. `git status` / `git diff` — confirm only intended paths; **copyright
   hygiene** (AGENTS.md): no ROM slices, extracted scripts/dialogue, graphics
   dumps, WAVs, savestates, or screenshots of game graphics in the index.
3. Leave dig-only scratch tools untracked unless they are lasting project
   tools; do not commit `bin/` asset output.
4. Prefer **focused commits** (one logical unit: adoption plumbing, sram
   report, replay codec) over a single mega-dump of a whole wave — easier to
   revert and review.

**Commit**

- Conductor (or a child **explicitly** tasked to commit after the conductor
  already decided and verified) runs the normal git flow: stage intended
  paths, message that states why, `git status` clean of secrets/assets.
- Do not amend published commits or force-push unless the user asked for that
  recovery path.
- Analysis-only waves may produce **no** commit — notes go in handoffs /
  `docs/` updates the conductor authors after spot-check.

**Push**

- Push **`origin`** when the change set is verified and ready to share —
  typically after the user asks, or after a gated wave when the session goal
  was explicitly "land it" / "commit and push."
- Default caution: if the user only said "kick off agents" or "dig," leave
  results in the working tree (or local commits) until they ask to push.
- After push: confirm `git status` is clean vs `origin` for the shipped
  branch; report the commit range.

**Who may push**

| Actor | Commit | Push |
|-------|--------|------|
| Sub-agent (default) | No — unless brief says "commit locally in worktree for handoff" | **No** |
| Conductor after verify | Yes | Yes, when user/session goal asks to ship |
| User | Always | Always |

### What sub-agents must not do alone

- Claim "tests pass / adopted / matching gold" without the parent re-running
  the gate (or auditing a verify child's command output).
- Edit the verification harness without the conductor reviewing the diff.
- Name symbols without trace data or byte-level reasoning (goal-1.5 evidence
  rule).
- Silently swap the assigned task for an easier adjacent one.

### Task shapes that stay on the conductor

Not "don't use sub-agents ever" — "don't fire-and-forget these without the
top session owning the decision and reading the work":

- Emulator correctness and protocol debugging (APU upload capture class of
  problem) — failure modes reward "makes assumptions instead of looking
  things up." A child may dig; the conductor owns the fix call.
- Changes to the verification harness itself (`compare.nim`, `tests/`, the
  opcode table). **The referee does not get subcontracted.**
- Naming without evidence. Delegated names must arrive with trace data or
  byte-level reasoning attached.

### Multi-hour / long batch work

**Agents are for judgment, not waiting.** Do not keep a sub-agent alive across
a multi-hour sweep with wake-per-event monitors. Pattern:

1. Launch a **bounded deterministic driver** (fixed N, timeouts, clear
   output path under a git-ignored dir).
2. Arm a cheap dead-man watcher on the pid if needed.
3. At completion, **one** child (or the conductor) reads the logs and writes
   the summary / scorecard.

### Grok Build checklist

- Confirm the session model is the current frontier Build model (`grok-4.5`
  or successor) — do not silently stay on a stale alias if you intend 4.5.
- Sub-agents on; manager and workers are both Grok.
- `agnt` is optional dogfood / cross-harness only (next section).

---

## Optional: `agnt` (dogfood / cross-harness)

Day-to-day decompbound work does **not** need `agnt`. Native `spawn_subagent`
is the worker lane.

Keep `agnt` in the toolbox when:

- **Dogfooding** the wrapper itself (regression hunting, logging, multi-agent
  CLI behavior).
- **Cross-harness** work — another conductor (scriptorium, a non-Grok session,
  a shell script) needs to spawn a Grok worker without being inside Grok Build.
- **Headless batch** from outside a Grok TUI session.

```
agnt grok "task..."          # read-only (investigate/report) - DEFAULT
agnt -w grok "task..."       # write mode (full-auto edits in cwd)
agnt list                    # recent task logs (~/.agnt/tasks/)
```

Notes when you do use it:

- Run from the decompbound repo root (or the target worktree) so relative
  paths and the Makefile resolve.
- **Grok's read-only (plan) mode is broken headless** (2026-07-04): any
  tool-using task returns empty output. Use `agnt -w grok` with "analysis
  only, do not modify files" in the prompt; audit with `git status` after.
  Plan mode was permission-layer-only anyway (no kernel sandbox).
- Every run logs prompt/result/stderr under `~/.agnt/tasks/<timestamp>/`.
- **An empty result is a failed run, not a null finding.** A dead MCP server
  can make grok exit 0 with empty stdout — check stderr before believing it.
- Log which model id actually ran when comparing (CLI model names drift).
- NEVER run `grok login` — already authed; login spams popups.
- Same trust tiers and handoff contract as native sub-agents. Still never
  merge on self-report.
- Never `pkill -f agnt` on a shared machine (other projects use it too) —
  scope kills to exact loop/brief names.

---

## Prompt template

Delegated prompts must be self-contained — children get no conversation
history. Include:

```
You are working in the decompbound repo (Earthbound decompilation in Nim).
Read docs/goal.md and docs/goal-1.5.md first. Follow AGENTS.md copyright hygiene
(no ROM / extracted assets / script dumps committed).
Task: <one specific, bounded task>
Verification: <the exact command(s) that must pass, e.g. make test>
Report: <findings, diffs, evidence; end with a ```handoff``` block>
Do not modify: src/decompbound/opcodes.nim, compare.nim, tests/ (the referee)
  unless the conductor explicitly assigned a harness change and will review the diff.
Constraints: prefer nim r / nim check; no magic bytes without TODO + comment;
  parallel-safe — only touch the files listed in the task.
  Do not git push. Do not commit unless this brief explicitly says to commit
  locally after your verify bar; conductor owns origin/master.
```

---

## After every delegated run

- Verify against the harness yourself; **never merge on a worker's self-report.**
- `git status` audit on analysis-only runs (especially `agnt -w` analysis-only).
- If write work is accepted: **commit** (focused messages) and **push** only
  when shipping is in scope — see **Commit and push** above. A finished wave
  with green gates still sitting uncommitted is unfinished shipping, not
  unfinished engineering; say which when reporting status.
- If the change needs a **human eyeball** (play feel, visual, audio): add or
  update **`docs/human-verify.md`** (Run + Pass if). Optional one-liner in
  chat: `human-verify: <title>`. Never leave "please confirm in make play" only
  in a long reply.
- Surprising failures or successes → dated incidents in racha_notes model field
  notes (`AI/models/grok.md` / related model notes), per the calling-agent
  protocol. Routine runs stay in the session log and/or `~/.agnt/tasks/` when
  `agnt` was used.

---

## Quick chooser

```
Are you in Grok Build / Grok 4.5 as the long session?
  YES → spawn_subagent for workers. You are conductor + manager.
        Parallel write kids → worktree isolation.
        After green gates → commit (focused); push when shipping is in scope.
        Use agnt only if dogfooding or scripting outside the session.
  NO  → Cross-harness / headless batch → agnt -w grok with a full brief.
        Still apply trust tiers; still never merge on self-report.
```
