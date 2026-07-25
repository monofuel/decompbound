- monofuel note: these is output from grok
- review note (2026-07-24): offense/guts/accuracy/price numbers below
  cross-checked against our ROM item table (`$D55000`) — all ✅ except the
  Sword of Kings offense (see its section). Drop rates, sources, and the
  IQ-65 repair requirement remain 🟡 community. The check also pinned three
  new item-table fields (`+$1F` offense, `+$21` guts, `+$22` miss/16) — see
  `docs/decompilation.md`.

# EarthBound - Best Weapons for the Party

*Technically Best vs "Total Pain in the Fucking Butt"*

---

## Ness (Bats)

### Technically Best
**Gutsy Bat**
- +100 Offense
- **+127 Guts**
- Normal accuracy (15/16)
- 1/128 drop from Bionic Kraken (Cave of the Past)

This is the one. The Guts bonus turns Ness into a SMAAAASH machine. Consistent hits + constant criticals = best overall damage output.

**Very close second (and way less painful):**  
**Legendary Bat** (+110 Offense, normal accuracy)  
Free present box in the Cave of the Past. Pure offense king among reliable bats.

### Total Pain in the Fucking Butt
**Casey Bat**
- +125 Offense (highest in the game)
- Hits only **25%** of the time
- Dropped by Master Barf

When it connects it hits like a freight train. The rest of the time you'll want to throw your controller. Fun for Instant Wins and memes. Terrible for actual play.

---

## Paula (Frying Pans)

### Technically Best (depending on playstyle)

**Holy Fry Pan** (Reliable Physical)
- +80 Offense
- +10 Guts
- Normal accuracy
- Buyable in Lost Underworld for $3480

Best pure offense pan. If you actually bash with Paula sometimes, this is the one.

**Magic Fry Pan** (Crit / Survival focused)
- +50 Offense
- **+100 Guts**
- Misses 25% of the time (12/16 accuracy)
- 1/128 drop from Chomposaur (Lost Underworld)

Lower offense and worse accuracy, but the massive Guts is excellent for survival (enduring lethal hits) and occasional big SMAAAASHes. Preferred by a lot of people who mostly use her for PSI.

### Total Pain in the Fucking Butt
Farming the Magic Fry Pan when you already have the Holy Fry Pan and don't really need it. Chomposaurs are annoying and the drop rate is pure suffering.

---

## Jeff (Guns)

### Technically Best
**Gaia Beam**
- +125 Offense
- Perfect accuracy (as all of Jeff's guns)
- Repair the **Broken Antenna** (1/128 drop from Uncontrollable Sphere in Lumine Hall)
- Requires Jeff IQ 65 to repair

Highest offense gun in the game. Clean, consistent, and strong.

**Excellent and free alternative:**  
**Moon Beam Gun** (+110 Offense)  
Gift box in Fire Spring. Almost as good and requires zero farming.

### Total Pain in the Fucking Butt
Farming Uncontrollable Spheres for the Broken Antenna. They're not hard, but the 1/128 rate + having to go repair it can feel like a personal insult from the game.

(Also note: A lot of veterans just ignore equipped guns late-game and spam Multi Bottle Rockets / Heavy Bazooka instead, which often out-damage even the Gaia Beam.)

---

## Poo

### Technically Best
**Sword of Kings**
- +30 Offense
- 1/128 drop from Starman Super (Stonehenge Base)

This is literally the only weapon in the entire game that actually *raises* Poo's offense. Everything else (yo-yos, slingshots) lowers it.

Without it, Poo just uses his fists.

### Total Pain in the Fucking Butt
**The Sword of Kings itself.**

It is *the* most infamous 1/128 drop in the game. Starman Supers are a pain to farm efficiently, the drop rate is evil, and +30 Offense is honestly not that huge of an upgrade. Many people finish the game with bare fists and never look back.

The Sword of Kings is the **"free space" on the bingo board** of any
playthrough — the 1/128 pain you don't decide on, you just budget for. If
you're doing a run, you're grinding Stonehenge. It's a tax.

- ✅ **ROM oddity — SOLVED (2026-07-24):** the item table has TWO stat
  columns: `+$1F` for everyone else and **`+$20` for Poo specifically,
  signed**. The sword's Poo column reads **+30** — community was right.
  The yo-yos are the proof: their `+$20` bytes are exact two's-complement
  negatives of their `+$1F` offense (−6/−46/−54), which is the ROM-level
  mechanism behind "everything but the Sword of Kings lowers Poo's offense."
  Live-verified: Bracer of Kings `+$20`=30 ↔ Poo's real equipped−base
  defense = exactly +30. See `docs/decompilation.md`.

---

### Quick Recommendation Summary

| Character | Best Realistic Choice          | Absolute Peak (if you hate yourself) |
|-----------|--------------------------------|--------------------------------------|
| **Ness**  | Gutsy Bat or Legendary Bat     | Casey Bat                            |
| **Paula** | Holy Fry Pan                   | Magic Fry Pan                        |
| **Jeff**  | Gaia Beam or Moon Beam Gun     | —                                    |
| **Poo**   | Sword of Kings or Fists        | Sword of Kings (the grind)           |

The real "best" weapons are usually the ones that don't make you want to quit the game.
