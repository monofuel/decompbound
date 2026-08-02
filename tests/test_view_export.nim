## View-path exporters: synthetic unit bits + optional gold end-to-end.

import
  std/[os, osproc],
  decompbound/[gfx_lz, rom_pipeline]

block gfxLzDecodeShipped:
  ## Shipped decoder must accept a real gold gfx stream when gold is present.
  if not goldBaseromAvailable():
    echo "[test_view_export] skip gfx_lz gold slice"
  else:
    let rom = readGoldBaserom()
    const Off = 0x214EE0
    let window = rom[Off ..< min(Off + 0x8000, rom.len)]
    let decoded = decode(window)
    doAssert decoded.len > 0

block goldViewWhenPresent:
  if not goldBaseromAvailable():
    echo "[test_view_export] skip live view (no gold)"
  else:
    let cmd = "nim r --hints:off --warnings:off src/tools/view_export.nim"
    doAssert execCmd(cmd) == 0
    for rel in ["graphics_sample.png", "audio_sample.wav",
                "script_sample.txt", "table_sample.csv"]:
      let p = "extracted/view" / rel
      doAssert fileExists(p), p
      doAssert getFileSize(p) > 0, p
    # Vanilla rebuild must still be green after view export (view does not feed build).
    doAssert execCmd("nim r --hints:off --warnings:off src/tools/rom_rebuild.nim") == 0
    echo "[test_view_export] live view + rebuild ok"

echo "[test_view_export] ok"
