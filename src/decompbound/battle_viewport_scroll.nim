import
  ./[cpu, ppu, snesbus]

type
  BattleScroll* = tuple[x, y: int]
  DistortionState* = object
    ## C2CF29's live object fields, including the increments for its next frame.
    kind*, frequency*, amplitude*, angle*, compression*: int
    frequencyStep*, amplitudeStep*, angleStep*, compressionStep*: int
  BattleScrollModel* = object
    ## A continuation accepted only after agreement with every displayed scroll row.
    valid*: bool
    kind, frequency, amplitude, phase, compression, bias, lag: int
    baseX, baseY: int
    sourceBase: int
    targetX: bool

const
  FirstBackgroundObject = 0xADD4
  SecondBackgroundObject = 0xAE4B
    ## C2DCDC/C2DCF4 pass these two objects to C2C92D.
  Wram = 0x7E0000'u32
  ScrollMask = 0x03FF
  WordMask = 0xFFFF
  ByteMask = 0xFF

proc distortionState*(snes: SnesBus, layer: int): DistortionState =
  ## Read C2CF29's current parameters and acceleration fields without executing its driver.
  let base = Wram + (if layer == 0: FirstBackgroundObject else: SecondBackgroundObject).uint32
  result.kind = snes.bus.read8(base + 0x68).int
  result.frequency = snes.bus.read16(base + 0x69).int
  result.amplitude = snes.bus.read16(base + 0x6B).int
  result.angle = snes.bus.read8(base + 0x6D).int
  result.compression = snes.bus.read16(base + 0x6E).int
  result.frequencyStep = snes.bus.read16(base + 0x70).int
  result.amplitudeStep = snes.bus.read16(base + 0x72).int
  result.angleStep = snes.bus.read8(base + 0x74).int
  result.compressionStep = snes.bus.read16(base + 0x75).int

proc valueAt*(model: BattleScrollModel, sine: array[256, int], line: int): BattleScroll =
  ## Continue C0AE5A's wrapped sine and compression equations into signed viewport rows.
  result = (model.baseX, model.baseY)
  if model.kind == 0: return
  let
    index = (if model.lag == 1 and line == 0: 0 else: line - model.lag) + model.bias
    phase = (model.phase + model.frequency * index) and WordMask
    product = model.amplitude * sine[phase shr 8]
    wave = if product >= 0: product shr 8 else: -((-product + ByteMask) shr 8)
    signed = if model.kind in [2, 4] and (index and 1) != 0: -wave else: wave
  var value: int
  if model.kind <= 2:
    value = (model.sourceBase + signed) and ScrollMask
  else:
    let vertical = ((model.sourceBase shl 8) + model.compression * (index + 1)) and WordMask
    value = ((vertical shr 8) + signed) and ScrollMask
  if model.targetX: result.x = value
  else: result.y = value

proc agrees(model: BattleScrollModel, sine: array[256, int],
    rows: array[ScreenHeight, BattleScroll]): bool =
  ## Check both axes of every actual visible row before claiming a vertical continuation.
  for line in 0 ..< ScreenHeight:
    if model.valueAt(sine, line) != rows[line]: return false
  true

proc fitScroll*(sine: array[256, int], rows: array[ScreenHeight, BattleScroll],
    snapshots: openArray[DistortionState]): BattleScrollModel =
  ## Resolve current or queued driver state against observed HDMA, preserving restore-time phase.
  for parameters in snapshots:
    if parameters.kind notin 1 .. 4: continue
    for previous in 0 .. 1:
      let
        frequency = (parameters.frequency - previous * parameters.frequencyStep) and WordMask
        amplitude = ((parameters.amplitude - previous * parameters.amplitudeStep) and WordMask) shr 8
        compression = (parameters.compression - previous * parameters.compressionStep) and WordMask
        angle = (parameters.angle - previous * parameters.angleStep) and ByteMask
        phase = ((angle + (if parameters.kind <= 2: rows[0].y else: 0)) and ByteMask) shl 8
      for bias in -1 .. 1:
        for lag in 0 .. 1:
          # C2CF02 routes only kind 3 to VOFS; kind 4's vertical generator goes to HOFS.
          # Verify the published axis as well, allowing scripts to replace that routing.
          for targetX in [parameters.kind != 3, parameters.kind == 3]:
            var candidate = BattleScrollModel(valid: true, kind: parameters.kind,
              frequency: frequency, amplitude: amplitude, compression: compression,
              phase: phase, bias: bias, lag: lag, targetX: targetX,
              baseX: rows[0].x, baseY: rows[0].y)
            let first = candidate.valueAt(sine, 0)
            let delta = if targetX: rows[0].x - first.x else: rows[0].y - first.y
            candidate.sourceBase = delta and (if parameters.kind <= 2: ScrollMask else: ByteMask)
            if candidate.agrees(sine, rows): return candidate
  let constant = BattleScrollModel(valid: true, baseX: rows[0].x, baseY: rows[0].y)
  if constant.agrees(sine, rows): result = constant
