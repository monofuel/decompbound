- monofuel note: I asked grok for common 'earthbound glitches' might be useful for both testing accuracy of our emulator, and also potentially patching with compile flags.

---

**Yes**, there are several excellent resources for EarthBound (Mother 2) bugs and glitches, ranging from community wikis with broad lists to highly technical speedrunning documentation that explains the underlying mechanics.

### Best Starting Point: Comprehensive List
**WikiBound – List of glitches in the EarthBound series**  
→ https://wikibound.info/wiki/List_of_glitches_in_the_EarthBound_series

This is the best centralized, community-maintained list. It organizes glitches by game (EarthBound Beginnings/Mother 1, EarthBound/Mother 2, Mother 1+2 GBA port, and Mother 3) and includes descriptions, some mechanics, and notes on which ones were fixed in ports or prototypes. 

For **EarthBound specifically**, it covers:
- Condiment glitch (aka Rock Candy glitch)
- Walk through walls / Staircase glitch
- Skip Sandwich glitch
- Threed Tent / Check Area glitch
- Stat overflow glitch
- Shattered Man / Overworld Status Suppression (OSS) flag issues
- Diamondized glitch
- Simultaneous defeat glitch (EXP underflow)
- And various text/NPC glitches

It also has good coverage of the earlier *Mother* glitches (like Bread Crumbs out-of-bounds).

### Technical Explanations ("How They Work")
For deeper mechanics, especially the big sequence-breaking ones:

- **Speed Demos Archive (SDA) Knowledge Base** — EarthBound Tricks and Glitches  
  → https://kb.speeddemosarchive.com/Earthbound/Tricks_and_Glitches

  Excellent write-ups on the **Stairs Glitch** (ghosted/walk-through-walls state) and **Check Area Glitch**. It explains the single large map layout the game uses, timing windows for interrupting stair transitions (phone calls or low-HP warnings), save manipulation methods, and limitations like the invisible horizontal line barrier.

- **TASVideos GameResources – SNES/Earthbound**  
  → http://tasvideos.org/GameResources/SNES/Earthbound

  Very technical documentation of tricks used in tool-assisted speedruns, including:
  - Staircase glitch details
  - Check Area glitch (arbitrary memory reads from map-edge checks)
  - Walk through cliffs (tile passability exploits)
  - Stutter-walking (skipping triggers)
  - Item duplication nuances
  - RNG manipulation

These resources are gold if you want to understand *why* something breaks (memory layout, flag handling, inventory sorting, etc.).

### Notable Glitches (Quick Highlights)
Here are some of the most discussed ones:

| Glitch | What It Does | How It Works (Brief) | Notes |
|--------|--------------|----------------------|-------|
| **Condiment / Rock Candy Glitch** | Infinite stat boosts or item uses | Put food item (Rock Candy best) at bottom of inventory + have a condiment. In battle, use the food → only the condiment is consumed. | Most popular for power-leveling. Sugar Packets or Delisauce double the stat gain. Stats can overflow past 255. Fixed in GBA port. |
| **Stairs / Walk Through Walls Glitch** | Ghosted state — walk through walls, NPCs, cliffs, etc. | Interrupt stair transition with phone call or critical HP warning (or die on stairs + save manipulation). Exploits the single big map. | Major sequence break tool. Detailed on SDA. |
| **Check Area / Threed Tent Glitch** | Garbage text, slowdowns, warps, or debug menu | Repeatedly check specific corner spots (e.g. Threed circus tent bottom-right or Onett edge) while holding 2P controller buttons. | Can access debug menu for warps/events. Risk of crashes/corruption. |
| **Stat Overflow** | Stats wrap around | Most stats (except HP/PP) are stored in one byte (max 255). Exceeding it overflows to low values. | Enemies sometimes lack the cap. |
| **Sprite Overload Crash** | Game crash | Too many sprites loaded on screen at once (game stores ~22; 25+ causes issues). | Used in some TASes. |
| **Diamondized Glitch** | Visual oddity | Teleporting while a character is diamondized causes brief diamondization effect on wall collisions. | Mostly cosmetic/funny. |

Other mentions include Skip Sandwich glitch, Bike Bell glitch, Onett Barrier Skip, and various battle/text oddities (e.g. simultaneous party wipe causing EXP underflow).

### Visual Demos
**"Earthbound Glitches" by Son of a Glitch (YouTube)** — https://www.youtube.com/watch?v=LL5QkmEClvc  
Covers several in an accessible, demo-heavy format: Onett Barrier Skip, Skip Sandwich, Bike Bell, Sprite Overload, Diamondized, Shattered Man, Stairs, and Check Area glitches. Great companion to the text resources.

### Additional Notes
- Many glitches (especially bigger ones like Stairs and Check Area) are heavily documented by the speedrunning community (SDA, TASVideos, speedrun.com EarthBound leaderboards/guides).
- Some glitches were fixed or altered in the *Mother 1+2* GBA port.
- Classic sites like Starmen.net also have a "Tips and Tricks" section with older glitch notes.

Start with the **WikiBound list** for breadth, then dive into **SDA** or **TASVideos** pages when you want the "why" behind a specific glitch. Enjoy the jank — EarthBound's glitches are part of its charm!
