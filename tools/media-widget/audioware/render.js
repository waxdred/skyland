// Reference renderer for the audioware widget wave (mirrored by AudiowareWave in
// tools/media-widget/main.swift). Model: model.json, measured on the cover.
// draw(P, W, H, audio, progress): P = {glow, far, mid, near} 2D contexts, composited
// back to front with blur ~6, 1.2, 0.35 and 0 px per 1000 px of width. audio comes from
// makeAudio() / advanceAudio(); with activity 0 (paused) the drawing is the cover as is.

// Audio state, advanced 30 times a second with the band levels (0...1, fast rise and
// slow fall, from the widget) like AudiowareWave.advance.
function makeAudio(){return {t:0,activity:0,bands:[],loud:0,loudSlow:0,pulse:0,seen:false,bass:0.6,mids:0.6,treble:0.6}}
function advanceAudio(st,input,playing){
  const target=playing?1:0,settling=Math.abs(st.activity-target)>0.002;
  st.activity=settling?st.activity+(target-st.activity)*0.08:target;
  if(st.bands.length!==input.length)st.bands=input.map(()=>0);
  st.bands=st.bands.map((b,i)=>b+(input[i]-b)*(input[i]>b?0.6:0.18)); // fast attack, softer release
  const mean=a=>a.length?a.reduce((s,v)=>s+v,0)/a.length:0;
  st.loud=mean(st.bands);st.loudSlow+=(st.loud-st.loudSlow)*0.05;
  st.seen=st.loudSlow>0.01; // no capture (no permission, silence): keep the cover's proportions
  st.pulse=st.seen?Math.max(st.pulse*0.86,Math.min(1,Math.max(0,(st.loud-st.loudSlow)*4))):0; // onsets: kick, attack
  st.bass=st.seen?mean(st.bands.slice(0,3)):0.6;st.mids=st.seen?mean(st.bands.slice(3,9)):0.6;st.treble=st.seen?mean(st.bands.slice(9)):0.6;
  if(playing)st.t+=(0.5+1.5*st.loud)/30; // louder, livelier
}

function makeWave(M){
const spline=(P,x)=>{if(x<=P[0][0])return P[0][1];if(x>=P[P.length-1][0])return P[P.length-1][1];
  let i=1;while(i<P.length-1&&P[i][0]<x)i++;const a=P[i-1],b=P[i],dx=b[0]-a[0],t=(x-a[0])/dx,sec=(b[1]-a[1])/dx;
  const ta=(a[2]||i<2)?sec:(b[1]-P[i-2][1])/(b[0]-P[i-2][0]), tb=(b[2]||i+1>=P.length)?sec:(P[i+1][1]-a[1])/(P[i+1][0]-a[0]);
  const t2=t*t,t3=t2*t;return (2*t3-3*t2+1)*a[1]+(-2*t3+3*t2)*b[1]+((t3-2*t2+t)*ta+(t3-t2)*tb)*dx*0.9};
const lin=(P,x)=>{if(x<=P[0][0])return P[0][1];if(x>=P[P.length-1][0])return P[P.length-1][1];let i=1;while(P[i][0]<x)i++;const a=P[i-1],b=P[i];return a[1]+(b[1]-a[1])*(x-a[0])/(b[0]-a[0])};
const hash=i=>{const s=Math.sin(i*12.9898+78.233)*43758.5453;return s-Math.floor(s)};
const gauss=(x,c,w)=>Math.exp(-((x-c)**2)/(2*w*w));
const names=Object.keys(M.lines), isCrest=(k,x)=>k==='C1'||(k==='C2'&&x<0.72);
let cache=null;
function base(n){ // splines sampled once per width
  if(cache&&cache.n===n)return cache;
  const xs=[...Array(n+1).keys()].map(i=>i/n), L={};
  for(const k of names){const l=M.lines[k],a=l.keys[0][0],b=l.keys[l.keys.length-1][0];
    L[k]={h:xs.map(x=>x>=a&&x<=b?spline(l.keys,x):NaN),light:xs.map(x=>x>=a&&x<=b?lin(l.light,x):0)};}
  const coverTop=[],coverBottom=[]; // ribbon edges of the cover, the base of the spikes
  xs.forEach((x,i)=>{let a=-9,b=9;for(const k of names){const h=L[k].h[i];if(isNaN(h)||isCrest(k,x))continue;a=Math.max(a,h);b=Math.min(b,h)}coverTop.push(a===-9?0:a);coverBottom.push(b===9?0:b)});
  return cache={n,xs,L,coverTop,coverBottom,fillUp:xs.map(x=>lin(M.fill.up,x)),fillDown:xs.map(x=>lin(M.fill.down,x)),innerA:xs.map(x=>lin(M.glowA.inner,x)),outerA:xs.map(x=>lin(M.glowA.outer,x))};
}
return function draw(P,W,H,st=makeAudio(),frac=1){
  const G=M.gain, s=W/1000, n=Math.round(W/1.5), B=base(n), mid=H*0.555, unit=H*0.525, a=st.activity, t=st.t;
  // audio level under x: the bands spread over the drawn part of the cover (0.1...0.92)
  const level=x=>{const b=st.bands;if(!st.seen||b.length<2)return 0.6;const u=Math.max(0,Math.min(1,(x-0.1)/0.82))*(b.length-1),i=Math.min(b.length-2,Math.floor(u)),f=u-i;return b[i]*(1-f)+b[i+1]*f};
  // growth of a line at level l, 1 = the cover: troughs dig with the bass, crests rise on their band, all jump on onsets
  const response=(k,l)=>{const v=k==='B'||k==='T'?0.4+0.5*l+0.5*st.bass+0.25*st.pulse:k==='C1'||k==='C2'?0.3+1.15*l+0.15*st.pulse:0.4+l+0.12*st.pulse;return 1+a*(v-1)};
  const lv=B.xs.map(level), boost=lv.map(l=>1+a*(0.5*(l-0.6)+0.45*st.pulse)); // light follows the band, flashes on onsets
  const spikeGrow=l=>1+a*(0.04+1.6*l-1), hangGrow=l=>1+a*(0.4+0.5*l+0.5*st.bass+0.6*st.pulse-1);
  const L={};for(const k of names){const kk=k.charCodeAt(0);L[k]=B.L[k].h.map((h,i)=>{const x=B.xs[i];
    const wob=1+0.06*a*(Math.sin(t*0.9+x*23+kk)-Math.sin(x*23+kk)), shimmer=a*st.treble*0.025*Math.sin(x*90-t*7+kk)*Math.min(1,Math.abs(h)*8);
    return h*response(k,lv[i])*wob+shimmer})}
  // soft knee above 0.85 so loud crests round off instead of flattening
  const clip=h=>{const m=Math.abs(h);return m<=0.85?h:Math.sign(h)*(0.85+0.2*Math.tanh((m-0.85)/0.2))};
  const X=i=>i/n*W, Y=h=>mid-clip(h)*unit, W_=w=>Math.max(0.5,w*s);
  const top=[],bot=[];
  for(let i=0;i<=n;i++){let a=-9,b=9;for(const k of names){const h=L[k][i];if(isNaN(h)||isCrest(k,B.xs[i]))continue;a=Math.max(a,h);b=Math.min(b,h)}top.push(a===-9?0:a);bot.push(b===9?0:b)}
  const rgba=(c,a)=>`rgba(${c[0]},${c[1]},${c[2]},${Math.max(0,Math.min(1,a))})`;
  const poly=(ctx,arr,from,to)=>{ctx.beginPath();let first=true;for(let i=from;i<=to;i++){if(isNaN(arr[i])){first=true;continue}first?ctx.moveTo(X(i),Y(arr[i])):ctx.lineTo(X(i),Y(arr[i]));first=false}};
  // a line drawn in chunks so its brightness follows its light profile
  const lit=(ctx,k,col,alpha,width,step=4,dash,prof)=>{const h=L[k],li=prof||B.L[k].light;ctx.lineWidth=W_(width);ctx.lineCap='round';if(dash)ctx.setLineDash(dash.map(W_));
    for(let i=0;i<n;i+=step){const j=Math.min(n,i+step);if(isNaN(h[i])||isNaN(h[j]))continue;const a=alpha*(li[i]+li[j])/2*(boost[i]+boost[j])/2;if(a<0.02)continue;poly(ctx,h,i,j);ctx.strokeStyle=rgba(col,a);ctx.stroke()}ctx.setLineDash([])};
  const halo=(ctx,cx,cy,rx,ry,col,a)=>{ctx.save();ctx.translate(cx,cy);ctx.scale(rx/ry,1);const g=ctx.createRadialGradient(0,0,0,0,0,ry);g.addColorStop(0,rgba(col,a));g.addColorStop(1,rgba(col,0));ctx.fillStyle=g;ctx.fillRect(-ry,-ry,2*ry,2*ry);ctx.restore()};
  // hairlines batched by color and alpha (rounded to 0.05)
  const hair=(ctx,segs,width)=>{ctx.lineWidth=W_(width);const buckets={};for(const [x0,y0,x1,y1,c,a] of segs){const key=c+'|'+Math.round(Math.min(1,a)*20)/20;(buckets[key]=buckets[key]||[]).push([x0,y0,x1,y1])}
    for(const key in buckets){const [c,a]=key.split('|');if(+a<=0)continue;ctx.strokeStyle=`rgba(${c},${a})`;ctx.beginPath();for(const [x0,y0,x1,y1] of buckets[key]){ctx.moveTo(x0,y0);ctx.lineTo(x1,y1)}ctx.stroke()}};
  const ribbon=ctx=>{ctx.beginPath();for(let i=0;i<=n;i++)ctx.lineTo(X(i),Y(top[i]));for(let i=n;i>=0;i--)ctx.lineTo(X(i),Y(bot[i]));ctx.closePath()};
  const axisGradient=ctx=>{const g=ctx.createLinearGradient(0,0,W,0);for(const [x,c,a] of M.axisStops)g.addColorStop(x,rgba(c,a));return g};

  // ---- GLOW plane (strong blur): ribbon light per column, light the edges pour inside it, wide halos
  let ctx=P.glow;
  halo(ctx,W*0.53,mid,W*0.40,H*0.42,[22,45,80],0.45);
  const cols=[];
  for(let i=0;i<=n;i++){if(top[i]-bot[i]<0.005)continue;
    if(top[i]>0)cols.push([X(i),Y(top[i]),X(i),Y(Math.max(0,bot[i])),'40,110,195',G.fill*B.fillUp[i]*boost[i]]);
    if(bot[i]<0)cols.push([X(i),Y(Math.min(0,top[i])),X(i),Y(bot[i]),'40,110,195',G.fill*B.fillDown[i]*boost[i]]);}
  hair(ctx,cols,(W/n+0.5)/s);
  ctx.save();ribbon(ctx);ctx.clip();
  for(const k of names){const g=G.inner*(k==='A'?1:G.innerB),p=k==='A'?B.innerA:undefined;lit(ctx,k,[45,185,235],g,G.innerW,6,null,p);lit(ctx,k,[90,215,250],g,G.innerW*0.4,6,null,p)}
  lit(ctx,'B',[50,140,230],G.ramp,40,6);lit(ctx,'T',[50,140,230],G.ramp,40,6);
  ctx.restore();
  for(const k of names)lit(ctx,k,[35,165,230],G.outer*(k==='A'?1:G.outerB),G.outerW,6,null,k==='A'?B.outerA:undefined);
  ctx.fillStyle=axisGradient(ctx);ctx.globalAlpha=G.axisHalo;ctx.fillRect(0,mid-W_(4),W,W_(8));ctx.globalAlpha=1;

  // haze behind the cluster of spectrum peaks (a luminous jagged mountain on the cover)
  ctx.beginPath();let hz=true;for(let i=0;i<=n;i++){const x=B.xs[i];if(x<M.haze[0][0]||x>M.haze[M.haze.length-1][0])continue;const h=Math.max(top[i],lin(M.haze,x)*response('A',lv[i]));hz?ctx.moveTo(X(i),Y(h)):ctx.lineTo(X(i),Y(h));hz=false}
  for(let i=n;i>=0;i--){const x=B.xs[i];if(x<M.haze[0][0]||x>M.haze[M.haze.length-1][0])continue;ctx.lineTo(X(i),Y(top[i]))}ctx.closePath();
  const hg=ctx.createLinearGradient(0,Y(0.9),0,Y(0.3));hg.addColorStop(0,rgba([60,150,240],0));hg.addColorStop(1,rgba([60,150,240],G.haze));ctx.fillStyle=hg;ctx.fill();

  // ---- FAR plane (soft): secondary glows
  ctx=P.far;
  for(const k of names)lit(ctx,k,[60,195,240],G.far*(k==='A'?1:G.outerB),G.farW,4);

  // ---- MID plane (barely soft): hatch, spikes, hanging hairs, fans, secondary edges
  ctx=P.mid;
  const segs=[];
  for(let i=0;i<=n;i++){const r=hash(i+40);if(top[i]-bot[i]<0.01)continue;
    const bright=r>0.93, c=bright?'120,210,255':'55,125,215', up=G.hatch*B.fillUp[i]*(0.25+1.1*r)*boost[i], dn=G.hatch*B.fillDown[i]*(0.25+1.1*hash(i+91))*boost[i];
    if(top[i]>0)segs.push([X(i),Y(top[i]),X(i),Y(Math.max(0,bot[i])),c,up]);
    if(bot[i]<0)segs.push([X(i),Y(Math.min(0,top[i])),X(i),Y(bot[i]),c,dn]);}
  hair(ctx,segs,0.55);
  // spectrum peaks: narrow glowing triangles on the top edge, the tallest prolonged by a hairline with a light tip
  const sp=[];
  for(const [sx,sh] of M.spikesUp){const i=Math.round(sx*n),b=top[i],tip=b+Math.max(0,sh-B.coverTop[i])*spikeGrow(lv[i])*(1+0.12*a*(Math.sin(t*1.7+sx*40)-Math.sin(sx*40)));if(tip-b<0.03)continue;
    const th=Math.min(0.22,tip-b),hw=(0.003+0.02*th)*W,ax=X(i),ay=Y(b+th);
    const pk=G.peak*boost[i],g=ctx.createLinearGradient(0,Y(b),0,ay);g.addColorStop(0,rgba([70,170,245],pk));g.addColorStop(1,rgba([70,170,245],pk*0.3));
    // concave flanks, like a resonance peak
    ctx.beginPath();ctx.moveTo(ax-hw,Y(b));ctx.quadraticCurveTo(ax-hw*0.15,Y(b+th*0.25),ax,ay);ctx.quadraticCurveTo(ax+hw*0.15,Y(b+th*0.25),ax+hw,Y(b));ctx.closePath();ctx.fillStyle=g;ctx.fill();
    ctx.strokeStyle=rgba([110,210,250],pk*1.2);ctx.lineWidth=W_(0.5);ctx.stroke();
    if(tip-b>th+0.02){sp.push([ax,ay,ax,Y(tip),'110,200,250',G.spike*boost[i]]);if(tip>0.5)halo(ctx,ax,Y(tip),W_(2),W_(2),[170,240,255],0.5*boost[i])}}
  for(const [sx,sh] of M.spikesDown){const i=Math.round(sx*n),b=bot[i],tip=b-Math.max(0,B.coverBottom[i]-sh)*hangGrow(lv[i]);if(b-tip<0.03)continue;const m=(b+tip)/2;
    sp.push([X(i),Y(b),X(i),Y(m),'90,170,240',G.spike*boost[i]],[X(i),Y(m),X(i),Y(tip),'90,170,240',G.spike*0.45*boost[i]])}
  const above=x=>0.6*gauss(x,0.40,0.03)+0.4*gauss(x,0.60,0.02)+0.4*gauss(x,0.30,0.01)+0.3*gauss(x,0.74,0.01);
  const below=x=>Math.min(1,gauss(x,0.40,0.02)+gauss(x,0.52,0.025)+0.4*gauss(x,0.66,0.04));
  for(let i=0;i<=n;i++){const x=B.xs[i];
    if(hash(i+7)<above(x)){const len=Math.pow(hash(i+11),2)*0.3*1.35*spikeGrow(lv[i]),r=hash(i+3);sp.push([X(i),Y(top[i]),X(i),Y(top[i]+len),'60,140,225',G.hairs*(0.4+0.6*r)*boost[i]])}
    if(hash(i+17)<below(x)){const len=(0.04+Math.pow(hash(i+19),1.5)*0.22)*1.35*hangGrow(lv[i]),ha=G.hairs*(0.4+0.6*hash(i+23))*boost[i],m=bot[i]-len/2;
      sp.push([X(i),Y(bot[i]),X(i),Y(m),'60,140,225',ha],[X(i),Y(m),X(i),Y(bot[i]-len),'60,140,225',ha*0.4])}}
  hair(ctx,sp,0.6);
  // fans: nested contours from A up to each crest (moire)
  const fan=(k,lo,hi,count)=>{const hs=L[k];for(let f=1;f<=count;f++){const q=f/count;ctx.beginPath();let first=true;
    for(let i=0;i<=n;i++){const x=B.xs[i];if(x<lo||x>hi||isNaN(hs[i])||isNaN(L.A[i]))continue;const h=L.A[i]+(hs[i]-L.A[i])*q;first?ctx.moveTo(X(i),Y(h)):ctx.lineTo(X(i),Y(h));first=false}
    ctx.strokeStyle=rgba([75,155,230],(k==='C1'?G.fanC1:G.fan)*(0.35+0.65*q));ctx.lineWidth=W_(0.5);ctx.stroke()}};
  fan('C1',0.4525,0.565,22);fan('C2',0.645,0.7475,22);
  for(const k of ['B','T','E'])lit(ctx,k,[98,205,231],G.core,G.coreB,3);
  lit(ctx,'C1',[120,215,245],0.9,0.8,3);lit(ctx,'C2',[98,205,231],1.0,1.2,3);
  lit(ctx,'D',[120,215,245],1.0,1.1,3,[1.4,2.2]);

  // ---- NEAR plane (sharp): bright edge, center line, light points
  ctx=P.near;
  lit(ctx,'A',[98,205,231],G.core,G.coreW,3);lit(ctx,'A',[190,248,255],0.8*G.core,0.6,3);
  const th=W_(G.axisW),flash=a*st.pulse;ctx.fillStyle=axisGradient(ctx);ctx.fillRect(0,mid-th/2,W,th);
  if(flash>0.02){ctx.globalAlpha=Math.min(1,flash*0.8);ctx.fillRect(0,mid-th/2,W,th);ctx.globalAlpha=1} // the axis flashes on onsets
  const flare=1+0.6*flash;halo(ctx,W*0.06,mid,W*0.09*flare,W_(G.axisGlowW),[110,240,255],G.axisGlow*flare);halo(ctx,W*0.945,mid,W*0.03*flare,W_(5),[120,250,255],0.7);halo(ctx,W*0.76,mid,W*0.07*flare,W_(5),[45,110,230],0.45*flare);
  const head=W*frac;ctx.fillStyle='rgba(7,15,24,0.45)';ctx.fillRect(head,mid-th/2,W-head,th);if(frac>0&&frac<1)halo(ctx,head,mid,W_(10),W_(3),[180,245,255],0.9);
  for(const [lx,lh,la] of M.lights){const i=Math.round(lx*n);halo(ctx,X(i),Y(lh*response('A',lv[i])),W_(G.lightR),W_(G.lightR),[160,235,255],la*boost[i])}
};}
