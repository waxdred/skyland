#!/usr/bin/env python3
"""Score a render against the Audioware cover: compare.py <cover> <render.png> [heatmap.png].
Both are resized to 1000x286. Prints the mean absolute difference after a 1, 2 and 4 px
blur, the mean color of the bright areas, and the score the tuning minimized:
(blur2 + blur4) / 2 + 0.02 x the bright areas color difference. The heatmap stacks the
cover, the render and the difference (red: render brighter, purple: darker)."""
import sys, numpy as np
from PIL import Image, ImageFilter
cover = Image.open(sys.argv[1]).convert('RGB').resize((1000, 286), Image.LANCZOS)
render = Image.open(sys.argv[2]).convert('RGB').resize((1000, 286))
blurred = lambda im, b: np.asarray(im.filter(ImageFilter.GaussianBlur(b))).astype(float)
diffs = {}
for b in (1, 2, 4):
    d = np.abs(blurred(cover, b) - blurred(render, b)); diffs[b] = d.mean()
    print(f'blur{b}: {d.mean():.2f}  (R {d[..., 0].mean():.1f} G {d[..., 1].mean():.1f} B {d[..., 2].mean():.1f})')
o, r = blurred(cover, 2), blurred(render, 2); bright = o.mean(axis=2) > 120
gap = np.abs(o[bright].mean(axis=0) - r[bright].mean(axis=0)).sum()
print(f'bright areas: cover {o[bright].mean(axis=0).astype(int)} render {r[bright].mean(axis=0).astype(int)}')
print(f'score {(diffs[2] + diffs[4]) / 2 + 0.02 * gap:.3f}')
if len(sys.argv) > 3:
    lo, lr = blurred(cover, 3).mean(axis=2), blurred(render, 3).mean(axis=2)
    d = np.clip((lr - lo) * 3 + 128, 0, 255).astype(np.uint8)
    heat = np.stack([np.where(lr > lo, d, 128), np.minimum(d, 255 - d), np.where(lr < lo, 255 - d, 128)], axis=2).astype(np.uint8)
    out = Image.new('RGB', (1000, 858)); out.paste(cover, (0, 0)); out.paste(render, (0, 286)); out.paste(Image.fromarray(heat), (0, 572))
    out.save(sys.argv[3])
