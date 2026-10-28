# Pocket Jukebox

A small Nim music player with an EarthBound-inspired cassette UI, numeric track list, and
mouse, keyboard, and Paddy controls. It plays EarthBound music from your own
US ROM. It does not load player saves or run the game, and has no SFX mode.

## Run

```sh
make jukebox-app
make jukebox-app ARGS="--song:3"
make jukebox-app ROM="/path/to/your.sfc"
```

On NixOS, enter the repository's `nix develop` shell first; it supplies the
native Windy, Paddy and OpenAL libraries, plus the optional PulseAudio test tools.
`make jukebox-build` builds `bin/jukebox` without opening a window. The binary
embeds the existing IBM Plex font; it needs no theme files beside it.

```sh
bin/jukebox --help
bin/jukebox "/path/to/your.sfc" --song:3 --fullscreen
```

The default ROM is `bin/Earthbound (U) [!].smc`. Headerless 3 MiB ROMs and the
same ROM with a 512-byte copier header are accepted. Native window rendering
currently uses the existing desktop Windy/OpenGL path; handheld builds are
not verified by this feature.

## Controls

| Action | Mouse | Keyboard | Paddy (physical positions) |
|---|---|---|---|
| Browse | Wheel | Up / Down | D-pad / left stick Up / Down |
| Page | Page buttons | PageUp / PageDown | L2 / R2 |
| First / last | — | Home / End | — |
| Play selected from start | Click track | Enter | Bottom face button |
| Play / pause / resume | Large play button | Space | Start |
| Stop | Stop button | S | Right face button |
| Previous / next track | Skip buttons | Left / Right | L1 / R1 |
| Volume | Minus / plus buttons | Minus / plus (`=`) | D-pad Left / Right |
| Exit | Window close | Escape | Start + Select |

Browsing does not interrupt the current track. The highlighted row is the
selection; the playback icon marks the current song. Skip wraps at the ends
and starts the adjacent playing track. Held navigation repeats; held play or
pause does not. Controllers are polled through Paddy's public API and can be
connected during playback. Music continues when the window loses focus;
input is accepted only while focused. The UI fits smaller windows and keeps
mouse coordinates aligned with the centered picture.

Tracks loop according to the original sound driver. The timer shows elapsed
playback, not a guessed song length. There are no track names because we do not
yet have a verified name catalog.

Volume follows the jukebox's own system mixer stream on Linux with PulseAudio
or PipeWire's PulseAudio interface. Knobby's game fader and the in-app buttons
control that same stream, so moving slider 4 updates the displayed percentage.
The OpenAL gain stays at unity while linked; it does not multiply a second
80% gain into the system volume. Mixer mute is shown beside the percentage.
Other backends use the local OpenAL volume, initially 80%.

## Playback and limits

`src/decompbound/music_player.nim` is the shared music engine for the GUI and
`sound_explore.nim`. It reads the 191-entry song table and package pointers
from the local ROM, loads resident package 1 when necessary, boots our APU,
and produces 32 kHz stereo PCM. Package lengths, destinations, ids and source
bounds are checked. The zero-length terminator consumes only two bytes.

The GUI streams through Slappy with a short audio buffer ahead of rendering.
Song changes, stop and pause flush queued audio. `--mute` opens no audio device;
`--trace` prints numeric control/state diagnostics. `--frames:N` exits after
N UI frames for bounded smoke checks.

The APU freezes while paused. Flushing the output queue makes pause immediate,
but resume can omit the unplayed buffer lead (about 50 ms); the GUI does not
promise sample-exact pause at the speakers.

All 191 entries have been loaded and rendered headlessly. This is not a claim
that every entry is an audible standalone song: some require further driver
investigation, and some have quiet starts. Track 4 was silent during a
two-second check. Songs 1, 3, 11 and 76 produced nonzero PCM; chunking and
pause/resume preserve their output exactly. Listening and physical-controller
checks remain in [human-verify.md](human-verify.md).

The tools execute the original driver in our emulator; they do not yet decode
every sequence command or reproduce all in-game resident-state behavior.
See [audio.md](audio.md). ROMs and rendered WAVs remain local and ignored.

## Checks and WAV output

```sh
make jukebox-test                 # synthetic inputs/packages + actual ROM audio
make jukebox-window-test          # optional Xvfb mouse/keyboard/window/audio smoke
make jukebox-volume-test          # private Pulse server: external/app volume sync
make jukebox SONG=3 ARGS="--seconds 10"
```

The window test starts its own isolated Xvfb display and uses OpenAL's null
device. It does not open a window or play sound on your desktop. Paddy mappings
and hold/repeat behavior are tested using synthetic gamepad states; this does
not replace testing your physical controller and hotplugging it.

The volume test uses an isolated PulseAudio server with a null sink and a
second process's stream. It changes that test server's volume and mute, checks
the app's percentage and buttons, and verifies that the other process is untouched.
It does not change your desktop mixer or stop your running player. PulseAudio
test tools are included in the Nix development shell. The player uses the native
client library without launching mixer commands during playback.
