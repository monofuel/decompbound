# State-screenshots (F12 + `ebSt`)

**Status:** shipped. F12 embeds a compressed save-state in the PNG; drop the
file onto the play window to restore. Code: `png_state.nim`, `save_state.nim`,
`play.nim`.

## Where monofuel’s shots live

| | |
|---|---|
| **Directory** | `~/Pictures/Screenshots/` |
| **Absolute** | `/home/monofuel/Pictures/Screenshots/` |
| **Names** | `earthbound_yyyyMMdd-HHmmss.png` |
| **Writer** | `make play` → **F12** → `saveScreenshot` |

**Do not look in `bin/` for play F12s.** `bin/autoshots/` is for tool/auto
debug bundles (regs, traces), not the normal F12 archive.

Agents: when a chat message names `earthbound_….png`, resolve under
`~/Pictures/Screenshots/` first. See root `AGENTS.md` → *State-screenshots*.

## How to tell a PNG has a save-state attached

Play F12s are **normal PNGs** (open in any viewer). Extra payload is a private
ancillary PNG chunk type **`ebSt`** (EarthBound State) before `IEND`. Viewers
that don’t know the chunk ignore it.

### Fast checks

**1. File size (heuristic)**  
- Plain 256×224 play capture without state: often **~few–30 KB**.  
- With `ebSt` (compressed full machine state): typically **~80–150+ KB**.  
Large `earthbound_*.png` files in Screenshots almost always carry state. Size
alone is not proof (busy scenes compress worse), but it’s a useful first filter.

**2. Search for the chunk type bytes (reliable)**  
Chunk type is the four ASCII characters `ebSt` in the file:

```bash
# List shots that contain an ebSt chunk
grep -l $'ebSt' ~/Pictures/Screenshots/earthbound_*.png 2>/dev/null

# Or: Python one-liner (true/false per file)
python3 -c "
from pathlib import Path
for p in sorted(Path.home().joinpath('Pictures/Screenshots').glob('earthbound_*.png')):
    d = p.read_bytes()
    print(f\"{'ebSt' if b'ebSt' in d else '----'}  {p.stat().st_size:7}  {p.name}\")
"
```

**3. Walk PNG chunks (precise)**  
PNG layout: 8-byte signature, then chunks `length(4 BE) | type(4) | data | crc(4)`.
Find a chunk whose type is `ebSt`:

```bash
python3 -c "
import struct
from pathlib import Path
path = Path.home() / 'Pictures/Screenshots' / 'earthbound_20260709-003500.png'  # example
d = path.read_bytes()
assert d[:8] == b'\x89PNG\r\n\x1a\n'
i = 8
while i + 8 <= len(d):
    n = struct.unpack('>I', d[i:i+4])[0]
    t = d[i+4:i+8]
    print(f'{i:6}  {t.decode(\"latin1\")}  len={n}')
    if t == b'ebSt':
        print('  → has save-state')
    if t == b'IEND':
        break
    i += 12 + n
"
```

**4. Emulator / tools**  
- **Drag-and-drop** the PNG onto the play window: if it restores, it had valid
  `ebSt` (and matching ROM/version).  
- Nim: `png_state.extractState(pngBytes)` → `some(state)` or `none`.  
  Used by probes and `rerender_state.nim`.

### What is *not* a state-screenshot

| File | State? |
|------|--------|
| F12 `earthbound_*.png` under Pictures (typical) | **Yes** (`ebSt`) |
| Random phone photo of the monitor | No |
| Repo / tool PNGs under `bin/` (probes, round-trips) | Usually **no** full play state (unless a tool embedded one) |
| `bin/states/slotN.state` | Save-state **only**, not a PNG |

## Inner `ebSt` layout (for tools)

```
"EBSS"          4 bytes magic
version         u16 LE   (save_state StateVersion)
romHash         u32 LE
rawLen          u32 LE   (uncompressed state size)
payload         deflate(serializeState(...))
```

Implementation: `src/decompbound/png_state.nim`. State body:
`src/decompbound/save_state.nim`.

## Copyright — never commit these

State-screenshots are **game graphics + a full save-state** (WRAM/VRAM/APU
RAM/…). Same ban as ROM slices and `*.state` files:

- Keep under `~/Pictures/Screenshots/` (outside the repo).
- **Do not** `git add` them, copy into `docs/`/`bin/` for milestones, or ship
  in PRs.
- Milestones → empty bookmark commits or text; reference the **filename** in
  prose if needed.

Policy: root `AGENTS.md` (F12 section + *Screenshots and save-states — hard
ban*). Background: `docs/copyright-notes.md`.

## Related

- `docs/human-verify.md` — F12 in the human checklist  
- `docs/saves-vs-states.html` — SRAM vs emulator state  
- `AGENTS.md` — agent path + copyright  
