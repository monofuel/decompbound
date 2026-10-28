import
  std/[unittest],
  paddy, pixie, windy,
  decompbound/[jukebox_controls, jukebox_view]

proc pad(buttons: set[GamepadButton], stickY = 0'f32): Gamepad =
  ## Create synthetic controller input without opening a device.
  for button in buttons: result.buttons = result.buttons or (1'u64 shl button.ord)
  result.axes[GamepadLStickY.ord] = stickY

suite "Jukebox controls":
  test "navigation reaches all tracks and preserves a visible selection":
    var selection = TrackSelection(count: 191)
    selection.navigate(GoLast)
    check selection.index == 190
    check selection.firstVisible <= 190 and selection.firstVisible + VisibleTracks > 190
    selection.navigate(MoveDown)
    check selection.index == 190
    selection.navigate(PageUp)
    check selection.index == 182
    selection.navigate(GoFirst)
    selection.navigate(MoveUp)
    check selection.index == 0 and selection.firstVisible == 0
    selection.selectIndex(55)
    check selection.firstVisible <= 55 and selection.firstVisible + VisibleTracks > 55

  test "short and empty lists stay in bounds":
    for count in [0, 1, 4]:
      var selection = TrackSelection(count: count)
      selection.navigate(GoLast)
      selection.navigate(PageDown)
      check selection.firstVisible == 0
      check selection.index == max(0, count - 1)

  test "keyboard and Paddy use matching playback actions":
    check keyboardActions({KeyEnter}) == gamepadActions([pad({GamepadA})])
    check keyboardActions({KeySpace}) == gamepadActions([pad({GamepadStart})])
    check keyboardActions({KeyS}) == gamepadActions([pad({GamepadB})])
    check keyboardActions({KeyLeft, KeyRight}) == gamepadActions([pad({GamepadL1, GamepadR1})])
    check keyboardActions({KeyPageUp, KeyPageDown}) == gamepadActions([pad({GamepadL2, GamepadR2})])
    check gamepadActions([pad({GamepadStart, GamepadSelect})]) == {QuitPlayer}

  test "sticks have a deadzone and multiple controllers combine":
    check gamepadActions([pad({}, 0.2)]) == {}
    check gamepadActions([pad({}, -0.8)]) == {MoveUp}
    check gamepadActions([pad({}, 0.8), pad({GamepadA})]) == {MoveDown, PlaySelected}
    check gamepadActions([]) == {}

  test "held play and pause fire once while navigation repeats":
    var input: JukeboxInput
    check input.update({MoveDown, TogglePlayback}, 0) == @[MoveDown, TogglePlayback]
    check input.update({MoveDown, TogglePlayback}, 349).len == 0
    check input.update({MoveDown, TogglePlayback}, 350) == @[MoveDown]
    check input.update({MoveDown, TogglePlayback}, 435) == @[MoveDown]
    check input.update({MoveDown, TogglePlayback}, 5000) == @[MoveDown]
    check input.update({}, 5001).len == 0
    check input.update({TogglePlayback}, 5002) == @[TogglePlayback]

  test "opposing directions cancel and focus reset releases held input":
    var input: JukeboxInput
    check input.update({MoveUp, MoveDown}, 0).len == 0
    check input.update({PlaySelected}, 1) == @[PlaySelected]
    input.reset()
    check input.update({PlaySelected}, 2) == @[PlaySelected]

  test "mouse hit testing follows scrolled rows, transport, and letterboxing":
    var selection = TrackSelection(count: 191)
    selection.selectIndex(40)
    let first = selection.firstVisible
    check mouseTarget(vec2(500, 155), selection).trackIndex == first
    check mouseTarget(vec2(500, 155 + 7 * 41), selection).trackIndex == first + 7
    check mouseTarget(vec2(200, 420), selection).actions == {TogglePlayback}
    check mouseTarget(vec2(200, 480), selection).actions == {StopPlayback}
    check mouseTarget(vec2(780, 590), selection).trackIndex == -1
    check viewPoint(vec2(100, 210), 400, 300) == vec2(200, 420)
    check viewPoint(vec2(300, 420), 1000, 600) == vec2(200, 420)
    check mouseTarget(viewPoint(vec2(10, 420), 1000, 600), selection).actions == {}

  test "headless view draws the selected page and playback state":
    let view = newJukeboxView()
    let image = view.render(JukeboxDisplay(selection: TrackSelection(count: 191),
      tracks: @[1, 2, 3, 4, 5, 6, 7, 8], songId: 1, playing: true,
      volume: 80, hover: vec2(-1, -1)))
    check image.width == 800 and image.height == 600
    check image[440, 165] != image[440, 206]
    let before = image[715, 166]
    discard view.render(JukeboxDisplay(selection: TrackSelection(count: 191),
      tracks: @[1, 2, 3, 4, 5, 6, 7, 8], songId: 1, paused: true,
      volume: 80, hover: vec2(-1, -1)))
    check image[715, 166] != before
