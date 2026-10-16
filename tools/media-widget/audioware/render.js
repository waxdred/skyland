// Reference renderer for the audioware widget wave (mirrored by AudiowareWave in
// tools/media-widget/main.swift). Model: model.json, measured on the cover.
// draw(P, W, H, t, level, progress): P = {glow, far, mid, near} 2D contexts,
// composited back to front with blur ~6, 1.2, 0.35 and 0 px per 1000 px of width.
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
  return cache={n,xs,L,fillUp:xs.map(x=>lin(M.fill.up,x)),fillDown:xs.map(x=>lin(M.fill.down,x)),innerA:xs.map(x=>lin(M.glowA.inner,x)),outerA:xs.map(x=>lin(M.glowA.outer,x))};
}
return function draw(P,W,H,t,level,frac){
  const G=M.gain, s=W/1000, n=Math.round(W/1.5), B=base(n), mid=H*0.555, unit=H*0.525;
  const gain=x=>0.55+0.6*level, wob=(x,k)=>1+0.06*(Math.sin(t*0.9+x*23+k)-Math.sin(x*23+k));
  const L={};for(const k of names){L[k]=B.L[k].h.map((h,i)=>{const x=B.xs[i];return h*gain(x)*wob(x,k.charCodeAt(0))})}
  const X=i=>i/n*W, Y=h=>mid-Math.max(-1.05,Math.min(1.05,h))*unit, W_=w=>Math.max(0.5,w*s);
  const top=[],bot=[];
  for(let i=0;i<=n;i++){let a=-9,b=9;for(const k of names){const h=L[k][i];if(isNaN(h)||isCrest(k,B.xs[i]))continue;a=Math.max(a,h);b=Math.min(b,h)}top.push(a===-9?0:a);bot.push(b===9?0:b)}
  const rgba=(c,a)=>`rgba(${c[0]},${c[1]},${c[2]},${Math.max(0,Math.min(1,a))})`;
  const poly=(ctx,arr,from,to)=>{ctx.beginPath();let first=true;for(let i=from;i<=to;i++){if(isNaN(arr[i])){first=true;continue}first?ctx.moveTo(X(i),Y(arr[i])):ctx.lineTo(X(i),Y(arr[i]));first=false}};
  // a line drawn in chunks so its brightness follows its light profile
  const lit=(ctx,k,col,alpha,width,step=4,dash,prof)=>{const h=L[k],li=prof||B.L[k].light;ctx.lineWidth=W_(width);ctx.lineCap='round';if(dash)ctx.setLineDash(dash.map(W_));
    for(let i=0;i<n;i+=step){const j=Math.min(n,i+step);if(isNaN(h[i])||isNaN(h[j]))continue;const a=alpha*(li[i]+li[j])/2;if(a<0.02)continue;poly(ctx,h,i,j);ctx.strokeStyle=rgba(col,a);ctx.stroke()}ctx.setLineDash([])};
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
    if(top[i]>0)cols.push([X(i),Y(top[i]),X(i),Y(Math.max(0,bot[i])),'40,110,195',G.fill*B.fillUp[i]]);
    if(bot[i]<0)cols.push([X(i),Y(Math.min(0,top[i])),X(i),Y(bot[i]),'40,110,195',G.fill*B.fillDown[i]]);}
  hair(ctx,cols,(W/n+0.5)/s);
  ctx.save();ribbon(ctx);ctx.clip();
  for(const k of names){const g=G.inner*(k==='A'?1:G.innerB),p=k==='A'?B.innerA:undefined;lit(ctx,k,[45,185,235],g,G.innerW,6,null,p);lit(ctx,k,[90,215,250],g,G.innerW*0.4,6,null,p)}
  lit(ctx,'B',[50,140,230],G.ramp,40,6);lit(ctx,'T',[50,140,230],G.ramp,40,6);
  ctx.restore();
  for(const k of names)lit(ctx,k,[35,165,230],G.outer*(k==='A'?1:G.outerB),G.outerW,6,null,k==='A'?B.outerA:undefined);
  ctx.fillStyle=axisGradient(ctx);ctx.globalAlpha=G.axisHalo;ctx.fillRect(0,mid-W_(4),W,W_(8));ctx.globalAlpha=1;

  // haze behind the cluster of spectrum peaks (a luminous jagged mountain on the cover)
  ctx.beginPath();let hz=true;for(let i=0;i<=n;i++){const x=B.xs[i];if(x<M.haze[0][0]||x>M.haze[M.haze.length-1][0])continue;const h=Math.max(top[i],lin(M.haze,x)*gain(x));hz?ctx.moveTo(X(i),Y(h)):ctx.lineTo(X(i),Y(h));hz=false}
  for(let i=n;i>=0;i--){const x=B.xs[i];if(x<M.haze[0][0]||x>M.haze[M.haze.length-1][0])continue;ctx.lineTo(X(i),Y(top[i]))}ctx.closePath();
  const hg=ctx.createLinearGradient(0,Y(0.9),0,Y(0.3));hg.addColorStop(0,rgba([60,150,240],0));hg.addColorStop(1,rgba([60,150,240],G.haze));ctx.fillStyle=hg;ctx.fill();

  // ---- FAR plane (soft): secondary glows
  ctx=P.far;
  for(const k of names)lit(ctx,k,[60,195,240],G.far*(k==='A'?1:G.outerB),G.farW,4);

  // ---- MID plane (barely soft): hatch, spikes, hanging hairs, fans, secondary edges
  ctx=P.mid;
  const segs=[];
  for(let i=0;i<=n;i++){const r=hash(i+40);if(top[i]-bot[i]<0.01)continue;
    const bright=r>0.93, c=bright?'120,210,255':'55,125,215', up=G.hatch*B.fillUp[i]*(0.25+1.1*r), dn=G.hatch*B.fillDown[i]*(0.25+1.1*hash(i+91));
    if(top[i]>0)segs.push([X(i),Y(top[i]),X(i),Y(Math.max(0,bot[i])),c,up]);
    if(bot[i]<0)segs.push([X(i),Y(Math.min(0,top[i])),X(i),Y(bot[i]),c,dn]);}
  hair(ctx,segs,0.55);
  // spectrum peaks: narrow glowing triangles on the top edge, the tallest prolonged by a hairline with a light tip
  const sp=[];
  for(const [sx,sh] of M.spikesUp){const i=Math.round(sx*n),b=top[i],tip=sh*gain(sx)*(1+0.12*(Math.sin(t*1.7+sx*40)-Math.sin(sx*40)));if(tip-b<0.03)continue;
    const th=Math.min(0.22,tip-b),hw=(0.003+0.02*th)*W,ax=X(i),ay=Y(b+th);
    const g=ctx.createLinearGradient(0,Y(b),0,ay);g.addColorStop(0,rgba([70,170,245],G.peak));g.addColorStop(1,rgba([70,170,245],G.peak*0.3));
    // concave flanks, like a resonance peak
    ctx.beginPath();ctx.moveTo(ax-hw,Y(b));ctx.quadraticCurveTo(ax-hw*0.15,Y(b+th*0.25),ax,ay);ctx.quadraticCurveTo(ax+hw*0.15,Y(b+th*0.25),ax+hw,Y(b));ctx.closePath();ctx.fillStyle=g;ctx.fill();
    ctx.strokeStyle=rgba([110,210,250],G.peak*1.2);ctx.lineWidth=W_(0.5);ctx.stroke();
    if(tip-b>th+0.02){sp.push([ax,ay,ax,Y(tip),'110,200,250',G.spike]);if(tip>0.5)halo(ctx,ax,Y(tip),W_(2),W_(2),[170,240,255],0.5)}}
  for(const [sx,sh] of M.spikesDown){const i=Math.round(sx*n),b=bot[i],tip=sh*gain(sx);if(b-tip<0.03)continue;const m=(b+tip)/2;
    sp.push([X(i),Y(b),X(i),Y(m),'90,170,240',G.spike],[X(i),Y(m),X(i),Y(tip),'90,170,240',G.spike*0.45])}
  const above=x=>0.6*gauss(x,0.40,0.03)+0.4*gauss(x,0.60,0.02)+0.4*gauss(x,0.30,0.01)+0.3*gauss(x,0.74,0.01);
  const below=x=>Math.min(1,gauss(x,0.40,0.02)+gauss(x,0.52,0.025)+0.4*gauss(x,0.66,0.04));
  for(let i=0;i<=n;i++){const x=B.xs[i];
    if(hash(i+7)<above(x)){const len=Math.pow(hash(i+11),2)*0.3*(0.6+level),r=hash(i+3);sp.push([X(i),Y(top[i]),X(i),Y(top[i]+len),'60,140,225',G.hairs*(0.4+0.6*r)])}
    if(hash(i+17)<below(x)){const len=(0.04+Math.pow(hash(i+19),1.5)*0.22)*(0.6+level),r=hash(i+23),m=bot[i]-len/2;
      sp.push([X(i),Y(bot[i]),X(i),Y(m),'60,140,225',G.hairs*(0.4+0.6*r)],[X(i),Y(m),X(i),Y(bot[i]-len),'60,140,225',G.hairs*0.4*(0.4+0.6*r)])}}
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
  const th=W_(G.axisW);ctx.fillStyle=axisGradient(ctx);ctx.fillRect(0,mid-th/2,W,th);
  halo(ctx,W*0.06,mid,W*0.09,W_(G.axisGlowW),[110,240,255],G.axisGlow);halo(ctx,W*0.945,mid,W*0.03,W_(5),[120,250,255],0.7);halo(ctx,W*0.76,mid,W*0.07,W_(5),[45,110,230],0.45);
  const head=W*frac;ctx.fillStyle='rgba(7,15,24,0.45)';ctx.fillRect(head,mid-th/2,W-head,th);if(frac>0&&frac<1)halo(ctx,head,mid,W_(10),W_(3),[180,245,255],0.9);
  for(const [lx,lh,a] of M.lights){const i=Math.round(lx*n);halo(ctx,X(i),Y(lh*gain(lx)),W_(G.lightR),W_(G.lightR),[160,235,255],a)}
};}
