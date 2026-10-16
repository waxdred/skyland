# Audioware wave model

The `audioware` style of the media widget (`[media] style = 'audioware'`) draws the cover
of [Audioware](https://github.com/cyb3rpsych0s1s/audioware): a luminous ribbon twisting
around a cyan center line. `AudiowareWave` in `../main.swift` reads `model.json` at launch.

- `model.json`: everything measured on the 2000x571 cover (the lines, their light along
  x, the ribbon light, the glow of the bright edge, spikes, axis colors) and the gains.
- `render.js`: the same drawing in a canvas, the reference the gains were tuned with.
  Keep it and `AudiowareWave` in step.
- `preview.py`: writes `preview.html` (render.js on model.json, the four blurred planes
  composited like the widget). Still it is the cover; pick an audio file or the
  microphone to see it react live (bands computed like the widget's AudioBands).
  Query: `w`, `h`, `f` (progress), `blur=0`, `ui=0`.

Playing, the 14 bands spread over the drawn part of the cover (0.1...0.92 of the width):
troughs dig with the bass, crests rise on their band, spectrum peaks and hanging hairs
grow, light follows the band, onsets (level above its slow average) make everything
jump and flash the axis, highs shimmer, lines drift faster when it is loud. Paused, or
with no audio captured, it is the cover. `makeAudio` / `advanceAudio` in render.js and
`AudiowareWave.advance` hold the same rules.
- `compare.py <cover> <render.png> [heatmap.png]`: scores a 1000x286 render of the preview
  against the cover (lower is closer) and writes a heatmap.

The cover is not in this repository: take it from the Audioware repository.
