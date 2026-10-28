# Music

[**Pocket Jukebox**](jukebox.md) is the standalone music app. Run
`make jukebox-app` for mouse, keyboard and Paddy controls, or
`make jukebox SONG=N` to render a local WAV. Both use
`src/decompbound/music_player.nim`; the old duplicated loaders are retired.

The scope is numeric music-track selection and playback. Track names and SFX
are separate work. The app streams our SPC700/APU/DSP at 32 kHz, using the
user's ROM for resident driver, sequence and sample packages. No game audio
or bootstrap capture is bundled.

## Verified behavior

- The song and package tables contain 191 rows and 169 package pointers.
  [audio.md](audio.md) documents the named offsets and loader evidence.
- Prepending resident package 1 when omitted by a song gives a fresh standalone
  APU its driver at `$0500`. Direct loading bypasses the S-CPU/IPL handshake.
- All 191 track entries load and render through the shared engine. This verifies
  package bounds and execution, not whole-catalog audibility or fidelity.
- Songs 1, 3, 11 and 76 produce nonzero PCM. Splitting their playback into
  irregular chunks and pausing across song-command boundaries preserves PCM
  exactly (`tests/integration_music_player.nim`).
- A two-second song-1 WAV was byte-identical before and after consolidating the
  loader. The GUI and WAV renderer now share the same engine.

The old July note listing 4/11/76 as quiet is stale: 11 and 76 now produce
nonzero samples. Track 4 remained silent during the two-second recheck;
its intended standalone behavior is not yet established. The old full-catalog
"188/191 audible" claim predates subsequent driver/emulator work and is not a
current fidelity result.

## Remaining investigation

- Establish which catalog entries are expected to play standalone, including
  quiet starts, special commands and resident-state requirements.
- Diagnose unexpected silence against the original driver rather than changing
  commands or adding per-track guesses.
- Continue sequence/instrument interpretation and sound-driver annotation under
  Goal 5. Existing evidence is in [audio.md](audio.md).
- Investigate the documented synthesis issues in [sfx.md](sfx.md); those older
  reports need fresh listening before treating every symptom as current.
- Add track identities only when verified; numeric labels remain sufficient.

The usable app does not require completing the driver decompilation first.
Listening and physical input checks belong in [human-verify.md](human-verify.md).
