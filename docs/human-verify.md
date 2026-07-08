# Human verify — stuff for your eyeballs

**This is your queue.** Not the chat. Agents put "please check this" **here** so you
can keep playing and only glance when you want. Chat may still mention a fix; if
it needed a human look, it must also land as a row below.

**You do not need to read long AI essays.** For each open item: run the command
(or hit the scene in-game), answer **looks right?** yes/no, F12 if no.

---

## How you use this (30 seconds)

1. Open this file when you feel like it (or after `git pull` / a big wave).
2. Work **OPEN** top-down, or pick any row that matches where you already are
   in the game (intro / Onett / battle / menu).
3. For each row:
   - Do **Run**
   - Compare to **Pass if**
   - If wrong → **F12** (state-screenshot), drop a one-liner under **Notes** or
     in chat, leave the box unchecked
   - If good → flip `- [ ]` to `- [x]` and optionally move the row to **Done**
4. New bugs you find while playing → add under **Found in play** (or chat "add
   this to human-verify"); agents file durable detail into `docs/issues.md`.

### Keys you already use

| Key | What |
|-----|------|
| `make play` | Run the game |
| F12 | Screenshot + state bundle (best bug report) |
| F10 | Per-scanline trace (when agents ask) |

ROM path: `bin/Earthbound (U) [!].smc` (your dump).

---

## OPEN — please check

Copy this template when adding a row (agents: always use it):

```markdown
- [ ] **Short title** · YYYY-MM-DD · `commit-or-branch`
  - **Run:** `make play` → one sentence where to go / what to press
  - **Pass if:** one sentence, visual/audio only
  - **Fail if:** one sentence (optional)
  - **Notes:** (human fills)
```

### Intro / title

- [ ] **Giygas red snow (intro static)** · 2026-07-08 · `d37e4bc` / `aa425e6`
  - **Run:** `make play` from cold boot → watch the Giygas "war" / static intro
  - **Pass if:** churning red/warped TV snow, not a coherent Giygas face tile grid;
    near-black fade should not go yellow/green mess
  - **Fail if:** clean face grid, or yellow/green noise at end of fade
  - **Notes:**

- [ ] **EarthBound logo glow (no 1px dark seam under letters)** · 2026-07-08 · `7935cfc`
  - **Run:** `make play` → wait for the EARTHBOUND logo (or load an F12 from that screen)
  - **Pass if:** soft glow touches the letter bottoms; no dark purple hairline under the orange letters
  - **Fail if:** obvious 1px gap under EARTH / OUND
  - **Notes:**

### Overworld / menus

- [ ] **No garbage / rainbow 1px line at top of screen** · 2026-07-08 · sprite Y wrap fix
  - **Run:** `make play` → overworld or battle (status windows visible)
  - **Pass if:** top scanline is clean (no multi-colored sparkle row)
  - **Fail if:** 1px garbage across the top (was Y=$E0 32px sprites wrapping)
  - **Notes:**

### Battle

- [x] **Mini Barf / normal battle BG + UI** · 2026-07-08 · mode-0 priority ladder
  - **Run:** `make play` → any normal battle with a busy animated BG (Mini Barf is fine)
  - **Pass if:** full psychedelic BG visible **and** HP/PP windows + command/dialogue on top
  - **Fail if:** BG covers the UI, or UI only with black/missing BG
  - **Notes:** confirmed Mini Barf 2026-07-08 (screenshot era + chat). Re-open if another battle type still wrong.

- [ ] **Victory / exp box not washed by battle BG** · 2026-07-08 · layer-gated color math
  - **Run:** `make play` → win a battle; look at “gained exp” window + HP boxes
  - **Pass if:** window chrome/text solid on top; purple BG stays *behind* (not blended over UI)
  - **Fail if:** diamond/pattern looks painted over the dialogue or status boxes
  - **Notes:** F12 `earthbound_20260708-191042.png` was the fail case.

- [ ] **Battle swirl color** · open
  - **Run:** enter a battle; watch the swirl transition
  - **Pass if:** swirl colors look right (not red-where-green / obviously wrong hue)
  - **Fail if:** clearly wrong colors vs memory of real hardware / reference
  - **Notes:**

- [ ] **Battle HP/PP status band** · open
  - **Run:** any battle; look at the HP/PP strip
  - **Pass if:** numbers and bar fully visible, not cut off or solid black
  - **Fail if:** band missing, black, or clipped
  - **Notes:**

- [ ] **Boss intro world-dim / bush sprite** · open
  - **Run:** trigger a boss intro that dims the overworld
  - **Pass if:** dim looks right; nearby sprites (e.g. bush) don't vanish wrongly
  - **Fail if:** missing bush / wrong dim
  - **Notes:**

### Audio

- [ ] **SFX "feel"** · open
  - **Run:** `make play` → menu blip, battle swirl whoosh, enemy defeated
  - **Pass if:** recognizable and not obviously wrong pitch/body
  - **Fail if:** Goods click / swirl / death still sound "off" in a way beeps don't
  - **Notes:**

### LLM-play (optional)

- [ ] **LLM watch mode doesn't freeze the window** · 2026-07-08 · `--watch-async`
  - **Run:** `make llm-ai` (or rebuild after pull) → watch ~30s of bedroom/house nav with qwen live
  - **Pass if:** game keeps animating while the model "thinks" (no multi-second hard freeze every tick); policy may still be dumb
  - **Fail if:** same old ~0.3s play / multi-second freeze loop
  - **Notes:** headless async proof already green (`frames_during_pending>0`). This row is windowed feel only.

- [ ] **LLM starts in bedroom, not your play save** · 2026-07-08 · `bin/states/llm/`
  - **Run:** `make llm-ai` → look at first screen
  - **Pass if:** Ness's house / bedroom (touch-grass start), **not** mid-game (e.g. Belch's base from slot4)
  - **Fail if:** continues your personal `slot1–4` progress
  - **Notes:** LLM states live under `bin/states/llm/`; play slots stay for `make play` only.

- [ ] **House decoration bot walks outside** · 2026-07-08 · `make llm-ai-display`
  - **Run:** `make llm-ai-display-loop` (or `make llm-ai`) on a spare monitor; watch ~1–2 min
  - **Pass if:** leaves bedroom → front door → **Onett exterior fades in** (not permanent black)
  - **Fail if:** stuck in bedroom/hall forever, or loads your Belch save
  - **Notes:** door force-blank hang fixed 2026-07-08 (APU timers in save-state). See `docs/issues.md`.

- [x] **make play: walk out front door yourself** · 2026-07-08 · force-blank dig
  - **Run:** `make play` → bedroom/house → walk out the front door **manually**
  - **Pass if:** Onett exterior fades in
  - **Fail if:** black after door (same as llm-ai) → confirms shared transition bug
  - **Notes:** cold-boot play was fine; llm-ai `--load-state` path was the broken one (timers).

### Optional one-shot commands (no full play session)

Only when an agent points you here for a **tool** check:

| Check | Run | Pass if |
|-------|-----|---------|
| Save report | `nim r src/tools/sram_info.nim "bin/Earthbound (U) [!].srm"` | Your party/money look sane |
| Script dump smoke | `nim r src/tools/script_dump.nim "bin/Earthbound (U) [!].smc" --offset 0x63040` | Prints something like `@INPUT YOUR COMMAND.` |
| Jukebox song | `nim r src/tools/sound_explore.nim --song 3 --seconds 2` (or jukebox app) | Audible music, not silence/halt |

---

## FOUND IN PLAY — new issues (human → agents)

Add a bullet when something is wrong **while you're playing**. No essay.

```markdown
- **YYYY-MM-DD** · where (intro / Onett / battle / menu) · one line what's wrong · F12 name if any
```

-

Agents: promote durable items into `docs/issues.md` (IN PROGRESS / OPEN) and
leave a short **OPEN** row here if you need a later eyeball on a fix.

---

## DONE (recent)

Move checked rows here so OPEN stays short. Prune freely.

- **Mini Barf battle BG + UI** · 2026-07-08 · mode-0 priority ladder

---

## For agents (do not make the human read this)

**Rule: never use chat-only "please test this."** If a human must look:

1. Append or update a row under **OPEN** with **Run** + **Pass if** only.
2. Optionally one line in chat: `human-verify: <title>` — link is this file.
3. When they mark done or confirm in chat, move to **DONE** or tick the box;
   update `docs/issues.md` FIXED/IN PROGRESS to match.
4. Prefer checks that fit **wherever they already are** in the game over "go
   start a new 20-minute path" unless unavoidable.
5. Mechanical gates (`make test`, ROM round-trip) are **not** human-verify —
   you run those. Human-verify is eyeballs and "does the game feel right."

**Anti-pattern:** long "verification plan" in a chat reply with five scenes to
visit. **Pattern:** one checkbox, one run line, one pass line.
