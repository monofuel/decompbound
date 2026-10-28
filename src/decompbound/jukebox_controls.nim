import
  std/[math],
  paddy, windy

const
  VisibleTracks* = 8
  InitialRepeatMs = 350'i64
  RepeatMs = 85'i64
  StickThreshold = 0.5'f32
  VolumeStep* = 5

type
  JukeboxAction* = enum
    MoveUp, MoveDown, PageUp, PageDown, GoFirst, GoLast,
    PlaySelected, TogglePlayback, StopPlayback, PreviousTrack, NextTrack,
    Quieter, Louder, QuitPlayer
  TrackSelection* = object
    count*: int
    index*: int
    firstVisible*: int
  JukeboxInput* = object
    previous: set[JukeboxAction]
    repeatAt: array[JukeboxAction, int64]

proc selectIndex*(selection: var TrackSelection, index: int) =
  ## Select a clamped track index and keep its row in the visible page.
  if selection.count <= 0:
    selection.index = 0
    selection.firstVisible = 0
    return
  selection.index = clamp(index, 0, selection.count - 1)
  if selection.index < selection.firstVisible:
    selection.firstVisible = selection.index
  elif selection.index >= selection.firstVisible + VisibleTracks:
    selection.firstVisible = selection.index - VisibleTracks + 1
  selection.firstVisible = clamp(selection.firstVisible, 0,
    max(0, selection.count - VisibleTracks))

proc navigate*(selection: var TrackSelection, action: JukeboxAction) =
  ## Move a track selection without starting or interrupting playback.
  case action
  of MoveUp: selection.selectIndex(selection.index - 1)
  of MoveDown: selection.selectIndex(selection.index + 1)
  of PageUp: selection.selectIndex(selection.index - VisibleTracks)
  of PageDown: selection.selectIndex(selection.index + VisibleTracks)
  of GoFirst: selection.selectIndex(0)
  of GoLast: selection.selectIndex(selection.count - 1)
  else: discard

proc keyboardActions*(held: set[Button]): set[JukeboxAction] =
  ## Map keyboard keys to the same semantic actions used by the controller.
  for (key, action) in [
    (KeyUp, MoveUp), (KeyDown, MoveDown), (KeyPageUp, PageUp),
    (KeyPageDown, PageDown), (KeyHome, GoFirst), (KeyEnd, GoLast),
    (KeyEnter, PlaySelected), (KeySpace, TogglePlayback), (KeyS, StopPlayback),
    (KeyLeft, PreviousTrack), (KeyRight, NextTrack),
    (KeyMinus, Quieter), (KeyEqual, Louder), (KeyEscape, QuitPlayer)
  ]:
    if key in held: result.incl(action)

proc gamepadActions*(pads: openArray[Gamepad]): set[JukeboxAction] =
  ## Read Paddy's public positional buttons and normalized left stick.
  for pad in pads:
    for (button, action) in [
      (GamepadUp, MoveUp), (GamepadDown, MoveDown),
      (GamepadLeft, Quieter), (GamepadRight, Louder),
      (GamepadA, PlaySelected), (GamepadStart, TogglePlayback),
      (GamepadB, StopPlayback), (GamepadL1, PreviousTrack),
      (GamepadR1, NextTrack), (GamepadL2, PageUp), (GamepadR2, PageDown)
    ]:
      if pad.button(button): result.incl(action)
    if pad.axis(GamepadLStickY) < -StickThreshold: result.incl(MoveUp)
    if pad.axis(GamepadLStickY) > StickThreshold: result.incl(MoveDown)
    if pad.button(GamepadStart) and pad.button(GamepadSelect):
      result.excl(TogglePlayback)
      result.incl(QuitPlayer)

proc update*(input: var JukeboxInput, held: set[JukeboxAction],
             nowMs: int64): seq[JukeboxAction] =
  ## Emit press edges and bounded navigation repeats, never repeated toggles.
  var actions = held
  if MoveUp in actions and MoveDown in actions:
    actions.excl(MoveUp)
    actions.excl(MoveDown)
  for action in actions:
    if action notin input.previous:
      result.add(action)
      input.repeatAt[action] = nowMs + InitialRepeatMs
    elif action in {MoveUp, MoveDown, PageUp, PageDown, Quieter, Louder} and
        nowMs >= input.repeatAt[action]:
      result.add(action)
      input.repeatAt[action] = nowMs + RepeatMs
  input.previous = actions

proc reset*(input: var JukeboxInput) =
  ## Release input when the window loses focus without pausing the music.
  input = JukeboxInput()
