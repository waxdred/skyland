#!/usr/bin/env python3
"""Write preview.html: render.js drawing model.json, the four planes composited with
their blur like the widget. Open it in a browser; query: w, h (size), f (progress),
blur=0 (no blur). Still it is the cover; the buttons feed the wave from an audio file
or the microphone (bands computed like the widget's AudioBands), live at 30 fps.
For scripted frames: window.frame(levels[], playing) advances the audio state once."""
import json, pathlib
here = pathlib.Path(__file__).parent
model = json.loads((here / 'model.json').read_text())
html = '''<!doctype html><html><body style="margin:0;background:#000;color:#9cf;font:12px sans-serif">
<canvas id="c" style="display:block"></canvas>
<div id="ui" style="padding:6px"><input type="file" id="file" accept="audio/*"> <button id="mic">microphone</button> <span id="info"></span></div>
<script>const MODEL=%s;</script><script>%s</script><script>
const q=new URLSearchParams(location.search),W=+(q.get('w')||1000),H=+(q.get('h')||286),sc=W/1000,blur=q.get('blur')!=='0';
if(q.get('ui')==='0')document.getElementById('ui').style.display='none';
const c=document.getElementById('c');c.width=W;c.height=H;
const mk=()=>{const o=document.createElement('canvas');o.width=W;o.height=H;return o};
const pl={glow:mk(),far:mk(),mid:mk(),near:mk()},draw=makeWave(MODEL),audio=makeAudio();
function render(){
  for(const k in pl)pl[k].getContext('2d').clearRect(0,0,W,H);
  draw({glow:pl.glow.getContext('2d'),far:pl.far.getContext('2d'),mid:pl.mid.getContext('2d'),near:pl.near.getContext('2d')},W,H,audio,+(q.get('f')||1));
  const o=c.getContext('2d');o.filter='none';o.fillStyle='#0A121A';o.fillRect(0,0,W,H);
  for(const [p,r] of [['glow',6],['far',1.2],['mid',0.35],['near',0]]){o.filter=blur&&r?`blur(${(r*sc).toFixed(2)}px)`:'none';o.drawImage(pl[p],0,0)}
}
window.frame=(levels,playing)=>{advanceAudio(audio,levels,playing);render()};
render();
// live audio: 14 log bands 50 Hz...12 kHz, (1 + band)^1.5 tilt, auto gain, sqrt, fast rise / slow fall
let analyser=null,shown=new Array(14).fill(0),peak=1e-3;
function bands(){const bins=new Float32Array(analyser.frequencyBinCount);analyser.getFloatFrequencyData(bins);
  const hz=analyser.context.sampleRate/analyser.fftSize,out=[];
  for(let b=0;b<14;b++){const lo=50*Math.pow(240,b/14),hi=50*Math.pow(240,(b+1)/14),f=Math.max(1,Math.floor(lo/hz)),l=Math.max(f,Math.min(bins.length-1,Math.floor(hi/hz)));
    let sum=0;for(let k=f;k<=l;k++)sum+=Math.pow(10,bins[k]/20);out.push(sum/(l-f+1)*Math.pow(1+b,1.5))}
  peak=Math.max(Math.max(...out),peak*0.995,1e-3);return out.map(v=>Math.min(1,Math.sqrt(v/peak)))}
function start(node,ctx){analyser=ctx.createAnalyser();analyser.fftSize=1024;analyser.smoothingTimeConstant=0;node.connect(analyser);
  setInterval(()=>{const t=bands();shown=shown.map((v,i)=>Math.max(t[i],v*0.85));window.frame(shown,true);
    document.getElementById('info').textContent='loud '+audio.loud.toFixed(2)+'  pulse '+audio.pulse.toFixed(2)},1000/30)}
document.getElementById('file').onchange=e=>{const ctx=new AudioContext(),el=new Audio(URL.createObjectURL(e.target.files[0]));
  const src=ctx.createMediaElementSource(el);src.connect(ctx.destination);start(src,ctx);el.play()};
document.getElementById('mic').onclick=async()=>{const ctx=new AudioContext(),stream=await navigator.mediaDevices.getUserMedia({audio:true});start(ctx.createMediaStreamSource(stream),ctx)};
</script></body></html>''' % (json.dumps(model), (here / 'render.js').read_text())
(here / 'preview.html').write_text(html)
print(here / 'preview.html')
