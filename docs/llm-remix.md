# LLM remix — regenerate the game's writing

**Status:** brainstorm / wishlist. A content romhack (`docs/post-decomp.md`
Family 1) powered by LLMs, and the sibling of the LLM-*plays* harness
(`docs/llm-plays.md`): one LLM *plays* EarthBound, the other *rewrites* it.

Use an LLM to remix EarthBound's writing — item descriptions, NPC dialogue,
enemy names, battle flavor text — generating new content **in the game's own
voice** and injecting it back as a patch. monofuel is already doing this by hand
(journal, 2026-07-04): riffing the "Trout Yogurt" quest into Caviar Yogurt,
Sardine Swirl, and the magnificent *Hákarl Yogurt with Brennivín Reduction*
("...the ammonia really opens up the palate" / Jeff's machine "smells like a
Viking died in here"). This track productizes that loop.

## Why it's exciting

- EarthBound's **writing is its soul** — quirky, deadpan, weird. It's the most
  fun thing to remix, and an LLM can riff on it endlessly.
- **Personalized / procedural:** a comedic pass, a grimdark pass, a version with
  your friends' names, or a *different* remix every seed.
- It's a **real creative deliverable** you'd actually want to play — not a demo.

## What it pulls (the grind that rides along)

The remix is impossible without the **scripts track** (`docs/scripts.md`),
which is exactly the point:

- **Decode** the text so the LLM sees the real lines to riff on.
- **Re-encode** the new text into EB's format — the round-trip
  (`encode(decode(bytes)) == bytes` for the *untouched* lines proves the codec;
  the new lines ride the same encoder).
- **Pointer tables — the technical crux.** EB's text is pointer-driven; a
  replacement of a *different length* shifts everything after it, so injection
  means **repointing** (or relocating text to free space and updating the
  pointer). This is the hard, real engineering the funny yogurt drags into
  existence.

## The pipeline

1. **Extract** the target text category (item descriptions, one NPC's lines…)
   via the scripts extractor — from the user's own ROM, locally.
2. **Prompt** the LLM with the constraints (below) + the original line + its
   context (what item/quest it's for).
3. **Generate** in-voice replacements.
4. **Validate** each: fits the length/box budget, control codes preserved,
   game function unchanged.
5. **Inject + repoint** into the text format; assemble a patch.

## The constraints the LLM must respect

This is what makes it a real problem, not just a chat:

- **Length / text-box budget** — SNES windows are small; overlong lines break
  layout (or force repointing to fit).
- **Control codes** — line breaks, waits, and **name/item/PSI substitution
  tokens** must survive (e.g. keep the `[name]` token, don't prose over it).
- **Mechanical function** — flavor changes, function doesn't: "Trout Yogurt
  heals ~30 HP" stays a ~30 HP heal; only the description gets the ammonia burn.
- **Voice** — a style guide / few-shot examples keep it EarthBound-deadpan, not
  generic-funny.

## Combos (this is where it gets great)

- **× Randomizer** (`docs/post-decomp.md`) → a game that's **differently written
  every seed**. Shuffle *and* rewrite.
- **× The Screenplay** (`docs/stretch-goals.md`) → preview the remix in the
  script browser before you patch.
- **× LLM-plays** (`docs/llm-plays.md`) → the *playing* agent **playtests** the
  *rewriting* agent's output: does the remixed text break any box/flag/quest?
  Two LLMs, one writes the game and one plays it.

## Legal

- The **new text is LLM/our expression** — but it's a **derivative work** (built
  on EB's characters, quests, structure). So: distribute as a **patch, never the
  ROM** (`docs/copyright-notes.md` §5), and it needs the user's own ROM.
- The **original** copyrighted text is still never committed; the remix contains
  only the *new* lines we generated (additive/replacement), which is the cleaner
  side of the patch line.

## Definition of done

- [ ] Round-trip the target text category (decode ↔ re-encode byte-exact for
      untouched lines).
- [ ] LLM generates in-voice replacements honoring length + control codes +
      function.
- [ ] Injection **repoints correctly** for variable-length text.
- [ ] A patch builds against the user's ROM and plays clean.
- [ ] **Flagship slice:** the Trout Yogurt quest, remixed end to end (item name +
      description + Electra's dialogue + Jeff's machine flavor) — straight from
      the journal brainstorm.

## Non-goals

- Rewriting *code* — this is content (text) only.
- Shipping the remixed ROM or the original text (patch + user ROM only).
- Perfect voice on the first pass — few-shot + a human/LLM editing loop is fine.

**Scope:** rides on the scripts track (extract + re-encode + repoint) + an LLM
content pipeline + patch output. The most creative face of the ROM-patch class.
</content>
