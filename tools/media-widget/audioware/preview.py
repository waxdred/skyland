#!/usr/bin/env python3
"""Write preview.html: render.js drawing model.json, the four planes composited with
their blur like the widget. Open it in a browser; query: w, h (size), t (time),
l (audio level, 0.75 = the cover), f (progress), blur=0 (no blur)."""
import json, pathlib
here = pathlib.Path(__file__).parent
model = json.loads((here / 'model.json').read_text())
html = '''<!doctype html><html><body style="margin:0;background:#000"><canvas id="c"></canvas>
<script>const MODEL=%s;</script><script>%s</script><script>
const q=new URLSearchParams(location.search),W=+(q.get('w')||1000),H=+(q.get('h')||286),sc=W/1000;
const c=document.getElementById('c');c.width=W;c.height=H;
const mk=()=>{const o=document.createElement('canvas');o.width=W;o.height=H;return o};
const pl={glow:mk(),far:mk(),mid:mk(),near:mk()},blur=q.get('blur')!=='0';
makeWave(MODEL)({glow:pl.glow.getContext('2d'),far:pl.far.getContext('2d'),mid:pl.mid.getContext('2d'),near:pl.near.getContext('2d')},W,H,+(q.get('t')||0),+(q.get('l')||0.75),+(q.get('f')||1));
const o=c.getContext('2d');o.fillStyle='#0A121A';o.fillRect(0,0,W,H);
for(const [p,r] of [['glow',6],['far',1.2],['mid',0.35],['near',0]]){o.filter=blur&&r?`blur(${(r*sc).toFixed(2)}px)`:'none';o.drawImage(pl[p],0,0)}
</script></body></html>''' % (json.dumps(model), (here / 'render.js').read_text())
(here / 'preview.html').write_text(html)
print(here / 'preview.html')
