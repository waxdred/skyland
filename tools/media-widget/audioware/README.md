# Audioware wave

The `audioware` style of the media widget (`[media] style = 'audioware'`) draws the live
audio wave in the style of the [Audioware](https://github.com/cyb3rpsych0s1s/audioware)
cover: a luminous ribbon twisting around a cyan center line, flat when silent, behind
the artwork, text and buttons (its center line is the progress, where the classic
progress bar is).
`AudiowareWave` in `../main.swift` draws it; `AudioBands` there feeds it.

- `render.js`: the same drawing in a canvas, the reference. Keep it and `AudiowareWave`
  in step (same constants, same order).
- `model.json`: the look. `gain` was tuned against the cover (the measured cover is
  kept under `cover`), `window` is the cover's amplitude envelope along x.
- `preview.py`: writes `preview.html`; open it, pick an audio file or the microphone and
  the wave plays live, the bands and signals computed like the widget's. Query: `w`, `h`,
  `f` (progress), `axis` (height of the center line), `blur=0`, `ui=0`.

How the wave follows the audio, 30 times a second:

- AudioBands low-passes the audio (~180 Hz) and band-passes it (~1 kHz), decimates both
  to 6 kHz and keeps the last 768 points, next to the 14 band levels.
- Like an oscilloscope, the 80 ms window most like the previous frame is shown. The
  bright edge A is the low signal, the second edge B the same 10 ms earlier: a ribbon
  that twists, wide where the signal moves, pinched where both meet. Both are shaped by
  the cover's window (flat ends, big middle) and normalized by slow peaks.
- Crest fans sit on the two highest peaks of A, the dotted jagged edge hangs under the
  ribbon by |mid| (its cusps are the zero crossings), spectrum peaks rise where mid is
  strong, hairs hang under troughs with the bass, light follows slope and amplitude,
  onsets (level above its slow average) flash the ribbon and the axis.
- Silence, no capture (Screen Recording permission) or pause: the wave eases back to the
  flat line.

Colors follow the skyland theme (`~/.cache/skyland/theme.css`, live): the glow color is
the theme's `accent`, or its `highlight` when the accent has no color (white, black,
gray). Every color of the design turns from the cover's cyan to it, hue rotated,
saturation scaled, brightness kept, so the relations between them stay. On a light
background it is ink on paper: sharp lines darken, glows take a lighter ink, the dark
tints of the cover's atmosphere turn pale. Text and buttons take `fg` / `fg_dim`, the
background `bg`. Without a theme it is the cover's cyan (`makeTone` in render.js,
`setTheme` in AudiowareWave). Preview: `?glow=7aa2f7&bg=16161e`.
