#!/usr/bin/env python3
"""Write preview.html: render.js drawing the wave on the four planes composited with
their blur like the widget. Open it in a browser and pick an audio file or the
microphone: the bands and the low / mid signals are computed like the widget's
AudioBands, live at 30 fps. Query: w, h (size), f (progress), axis (height of the
center line, 0...1), blur=0, ui=0.
For scripted frames: window.frame(levels[14], playing, {low, mid}) advances once."""
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
  draw({glow:pl.glow.getContext('2d'),far:pl.far.getContext('2d'),mid:pl.mid.getContext('2d'),near:pl.near.getContext('2d')},W,H,audio,+(q.get('f')||1),+(q.get('axis')||0.445));
  const o=c.getContext('2d');o.filter='none';o.fillStyle='#0A121A';o.fillRect(0,0,W,H);
  for(const [p,r] of [['glow',6],['far',1.2],['mid',0.35],['near',0]]){o.filter=blur&&r?`blur(${(r*sc).toFixed(2)}px)`:'none';o.drawImage(pl[p],0,0)}
}
window.frame=(levels,playing,wave)=>{advanceAudio(audio,levels,playing,wave);render()};
render();
// live audio, like AudioBands: 14 log bands 50 Hz...12 kHz with (1 + band)^1.5 tilt, auto gain,
// sqrt, fast rise / slow fall; low-passed 180 Hz and band-passed 1 kHz signals decimated by 8
let shown=new Array(14).fill(0),peak=1e-3;
function bands(an){const bins=new Float32Array(an.frequencyBinCount);an.getFloatFrequencyData(bins);
  const hz=an.context.sampleRate/an.fftSize,out=[];
  for(let b=0;b<14;b++){const lo=50*Math.pow(240,b/14),hi=50*Math.pow(240,(b+1)/14),f=Math.max(1,Math.floor(lo/hz)),l=Math.max(f,Math.min(bins.length-1,Math.floor(hi/hz)));
    let sum=0;for(let k=f;k<=l;k++)sum+=Math.pow(10,bins[k]/20);out.push(sum/(l-f+1)*Math.pow(1+b,1.5))}
  peak=Math.max(Math.max(...out),peak*0.995,1e-3);return out.map(v=>Math.min(1,Math.sqrt(v/peak)))}
function decimated(an){const d=new Float32Array(an.fftSize);an.getFloatTimeDomainData(d);const out=[];
  for(let i=0;i+8<=d.length;i+=8){let s=0;for(let k=0;k<8;k++)s+=d[i+k];out.push(s/8)}return out.slice(-768)}
function start(node,ctx){
  const spectrum=ctx.createAnalyser();spectrum.fftSize=1024;spectrum.smoothingTimeConstant=0;node.connect(spectrum);
  const tap=(type,f,qv)=>{const bq=ctx.createBiquadFilter();bq.type=type;bq.frequency.value=f;bq.Q.value=qv;const an=ctx.createAnalyser();an.fftSize=8192;node.connect(bq);bq.connect(an);return an};
  const low=tap('lowpass',180,0.707),mid=tap('bandpass',1000,0.8);
  setInterval(()=>{const t=bands(spectrum);shown=shown.map((v,i)=>Math.max(t[i],v*0.85));
    window.frame(shown,true,{low:decimated(low),mid:decimated(mid)});
    document.getElementById('info').textContent='loud '+audio.loud.toFixed(2)+'  pulse '+audio.pulse.toFixed(2)+'  presence '+audio.presence.toFixed(2)},1000/30)}
document.getElementById('file').onchange=e=>{const ctx=new AudioContext(),el=new Audio(URL.createObjectURL(e.target.files[0]));
  const src=ctx.createMediaElementSource(el);src.connect(ctx.destination);start(src,ctx);el.play()};
document.getElementById('mic').onclick=async()=>{const ctx=new AudioContext(),stream=await navigator.mediaDevices.getUserMedia({audio:true});start(ctx.createMediaStreamSource(stream),ctx)};
</script></body></html>''' % (json.dumps(model), (here / 'render.js').read_text())
(here / 'preview.html').write_text(html)
print(here / 'preview.html')
