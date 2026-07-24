- (monofuel note) asked grok for a list of the major game checkpoints
- **LLM-play spine:** [grok_play_work.md](grok_play_work.md) Stream G grades Agent
  progress against these segments (metrics as referees, not a TAS queue).
- **Metric map (`story_percents.nim` / `checkpointSpineLine`):** hand-picked
  prologue gates (tg / pokey / knock / sunrise) plus soft bands for the long
  cart. Goal is **full Any% Glitchless coverage** below — expand metrics as
  freeplay seats land; soft **&lt;100** is fine until scene/flag RE for each
  **100**.

  | Speedrun segment (this doc) | Metric id(s) | Soft peak (freeplay) | 100 needs |
  |---|---|---|---|
  | Intro / Onett start | tg, pokey, pokey_knock, buzzbuzz, sunrise | tg100; knock80; buzz/sunrise open | sleep→knock freeplay; Buzz F12 |
  | Frank / Frankystein | frank | fr90 day continuous | boss kill flag |
  | Titanic Ant / Giant Step | giant_step | gs80 day continuous | cave mouth F12 |
  | Captain Strong | captain_strong | cs60–100 (leave soft) | true outdoor leave freeplay |
  | Pencil Eraser / Peaceful Rest / Twoson | peaceful_rest | pr70–90 | — |
  | Carpainter / Happy Happy / Paula | paula_rescue | pa90 soft | — |
  | Threed / Lilliput / Mondo Mole | lilliput_steps | li70 soft | sanctuary melody |
  | Jeff / Winters | winters | wi50 soft | Jeff join flag |
  | Mini Barf / Boogey Tent | *(none yet)* | — | RE + metric |
  | Master Belch / Saturn Valley | belch | be50 soft | Belch kill |
  | Dusty Dunes / Gold Mine | *(folded into fourside soft)* | — | optional split |
  | Dept. Store / Fourside | fourside | fo80 freeplay wall; fo90 soft seat | fo wall freewalk |
  | Mani-Mani / Moonside | *(none yet)* | — | RE + metric |
  | Monkey Cave | *(none yet)* | — | RE + metric |
  | Clumsy Robot / Monotoli | monotoli | mo70 soft | — |
  | Shrooom! / Rainy Circle | *(none yet)* | — | sanctuary metric |
  | Summers / Dalaam / Poo | summers | su70 soft | Poo join |
  | Pyramid / Kraken / Dungeon Man | *(none yet)* | — | RE + metric |
  | Master Barf / Deep Darkness / Tenda | deep_darkness | dd80 soft | — |
  | Starman Deluxe / Stonehenge | stonehenge | st80 soft | — |
  | Electro Specter … Fire Spring | *(bitpop only)* | bitpop≥550 soft98 band | per-sanctuary |
  | Ness’s Nightmare / Magicant | magicant | ma98 soft | dream F12 → ma100 |
  | Phase Distorter / Giygas | giygas | gi80 soft | phase F12 → gi100 |
  | Epilogue | *(none yet)* | — | credits/Mom flag |

- **Product freeplay honesty (2026-07-24):** day-leave Y poke grades only (teleports
  on night outdoor). Honest leave freeplay = `leave_day1_map` (pr70). fo wall
  sealed maxY~0x16B0; fo60+ via campaign seats. Soft ceiling ma98/gi80 until
  Magicant/Giygas dream-phase F12. Giant Step **80** = day-open west band
  (`$9887≥02`, GiantWestMaxX 0x08F8); cave mouth freewalk still needs human F12
  (d96 dig: indoor=0 from all day+knock seats / north wall).

# Checkpoints


**Notable checkpoints in EarthBound** (primarily from Any% Glitchless routes, with notes for broader use including 100%) are the major route segments, bosses, Your Sanctuaries, and story transitions that speedrunners use for routing, timing splits, and pacing.

These come directly from longstanding community resources like the SDA Knowledge Base Glitchless route and the Revised Glitchless notes on speedrun.com. Runners commonly treat these as natural segment boundaries (similar to LiveSplit splits), even if exact names vary slightly by runner or category.

### Core Speedrun Checkpoints / Route Segments (Any% Glitchless style)
These are the standard named sections used in route notes:

- **Intro / Onett start** — Meteor, Buzz Buzz, Starman Jr., Sound Stone acquisition
- **Frank / Frankystein** — Arcade sequence
- **Titanic Ant / Giant Step** — First Sanctuary
- **Captain Strong** — Police station (leaves Onett for Twoson)
- **Pencil Eraser / Peaceful Rest Valley / Twoson** — Apple Kid, etc.
- **Mr. Carpainter / Happy Happy Village / Paula rescue**
- **Threed Ambush / Lilliput Steps / Mondo Mole** — Second Sanctuary (often involves deathwarp setups)
- **Jeff’s Adventures in Winters** — Tessie, Brick Road, Sky Runner (Jeff joins)
- **Mini Barf / Boogey Tent**
- **Master Belch / Saturn Valley**
- **Mine Entrance / Dusty Dunes Desert / Gold Mine**
- **Dept. Store Spook / Fourside**
- **Evil Mani-Mani / Moonside**
- **Monkey Cave**
- **Clumsy Robot / Monotoli Building**
- **Shrooom! / Rainy Circle**
- **Summers / Dalaam / Shattered Man / Poo joins**
- **Pyramid / Kraken / Yellow Submarine / Guardian General / Dungeon Man**
- **Master Barf / Deep Darkness / Tenda Village**
- **Starman Deluxe / Stonehenge Base**
- **Electro Specter**
- **Plague Rat of Doom**
- **Thunder and Storm**
- **Diamond Dog / Lost Underworld / Fire Spring**
- **Remaining Sanctuary bosses** (Mondo Mole / Trillionage Sprout as needed in cleanup)
- **Ness’s Nightmare / Magicant**
- **Phase Distorter**
- **Giygas** (phases)
- **Epilogue** (often ends on talking to Mom or credits)

### The 8 Your Sanctuaries (Critical Progress Markers)
These are major story and routing checkpoints for both speedruns and 100% (each grants a melody for the Sound Stone):

1. Giant Step (Titanic Ant)
2. Lilliput Steps (Mondo Mole)
3. Milky Well (Trillionage Sprout)
4. Rainy Circle (Shrooom!)
5. Magnet Hill
6. Pink Cloud
7. Lumine Hall
8. Fire Spring (Diamond Dog)

Optimized routes sometimes collect them out of pure story order during cleanup.

### Useful Cutscene / Input Break Points (for pacing long runs)
From community guides (e.g., SheaFit’s list), these are good natural “checkpoints” where you can pause safely:

Intro, Runaway Five, R5 Bus from Twoson, Winters Intro, Tessie, Sky Runner to Threed, Belch Door, Bus to Desert, Runaway Five feat. Venus, Bus to Monkey Cave, R5 Bus from Fourside, Sky Runner to Winters/Summers, Dalaam Intro, Sailing/Kraken, Yellow Submarine, Tessie pt. 2, Lumine Hall Sanctuary, Venus concert, Magicant Intro, Wake Up, Robots, etc.

### Notes on Categories
- **Any% Glitchless** (most common competitive category) uses the structure above. Manipulation vs. no-manip variants affect early game (especially Onett) more than the later checkpoints.
- **Boogey%** and other short categories skip or heavily glitch many of these.
- **100% / Photo%** builds on the same backbone but adds all photos (“Fuzzy Pickles” spots), essentially all items, full exploration, and stricter completion requirements. Sanctuaries and major bosses remain the key structural checkpoints.

These are the points the community treats as the notable milestones for routing, timing, and discussing runs. Exact LiveSplit files can vary by runner preference, but the SDA/revised notes headings are the closest thing to a standardized list.
