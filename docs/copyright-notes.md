> **The practical rule for this repo lives in [`AGENTS.md`](../AGENTS.md) →
> "Copyright hygiene".** Short version: never commit ROMs, ROM-extracted assets
> (graphics/audio/text), or memory/state dumps that embed them; reverse-engineered
> code is our own new expression and is fine. This doc is the *why* behind that.

- grok suggested copyright rules around git / CI

- we are not lawyers take with a grain of salt

--- 

**No, this is not legal advice**—copyright law is jurisdiction-specific (you're in the US, so primarily federal copyright + DMCA), fact-specific, and enforcement is inconsistent. Courts haven't directly ruled on most modern decomp projects, so everything is based on precedents, statutes (e.g., 17 U.S.C. §§ 107, 117, 1201), and observed practice. Consult a copyright attorney for your specific situation. What follows is a synthesis from reliable sources on US law.

### 1. Exact ROM byte copy = piracy (clear infringement)
- Distributing, uploading, or sharing an exact ROM (or any verbatim copy of the game's code/assets) is unauthorized reproduction/distribution of a copyrighted work → illegal under 17 U.S.C. § 106.
- Even if you own the cartridge, downloading a ROM (instead of dumping it yourself) is generally infringement. The archival/backup right in § 117 allows *you* to make a personal backup of software you own, but it does **not** authorize downloading someone else's copy or sharing yours.
- Nintendo and others aggressively enforce this (e.g., lawsuits against ROM sites resulting in millions in damages).

### 2. Decompilation projects: Grey area, but the *clean* source-code repos are generally treated as legal (or at least not pursued)
Decompilation/reverse engineering itself is **not** automatically piracy. Key protections:

- **Fair use (§ 107)** and reverse-engineering precedents:
  - *Sega v. Accolade* (9th Cir. 1992): Disassembly/decompilation to access functional elements (for compatibility) was fair use. Intermediate copying was allowed because it was necessary and the final product used no protected code.
  - *Sony v. Connectix* (9th Cir. 2000): Reverse-engineering the PlayStation BIOS to make an emulator was fair use.
  - DMCA § 1201(f) has a narrow interoperability exception for reverse engineering lawfully obtained copies.

- How real decomp projects (SM64, Zelda 64/OoT, etc.) operate legally in practice:
  - Repos like **n64decomp/sm64** contain only the reverse-engineered C source, build tools, and *instructions*. They explicitly **do not include assets**; you must provide your own legally dumped baserom.<version>.z64 to extract assets during build. The repo itself has no Nintendo-copyrighted material.
  - The decompiled code is treated as *new expression* of the functional/ideas (not a direct copy of Nintendo's source or assets). It recreates behavior but is transformative.
  - Nintendo has DMCA'd *derivative ports* that bundle assets/prebuilt ROMs or advertise playable versions, but the pure decomp repos (n64decomp org, etc.) have existed openly for years without being taken down.

- **Limitations / risks**:
  - If the decomp includes any verbatim assets, music, graphics, or leaked code → infringement.
  - Distributing a built, playable ROM or port → almost certainly infringement (Nintendo has sued over this).
  - DMCA anti-circumvention if you bypassed any tech protection (rare for old carts, but relevant for newer games).
  - EULAs often prohibit it, but courts are mixed on enforceability for fair-use RE.
  - Academic view: Decomps are arguably infringing as they capture the "totality of creative labor," but should qualify as fair use for preservation/accessibility when games become unavailable.

**Bottom line**: Hosting/distributing a clean decomp source repo (no assets, requires user ROM) is widely viewed as legal under fair use + RE precedents and has been tolerated. Using your own dumped ROM to build/test privately is fine. Anything that lets someone play without owning the original crosses into piracy.

### 3. Save state dumps (savestates)
- **Regular save files** (in-game SRAM/EEPROM saves): Generally **not** considered infringing when distributed. They are mostly player-generated data (progress, names, etc.), not creative expression owned by the developer. Sites have hosted them for decades with little issue.
  - Exception: If they unlock DLC, contain ripped assets, or are marketed as "infinite money" cheats that substitute for paid content → riskier (Microsoft argued saves are copyrighted "map data" in *Datel v. Microsoft*, but it settled).

- **Savestates** (emulator memory dumps): **Much greyer / riskier**. They often include RAM contents with game code snippets, assets, or substantial portions of the protected work → can be seen as a derivative or partial copy. Distributing them is more analogous to distributing modified ROM pieces and is generally advised against.

### 4. Your exact example: Emulator + save states used for CI tests in a decomp project
- **If everything stays internal/private**:
  - You (or contributors) use your own legally dumped ROM.
  - Generate savestates in your emulator.
  - Use them in CI to verify that the decompiled/recompiled code matches original behavior at certain points.
  - **This is almost certainly legal** — it's personal archival/research use, fair use for interoperability/testing, and analogous to the protected RE in Sega/Connectix. No distribution of infringing files.

- **If the repo publicly includes the save states**:
  - Risk goes up (especially savestates). Could be challenged as distributing game data/derivatives. Better to have CI generate them on-the-fly from the user's own ROM or use minimal/non-infringing test inputs.

- **Best practices observed in real projects**: Decomp teams avoid including any Nintendo data. CI often uses checksums, disassembly diffs, or behavior tests without shipping full dumps.

### Quick summary table of "is it legal?"

| Activity | Generally Legal? | Why / Caveats |
|----------|------------------|---------------|
| Distribute exact ROM | No | Direct copy |
| Dump your own ROM for personal use | Yes (grey) | § 117 archival |
| Host clean decomp source (no assets) | Yes (in practice) | Fair use RE, new code |
| Build & play decomp with your ROM | Yes (personal) | Requires your legal copy |
| Distribute built decomp ROM/port | No | Infringement |
| Distribute regular save files | Usually yes | Player data |
| Distribute savestates | Risky / no | Contains game memory |
| Use savestates privately in CI for decomp testing | Yes | Fair use / research |

Decomp projects live in the "tolerated grey" because they advance preservation/modding without directly enabling easy piracy (unlike ROM sites). Companies like Nintendo hate anything that bypasses their control, but pure code repos have proven durable.

If you're building something like this, keep it asset-free, require user ROMs, document that users must own originals, and avoid any commercial angle. Enforcement is rare for non-profit hobby preservation unless you make it easy to play pirated copies.
