## Compact TAS/replay log format for decompbound (EarthBound).
## Header (magic/version-ish, ROM hash, start-state ref) + sparse (frame, joy1) deltas.
## Only records joy1 changes. Text format for easy human diff / git.
## Frame numbers are relative to the pinned start save-state.
## joy1 is the value fed to snes.joy1 for that frame onward (until next delta).

import
  std/[os, strformat, strutils, tables],
  ./snesbus

const
  ReplayMagic* = "DBTAS1"
  ReplayHeaderComment* =
    "# frame joy1   -- joy1 (hex) holds from listed frame until next delta line"

type
  ReplayHeader* = object
    ## Parsed header from a .tas log.
    magic*: string
    romHash*: uint32
    startStateRef*: string

  ReplayDelta* = object
    ## A (frame, joy1) entry. joy1 applies from this frame until the next delta.
    frame*: int
    joy1*: uint16

proc parseJoy1Token(tok: string): uint16 =
  ## Accept 0x0400, 0400 (4 hex digits), 1024 (dec), etc. Prefer hex for typical joy values.
  let t = tok.strip().toLowerAscii()
  if t.len == 0:
    return 0'u16
  if t.startsWith("0x"):
    return parseHexInt(t).uint16
  # bare 4-char hex digit string (e.g. 0400 for Down) -> hex; else decimal
  if t.len == 4 and t.allCharsInSet(HexDigits):
    return parseHexInt(t).uint16
  try:
    parseInt(t).uint16
  except ValueError:
    0'u16

proc formatDeltaLine*(frame: int, joy1: uint16): string =
  ## Format one delta line as written by the recorder.
  &"{frame} {joy1:04x}"

proc serializeReplay*(header: ReplayHeader, deltas: seq[ReplayDelta]): string =
  ## Serialize header + deltas to the text .tas format (trailing newline).
  ## Inverse of parseReplayString for the fields we define.
  let magic =
    if header.magic.len > 0: header.magic
    else: ReplayMagic
  var lines: seq[string]
  lines.add(magic)
  lines.add(&"rom_hash 0x{header.romHash:08X}")
  lines.add(&"start_state {header.startStateRef}")
  lines.add(ReplayHeaderComment)
  for d in deltas:
    lines.add(formatDeltaLine(d.frame, d.joy1))
  result = lines.join("\n") & "\n"

proc writeReplayHeader*(f: File, romHash: uint32, startStateRef: string) =
  ## Write header block (once) when starting a recording.
  let header = ReplayHeader(
    magic: ReplayMagic,
    romHash: romHash,
    startStateRef: startStateRef
  )
  f.write(serializeReplay(header, @[]))
  f.flushFile()

proc appendReplayDelta*(f: File, frame: int, joy1: uint16) =
  ## Append a delta. Caller ensures only on change (or initial frame 0).
  f.writeLine(formatDeltaLine(frame, joy1))
  f.flushFile()

proc parseReplayString*(content: string): tuple[header: ReplayHeader, deltas: seq[ReplayDelta]] =
  ## Parse .tas text into header + ordered deltas. Ignores blank and # lines.
  ## Deltas need not start at 0; replay runner applies holding last value.
  let lines = content.splitLines()
  var header = ReplayHeader(magic: "", romHash: 0'u32, startStateRef: "")
  var deltas: seq[ReplayDelta] = @[]
  var headerDone = false
  for raw in lines:
    let line = raw.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    if not headerDone:
      if line == ReplayMagic or line == "DBTAS1":
        header.magic = line
        continue
      # header key-value lines until we hit a line starting with digit (frame delta)
      if line[0] in {'0'..'9'}:
        headerDone = true
        # fallthrough to parse this line as first delta
      else:
        let parts = line.split(maxsplit = 1)
        if parts.len >= 2:
          let key = parts[0].toLowerAscii()
          let val = parts[1].strip()
          if key in ["rom_hash", "romhash"]:
            var hv = val.toLowerAscii()
            if hv.startsWith("0x"):
              hv = hv[2..^1]
            try:
              header.romHash = parseHexInt(hv).uint32
            except ValueError:
              discard
            continue
          elif key in ["start_state", "startstate", "start"]:
            header.startStateRef = val
            continue
        continue  # still in header, skip
    # delta line
    let parts = line.split()
    if parts.len >= 2:
      try:
        let fr = parseInt(parts[0])
        let jv = parseJoy1Token(parts[1])
        deltas.add(ReplayDelta(frame: fr, joy1: jv))
      except ValueError:
        discard
  if header.magic.len == 0:
    header.magic = ReplayMagic
  (header, deltas)

proc parseReplay*(path: string): tuple[header: ReplayHeader, deltas: seq[ReplayDelta]] =
  ## Parse full .tas into header + ordered deltas from a path.
  if not fileExists(path):
    raise newException(IOError, &"replay log not found: {path}")
  parseReplayString(readFile(path))

proc deltasToTable*(deltas: seq[ReplayDelta]): Table[int, uint16] =
  ## For convenience in runners: map frame -> joy1 at that point.
  ## Later entries override earlier at same frame.
  result = initTable[int, uint16]()
  for d in deltas:
    result[d.frame] = d.joy1

proc joyAtFrame*(deltas: seq[ReplayDelta], frame: int): uint16 =
  ## Resolve held joy1 at `frame` (last delta with d.frame <= frame, else 0).
  result = 0'u16
  for d in deltas:
    if d.frame > frame:
      break
    result = d.joy1

proc wramHash*(snes: SnesBus): uint32 =
  ## Cheap deterministic hash of the 128KB WRAM (7E+7F) for end-of-run reports.
  ## (zippy crc32 is already a dep via png_state, but avoid import here; fold is fine.)
  var h = 0x811c9dc5'u32  # FNV-ish offset
  const prime = 0x01000193'u32
  # Walk the two banks in bus.mem (layout: 7E0000..7EFFFF then 7F0000..)
  for bank in [0x7E0000'u32, 0x7F0000'u32]:
    for i in 0 ..< 0x10000:
      let b = snes.bus.mem[(bank + i.uint32).int]
      h = h xor b.uint32
      h = h * prime
  h

proc playerPos*(snes: SnesBus): tuple[x: uint16, y: uint16] =
  ## Read Ness/player world position from verified WRAM bases.
  ## Party leader = entity slot 24 (traced: $C04E15 STA $0B8E,X runs with X=0x30
  ## for the walking player; slot 0 is just the first map NPC/object).
  ## X at $0B8E+0x30 = $0BBE (LE), Y at $0BCA+0x30 = $0BFA (LE).
  let xlo = snes.bus.mem[0x7E0000 + 0x0BBE]
  let xhi = snes.bus.mem[0x7E0000 + 0x0BBF]
  let ylo = snes.bus.mem[0x7E0000 + 0x0BFA]
  let yhi = snes.bus.mem[0x7E0000 + 0x0BFB]
  ( (xlo.uint16 or (xhi.uint16 shl 8)) , (ylo.uint16 or (yhi.uint16 shl 8)) )
