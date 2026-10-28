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
| F12 | **Screenstate** (screenshot + embedded save-state; best bug report) → session `f12/` + `~/Pictures` mirror; archived to `secret/screenstates/` on exit |
| F10 | Per-scanline trace (when agents ask) |

ROM path: `bin/Earthbound (U) [!].smc` (your dump).

---

## OPEN — please check

- [ ] **Pocket Jukebox: playback and three input methods** · 2026-10-27 · `monofuel/jukebox`
  - **Run:** `make jukebox-app ARGS="--song:3"` in the usual development shell.
    Click tracks, browse with arrows, use Enter/Space/S, skip and adjust volume.
    Repeat with Paddy: D-pad/stick, bottom/right face buttons, Start and L1/R1;
    unplug/reconnect the controller. Resize, then put the window in the background.
  - **Pass if:** music is continuous without clicks/stutters, pause/resume and
    stop react promptly, track changes leave no previous song playing, held
    buttons do not repeatedly toggle playback, selection stays visible, mouse
    clicks match the resized picture, and background music continues. Controller
    disconnect/reconnect leaves mouse and keyboard usable.
  - **Theme check:** cream-framed navy panels, a red/gold cassette, and pink play
    button should remain readable when selecting tracks and hovering controls.
  - **Hotplug retry:** unplug and reconnect the physical controller while music
    plays. Audio and mouse/keyboard should continue; the controller should work
    again after reconnecting. The locked Paddy fork fixes the old device-path
    lifetime and disconnect handling; a virtual-controller cycle passes headlessly.
  - **Volume check:** move Knobby slider 4 while music plays. The displayed
    percentage should follow the jukebox's mixer stream even when unfocused.
    In-app volume buttons should change that same stream. Mixer mute should be
    shown, and other applications' mixer settings should stay unchanged.
  - **Notes:** monofuel confirmed the original player works; the EarthBound-inspired
    recolor needs a fresh visual check. Numeric labels are intentional. Track 4 may be silent; use 1/3/11/76
    for the initial listening check. Automated tests use silent output and synthetic
    gamepad states; real sound quality and controller behavior need this check.

- [ ] **RG DS Plus through mono-retro-player** · 2026-10-27
  - **Run:** Choose Decompbound in the handheld's mono-retro menu. Play, press L2
    to switch screens, hold Select+Start for two seconds to return, then relaunch.
    Make an in-game save and verify it survives another exit/relaunch.
  - **Pass if:** the game starts on the bottom screen with the top black, remains
    sharp when switched, all SNES buttons respond, sound is clean and correctly
    paced, and exiting restores the launcher. Device saves remain separate from
    desktop saves.

- [ ] **Libretro core in mono-retro's desktop player** · 2026-10-27 · `master`
  - **Run:** `make libretro-play` ([setup and options](libretro.md#mono-retro)).
    Boot, use a gamepad for all SNES buttons, make an in-game save, exit, and
    reopen with the same save directory.
  - **Pass if:** graphics and colors match ordinary desktop play, controls
    respond, and the in-game save survives restart. Audio depends on the
    installed frontend build and is a separate check.
  - **Notes:** monofuel confirmed manual launch/play works. In-game save/reload
    remains to be checked.

- [ ] **Integrated player: pause, screenshots, speed and audio** · 2026-10-27 · `master`
  - **Run:** `nim r src/tools/play.nim --no-vsync "bin/Earthbound (U) [!].smc"`.
    Pause with Space, hold Esc briefly, release it, and take an F12. Resume,
    use `=` to fast-forward and `-` to return to 1x. Resize below 256x224.
    Repeat with `--no-audio`.
  - **Pass if:** pause and hold feedback remain visible; Esc requires one second
    to quit; the F12 contains the game without the player toast; a small window
    shows the whole picture; music returns at normal speed after fast-forward;
    muted play keeps the same game speed.

- [ ] **Baseline overworld sprite preview**
  - **Run:** `nim r src/tools/sprite_preview.nim 437 0 0`; open
    `extracted/view/sprites/437-0-0.png`. Repeat with phase 1 and direction 2.
  - **Pass if:** Compare with Ness in ordinary overworld play: colors, tile
    assembly, facing, and walking-frame shape match without stray tile rows.
    This uses the baseline palette; scene lighting and special effects are
    outside the check. Keep generated images local.

- [x] **Desktop: `make play` after the GL 2.1 blit** · 2026-09-19 · `pi3-perf` · verified 2026-09-19: Skyrunner segment, audio, graphics and framerate good
  - **Run:** `make play`, then drag the window to a non-multiple size
  - **Pass if:** identical picture at the default 768x672 (3x); at odd sizes the game stays pixel-exact with bigger black bars instead of a fractional stretch; F2 saves slot 1, F4 loads it; holding Esc for a second quits and the terminal prints "Esc held: quitting"
  - **Fail if:** shader error at startup, blurry or stretched picture, Esc tap quits
  - **Notes:** integer scaling is deliberate (matches RetroArch on gammapi). `make llm-ai-display` once, to see the other glblit user still opens.

- [ ] **gammapi: fullscreen 1x from EmulationStation** · 2026-09-19 · `pi3-perf`
  - **Run:** ES → Custom → decompbound
  - **Pass if:** title screen 256x224 dead-centre on the 320x240 panel (32 px black sides, 8 px top/bottom), crisp pixels, no desktop or ES visible behind it
  - **Fail if:** windowed, stretched, off-centre, decorated, or ES still on top

- [ ] **gammapi: case buttons** · 2026-09-19 · `pi3-perf`
  - **Run:** new game → walk all four ways, open the menu (A), close it (B), L1/L2 and R1/R2, Select, Start
  - **Pass if:** every input responds; both shoulder pairs act as L/R
  - **Fail if:** any dead button, or a press that reaches ES instead of the game

- [ ] **gammapi: audio** · 2026-09-19 · `pi3-perf`
  - **Run:** title screen 60 s, then walk Onett 60 s (earbuds or the jack)
  - **Pass if:** music continuous, no crackle or drop-outs
  - **Fail if:** silence (try `ALSOFT_DRIVERS=pulse` in the launcher), crackle, or slow-motion music

- [ ] **gammapi: edge buttons + clean exit** · 2026-09-19 · `pi3-perf`
  - **Run:** F2 (middle edge button) → walk away → F4 (second from left); then hold the far-right edge button (Esc) for a second
  - **Pass if:** F4 snaps you back; Esc returns to the ES menu; `~/decompbound/play_stdout.log` shows "saved:" and "end screenstate:"; relaunch and the in-game save is there
  - **Fail if:** no snap-back, Esc ignored, or SRAM lost on relaunch

- [ ] **Lilliput cave mouth: black column** · 2026-08-18 · `master`
  - **Run:** drag-drop `earthbound_20260818-005541.png` (or `005543` /
    `005556`, or July `20260707-014807` / `014825` / `014835`) onto
    `make play`. Same cave as 2nd sanctuary / Mondo Mole.
  - **Pass if:** no 8px black vertical strip; grass and cliff are solid
  - **Fail if:** a screen-fixed black column cuts the cave / path
  - **Notes:** two runs, six F12s. Ticket: `docs/issues.md` OPEN
    “2nd sanctuary black column”. Do not commit the PNGs.

Copy this template when adding a row (agents: always use it):

```markdown
- [ ] **Short title** · YYYY-MM-DD · `commit-or-branch`
  - **Run:** `make play` → one sentence where to go / what to press
  - **Pass if:** one sentence, visual/audio only
  - **Fail if:** one sentence (optional)
  - **Notes:** (human fills)
```

### Harness / eval

- [ ] **`make llm-ai-prologue` hands the bot day Onett** · 2026-08-16 · TAS prefix
  - **Run:** `make llm-ai-prologue` — wait through the gold movie (~13 min at 1x), then watch the bot
  - **Pass if:** after the prefix, Ness is in **day** Onett with the Sound Stone and the bot is driving (not frozen on title)
  - **Fail if:** stuck in bedroom/night, no Sound Stone, or TAS desync
  - **Notes:** Prefix is `20260816-223148`. `--pilot tas` is still mock Lua, not this movie.

- [ ] **`make play-cont` resumes the last F12** · 2026-08-16 · TAS chain
  - **Run:** `make play-cont` (should load sunrise snap `224434` or newer)
  - **Pass if:** you spawn at that seat (day, south of Pokey's house) and a new RECORDING line appears
  - **Fail if:** title / bedroom / wrong room
  - **Notes:** Close the window to write the next end snap.

- [ ] **llm-ai window still opens after -d:noWindow gating** · 2026-07-28 · eval loop Phase 1
  - **Run:** `make llm-ai-scripted` → let it run ~30 seconds
  - **Pass if:** the GL window opens, title updates with frame count, game
    visibly plays (the noWindow compile gate must not affect default builds)
  - **Fail if:** no window, black window, or a crash at startup
  - **Notes:**

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

- [ ] **Live MCP co-pilot in `make play`** · 2026-07-24 · Goal 5 fold-in
  - **Run:** `make play` → confirm startup line `decompbound MCP on http://localhost:4343/mcp`; window + sound OK; in another terminal `curl -s -X POST http://localhost:4343/mcp -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"hv","version":"0"}}}'` then tools/call `get_party_vitals` (or use an MCP client)
  - **Pass if:** response has `source":"live-wram"`, sane HP for Ness matching the on-screen party; game audio/window unaffected
  - **Fail if:** crash/hang on launch, no MCP line, wrong HP vs game, or audio/window broken
  - **Notes:**

- [ ] **Sprite behind object: clean occlusion + swirl tint** · 2026-07-19 · `ppu overlayForegroundBg preSpriteComposite`
  - **Run:** `make play` → walk Ness **behind** a building / store counter; then start a battle and watch the **swirl** with a character partly behind an object
  - **Pass if:** the object covers the sprite with **no color/brightness seam**; during the swirl the part of the object over the sprite **fades/tints the same** as the rest of that object
  - **Fail if:** a visible seam where object overlaps sprite, or that patch stays full-bright / un-tinted during the swirl
  - **Notes:**

- [ ] **Auto-screenshots now ON by default** · 2026-07-09 · `play.nim autoShot=true`
  - **Run:** `make play` → play for ~20s, then check `bin/autoshots/`
  - **Pass if:** `shot_NNNN.png` files appear every ~5s and the periodic stutter is tolerable
  - **Fail if:** no shots appear, or the ~5s write-stutter is too disruptive (F11 turns it off)
  - **Notes:**

- [ ] **No garbage / rainbow 1px line at top of screen** · 2026-07-08 · sprite Y wrap fix
  - **Run:** `make play` → overworld or battle (status windows visible)
  - **Pass if:** top scanline is clean (no multi-colored sparkle row)
  - **Fail if:** 1px garbage across the top (was Y=$E0 32px sprites wrapping)
  - **Notes:**

### Captures wanted (not pass/fail — data the agents need)

- [ ] **Battle command-menu screenstate** · 2026-07-11 · battle skill RE
  - **Run:** `make play` → enter any battle → at the **command menu (Bash/Goods/PSI/Defend visible)**, press **F12**. One more F12 mid-attack + one at the victory "you won / EXP" screen if easy.
  - **Pass if:** the screenstate(s) land in the session `f12/` (auto-mirrored to `~/Pictures`); note the time
  - **Notes:** the only existing battle fixtures are dead (flag set but not mode-0, no reachable menu). A real command-menu state unblocks the reusable `winBattle` skill — foundational for every fight. Addresses already found: $4DBA in-battle, $5D60 result, party $4DC8.

- [ ] **Prologue-night breadcrumb: Pokey talk → home → knock → Buzz Buzz → sunrise** · 2026-07-11 · knock/buzz/sunrise ground truth
  - **Run:** `make play-pokey` (starts at the door) → walk the WHOLE prologue night: up to Pokey, back **home + sleep** (Pokey knocks), back up to the **meteor / Buzz Buzz**, pick up **Picky**, escort to the **Minch house**, watch the **Buzz Buzz death scene**, exit → **sunrise**. Recording is automatic; F12 at each major beat is a bonus.
  - **Pass if:** the session `.tas` covers the run; mention the time range
  - **Notes:** this is the §4-style ground truth for pokey_knock/buzzbuzz/sunrise metrics + seeds — same playbook that cracked pokey (I mine the trail + WRAM flag diffs from the replay). Story flags can't be RE'd reliably without it (models confabulate EB beats).
  - **Update 2026-07-11:** the bot now drives the whole route UP TO the bedroom on its own (walk home → talk the door cop → enter → reach the bed spot; probe_knock grades knock 0→80). The one beat it can't do is **sleeping in the bed to trigger the Pokey knock** — from the cop-warp bedroom the bed is inert to the bot (walking into it just opens the overworld menu; no "sleep?" prompt). So the single highest-value thing in your run is **actually going to sleep and letting Pokey knock** — that gives me the before/after WRAM pair to pin the knock flag (100 tier). Everything after (Buzz Buzz, Picky, sunrise) is bonus ground truth for the next milestones.
  - **Update 2026-07-24:** Agent night Onett reaches **captain 60 / paula soft 40** continuous; leave soft **captain 70** = later `$99F2=C4` alone; **captain 100** = later-story + outdoor **py≥0x0500** (day-leave map soft; F12 210416). Night freewalk still sticks at **py=0x02A0** — need **sleep→day** for true free-play leave without campaign day-map seat. Magicant/Giygas **100** still need dream/phase F12s (soft ceiling ma98/gi80).

- [ ] **Late-game F12: Magicant entry + Cave of the Past / Giygas** · 2026-07-24 · endgame referees
  - **Run:** From a late save (Poo in party ok) play into **Magicant** (post-sanctuaries) → F12 inside Magicant; if easy, F12 again at **Cave of the Past** or first **Giygas** phase.
  - **Update 2026-07-24:** Soft ceiling **magicant 98 / giygas 80** holds continuously after bitpop threshold fix (550; 0xFF sentinel clear on first joy). Full F12 corpus (542) never exceeds ma98 — **no dream F12 on disk**. Flagdiff high-bp overworld ≠ dream phase. Product campaign seats soft98 from fo80 free+Poo (`soft98_from_fo80paula`); freewalk cannot invent soft98 bitpop. Recent F12 scan (200 large) peakMa=98 peakGi=80 peakBp=683 still dream=false.
  - **Pass if:** F12s land under `~/Pictures/Screenshots/` with ebSt; note filenames in Notes
  - **Notes:** soft ceiling automated. Only **100** needs true Magicant dream / Giygas phase flag bits.

- [ ] **Day-1 F12: Giant Step cave mouth / Titanic Ant** · 2026-07-24 · giant_step 100 + freewalk cave
  - **Run:** Day Onett after Frank (or any day leave map) → walk to **Giant Step** mountain/cave entrance → F12 **outside cave mouth** and again **just inside** if you enter.
  - **Update 2026-07-24 (d94):** Soft **gs80** landed as day-open west band (`$9887≥02` + police west). Full F12 scan (542) has **no** Giant Step cave indoor seat (indoor hits are houses only). Bot cannot freewalk into cave from giant_approach even with leave_day1 day flags.
  - **Update 2026-07-24 (d110):** Day outdoor freeplay now reaches **gs80 continuous** from `post_knock_outdoor` (no campaign giant seat; AgentFrank→AgentGiant + day flags). Cave mouth still blocked (indoor=0, minY~0x0251). An F12 **inside** the Giant Step cave / at Titanic Ant still unblocks **gs100**.
  - **Pass if:** F12(s) with ebSt under `~/Pictures/Screenshots/`; mention filenames
  - **Notes:** unblocks giant_step **100** (melody / indoor cave) and true freeplay past gs80.


- [ ] **Breadcrumb trail: house → Pokey at the meteor** · 2026-07-09 · pokey_pct ground truth
  - **Run:** **`make play-pokey`** → you spawn at Ness's front door on the meteor night (bot fixture, your personal slots untouched). Just walk the real route (south → west along the paths → the winding climb) to Pokey and **talk to him**, then close the window. Recording is automatic now — no keys to remember.
  - **Pass if:** a fresh `.tas` + `_start.state` pair lands in `bin/sessions/<session>/` (auto-archived to the secret repo on exit); say roughly when you did it
  - **Notes:** replayable headlessly to pin the exact corridor + Pokey's coords. Audited all 365 secret states: no house→meteor trail exists. Static map decode found a door→north corridor via the WESTERN hill (exit at ~(0x06C0,0x00B0)) — your run confirms/corrects it.
    2026-08-16 cadence-emu trail: [sunrise TAS](2026-08-16-sunrise-tas.md) F12s `223656` (path) → `223935` / `224058` (crater).

- [ ] **Session capture dirs + auto-archive** · 2026-07-10 · play.nim sessions
  - **Run:** `make play` → take an F12, walk a bit, close the window; check `bin/sessions/<ts>/` and `../decompbound_secret/sessions/<ts>/`
  - **Pass if:** the session dir holds the `.tas`+`_start.state` pair and `f12/` screenstate; the F12 also mirrored to `~/Pictures/Screenshots`; on exit the terminal prints "session archived: N file(s)" with replay pairs in `secret/sessions/<ts>/` and the screenstate in `secret/screenstates/` (flat)
  - **Fail if:** captures land in old paths, no archive line on exit, or launch/exit regresses
  - **Notes:** autoshots stay in `bin/autoshots` (scratch, not archived — replay_seek regenerates moments).

- [x] **Remake bedroom.state with Fast text** · 2026-08-16 · llm-play fixture
  - **Run:** cold-boot `make play` (no load-state). New file. Name the party. Set text speed **Fast**. Reach Ness's bedroom. F12 or Ctrl+1, then copy that snapshot over `bin/states/llm/bedroom.state` (and `bin/states/game_start.state` if it is still the seed).
  - **Pass if:** a fresh bedroom fixture exists, in-game text is Fast, and `make play` / `make llm-ai` from that path skip naming with Fast text
  - **Fail if:** the old medium/slow file is still the start seat
  - **Notes:** Installed 2026-08-16 from F12 `earthbound_20260816-183333.png` (standing bedroom). Old medium file kept as `bin/states/llm/bedroom_medium.state`. See [Fast-text TAS](2026-08-16-fast-text-tas.md).

- [ ] **Always-on input recording doesn't hurt play feel** · 2026-07-09 · play.nim recording default
  - **Run:** `make play` normally for a few minutes; load a slot mid-session
  - **Pass if:** no new stutter/lag; terminal shows a RECORDING line at boot and after each state load; `.tas` files appear in `bin/replays/`
  - **Fail if:** any hitch that wasn't there before, or recording spam interferes
  - **Notes:** sparse joy1 deltas + one small state snapshot per segment; F7 toggles off.

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

- [ ] **Battle swirl color** · 2026-07-09 · COLDATA hardware mapping restored
  - **Run:** enter a normal battle; watch the swirl transition
  - **Pass if:** normal swirl is grey again (and boss/special swirls their usual colors)
  - **Fail if:** red-where-grey or otherwise wrong hue
  - **Notes:** monofuel caught the morning "R/B-swap fix" turning the grey swirl red — the old code was a double swap that was net-correct. Now hardware-truth ($2132 bit5=R/bit6=G/bit7=B, BGR555 pack) with `tests/test_coldata.nim` locking it. OBJ spotlight gating (Runaway Five row above) is separate and kept.

- [ ] **Runaway Five / stage spotlight dim** · 2026-07-09 · OBJ math window gate
  - **Run:** `make play` → Chaos Theater Runaway Five intro (or any advantage-win spotlight)
  - **Pass if:** band under the two blue beams is full palette (not crushed purple); outside beams + party dim; contrast looks like stage lighting
  - **Fail if:** whole scene / all sprites uniformly too dark (math applied inside the color window)
  - **Notes:** F12 `earthbound_20260709-005030.png` was the fail (ungated OBJ subtract). CGWSEL=$20 math-outside + CGADSUB=$B3 + HDMA WH beams.

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

- [ ] **Inn sleep / battle start no longer locks; tempo unchanged** · 2026-07-10 · `347ab9d` APU $214x catch-up
  - **Run:** `make play` → sleep at an inn; enter a couple of battles; listen to steady overworld/battle music
  - **Pass if:** no lockup on inn-sleep or battle-start; transition SFX correct; steady music tempo sounds normal (NOT half-speed or sped-up)
  - **Fail if:** any lock, wrong/ghost SFX on sleep, or music tempo drifts
  - **Notes:** fix ticks the SPC extra only during the sound-handshake burst (self-limiting); deterministic repro locked by test_apu_handshake_derail.



- [ ] **SFX "feel"** · open
  - **Run:** `make play` → menu blip, battle swirl whoosh, enemy defeated
  - **Pass if:** recognizable and not obviously wrong pitch/body
  - **Fail if:** Goods click / swirl / death still sound "off" in a way beeps don't
  - **Notes:**

### LLM-play (optional)

- [x] **Bot walks to Pokey at the meteor and talks to him** · 2026-07-10 · `9861803` pokey_pct 0→100
  - **Run:** `make llm-ai` (pokey scenario) → watch the bot leave Ness's house and climb to the meteor
  - **Pass if:** it legitimately walks the route (south → west → climb → ridge) and opens the Pokey dialogue — pokey_pct reaches 100
  - **Notes:** ✅ **CONFIRMED LIVE by monofuel 2026-07-10** — bot reaches Pokey and talks to him. Validates the headless 0→100 (POKEY_ACHIEVED@2920) in the real windowed harness.

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
| ROM-backed audio bootstrap | Render songs 1 and 3 with `nim r src/tools/sound_explore.nim --song N --seconds 2`, then listen to the resulting local WAVs; also select both in the jukebox app. | Both produce music without a halt after removing the captured bootstrap fallback; confirm by ear, not merely nonzero sample counts. |

---

## FOUND IN PLAY — new issues (human → agents)

- **2026-10-27** · Pocket Jukebox · unplugging a controller crashed the app;
  stack trace unavailable. Updated the Paddy pin and verified virtual-device
  removal/reconnect. Physical-controller retry remains in the jukebox row above.

Add a bullet when something is wrong **while you're playing**. No essay.

```markdown
- **YYYY-MM-DD** · where (intro / Onett / battle / menu) · one line what's wrong · F12 name if any
```

- **2026-08-18** · Lilliput / 2nd sanctuary cave mouth · 1-tile black
  vertical column, two runs · F12 `earthbound_20260818-005541.png`
  `005543` `005556` and `earthbound_20260707-014807.png` `014825`
  `014835` (Pictures only)

Agents: promote durable items into `docs/issues.md` (IN PROGRESS / OPEN) and
leave a short **OPEN** row here if you need a later eyeball on a fix.

---

## DONE (recent)

Move checked rows here so OPEN stays short. Prune freely.

- **Windowed TAS replay (`make play-tas`)** · 2026-08-16 · cadence emu
  - Confirmed: [sunrise TAS](2026-08-16-sunrise-tas.md) `20260816-223148`
    replays bedroom → leaving Pokey's house / sunrise. No desync.
  - 2026-08-17: chain replay in a second window while live play was at
    Giant Step — **no TAS bugs**; Onett delay = deaths on the tape.
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
