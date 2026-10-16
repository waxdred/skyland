# Audioware wave model

The `audioware` style of the media widget (`[media] style = 'audioware'`) draws the cover
of [Audioware](https://github.com/cyb3rpsych0s1s/audioware): a luminous ribbon twisting
around a cyan center line. `AudiowareWave` in `../main.swift` reads `model.json` at launch.

- `model.json`: everything measured on the 2000x571 cover (the lines, their light along
  x, the ribbon light, the glow of the bright edge, spikes, axis colors) and the gains.
- `render.js`: the same drawing in a canvas, the reference the gains were tuned with.
  Keep it and `AudiowareWave` in step.
- `preview.py`: writes `preview.html` (render.js on model.json, the four blurred planes
  composited like the widget). Query: `w`, `h`, `t` (time), `l` (audio level, 0.75 is the
  cover), `f` (progress), `blur=0`.
- `compare.py <cover> <render.png> [heatmap.png]`: scores a 1000x286 render of the preview
  against the cover (lower is closer) and writes a heatmap.

The cover is not in this repository: take it from the Audioware repository.
