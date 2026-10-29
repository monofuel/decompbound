# Curated README illustrations

These five images illustrate working project features in the root
[README](../../README.md). They are selected documentation examples, not a game
asset collection. Game imagery remains the property of its rightsholders; the
project's source-code license does not grant rights to that artwork.

| Image | Purpose |
|-------|---------|
| `emulator.png` | EarthBound gameplay rendered by the Nim emulator, shown at 3× nearest-neighbor scale. |
| `earthbound_20260818-022023-ds.png` | The libretro core's complete game and original-UI party companion, stacked vertically at 3×. |
| `music-jukebox.png` | Pocket Jukebox's original procedural cassette UI during offline playback of track 24. |
| `battle-background-viewer.png` | Pocket Backgrounds' actual control and preview canvases placed side by side, with New Age Retro Hippie selected at animation frame 180. |
| `bestiary.png` | Pocket Bestiary's actual UI, portrait, stats, and encounter background with Starman selected at animation frame 180. |

The gameplay images were exported from the user's local ROM/screenstate; the
original screenstate stays in the user's screenshot archive. Companion-app
canvases are rendered through the same modules as their windowed apps, without
desktop decorations. No source ROM, save-state, memory dump, or audio is included.

## Export and review

Export a fresh PNG from decoded pixels. Never copy an original F12 PNG here:
it contains an `ebSt` chunk with an entire save-state, hidden by image viewers.

Before including or replacing an image:

1. Decode it to verify it is a valid image and visually review its purpose.
2. Parse its PNG structure from the signature through the end of the file.
   Only `IHDR`, `IDAT`, and `IEND` chunks are allowed, with no trailing bytes.
   Reject any `ebSt`, text, unknown chunk, or appended payload.
3. Keep it referenced and explained in the root README, and list it here.
4. Keep the explicit `.gitignore` selection small. Other generated images
   remain ignored; do not add galleries or reusable extracted game assets.

The policy exception is in [AGENTS.md](../../AGENTS.md); the rationale is in
[copyright-notes.md](../copyright-notes.md). Save-states and screenstates remain
prohibited regardless of filename or storage location.
