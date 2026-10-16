// Reference renderer for the audioware widget wave (mirrored by AudiowareWave in
// tools/media-widget/main.swift): the live audio wave drawn in the style of the
// Audioware cover. model.json holds the look (gains tuned on the cover, the amplitude
// window of the cover, axis colors).
//
// Silent or paused: a flat line. Playing: the signal itself. advanceAudio(st, levels,
// playing, wave) runs 30 times a second with the 14 band levels (0...1, fast rise, slow
// fall) and wave = {low, mid}: the audio low-passed (~180 Hz) and band-passed (~1 kHz),
// decimated to ~6 kHz, the last 768 points, oldest first. Like an oscilloscope it takes
// the 80 ms window most like the previous frame. The bright edge A is the low signal,
// the second edge B the same 10 ms earlier (a ribbon that twists: wide where the signal
// moves, pinched where both meet), both shaped by the cover's window; crest fans sit on the two highest peaks,
// the dotted jagged edge hangs under the ribbon by |mid| (cusps at its zero crossings),
// spectrum peaks rise where mid is strong, hairs hang under troughs with the bass,
// light follows slope and amplitude, onsets flash. draw(P, W, H, st, progress) paints
// it on four planes {glow, far, mid, near}, composited back to front with blur ~6, 1.2,
// 0.35 and 0 px per 1000 px of width.

const WAVE = {points: 256, window: 480, shift: 60}; // shape resolution; samples shown (80 ms) and B's delay (10 ms) at 6 kHz

function makeAudio() {
  return {t: 0, activity: 0, presence: 0, bands: [], loud: 0, loudSlow: 0, pulse: 0, bass: 0, mids: 0,
    peakLow: 1e-5, peakMid: 1e-5, raw: null, A: null, B: null, M: null, crests: [], spikes: []};
}

function advanceAudio(st, input, playing, wave) {
  const target = playing ? 1 : 0, settling = Math.abs(st.activity - target) > 0.002;
  st.activity = settling ? st.activity + (target - st.activity) * 0.08 : target;
  if (st.bands.length !== input.length) st.bands = input.map(() => 0);
  st.bands = st.bands.map((b, i) => b + (input[i] - b) * (input[i] > b ? 0.6 : 0.18)); // fast attack, softer release
  const mean = a => a.length ? a.reduce((s, v) => s + v, 0) / a.length : 0;
  st.loud = mean(st.bands); st.loudSlow += (st.loud - st.loudSlow) * 0.05;
  st.pulse = Math.max(st.pulse * 0.86, Math.min(1, Math.max(0, (st.loud - st.loudSlow) * 4))); // onsets
  st.bass = mean(st.bands.slice(0, 3)); st.mids = mean(st.bands.slice(3, 9));
  if (playing) st.t += 1 / 30;
  const R = WAVE.points, sig = playing && wave ? signal(st, wave) : null;
  // silence (or no capture, or paused): back to the flat line
  const gate = sig ? Math.max(0, Math.min(1, (sig.rms - 0.002) / 0.008)) : 0;
  st.presence += (gate - st.presence) * (gate > st.presence ? 0.25 : 0.08);
  if (!st.A) { st.A = new Array(R).fill(0); st.B = new Array(R).fill(0); st.M = new Array(R).fill(0); }
  const amp = st.activity * st.presence, size = 0.9 * (0.65 + 0.5 * st.loud);
  const soft = v => Math.tanh(v * 1.1) / Math.tanh(1.1); // round off the loudest swings
  for (let r = 0; r < R; r++) {
    const w = lin(MODEL_WINDOW(), r / (R - 1)) * amp * size;
    const a = sig ? w * soft(sig.a[r]) : 0, b = sig ? w * 0.9 * soft(sig.b[r]) : 0, m = sig ? Math.abs(sig.m[r]) : 0;
    st.A[r] += (a - st.A[r]) * 0.5; st.B[r] += (b - st.B[r]) * 0.5; st.M[r] += (m - st.M[r]) * 0.5;
  }
  // crest fans on the two highest peaks of A, followed from frame to frame
  const found = [];
  for (let r = 2; r < R - 2; r++) {
    const x = r / (R - 1), h = st.A[r];
    if (x > 0.22 && x < 0.84 && h > 0.1 && h >= st.A[r - 1] && h >= st.A[r + 1] && h >= st.A[r - 2] && h >= st.A[r + 2]) found.push({x, h});
  }
  found.sort((p, q) => q.h - p.h);
  const peaks = [];
  for (const p of found) if (peaks.length < 2 && peaks.every(q => Math.abs(q.x - p.x) > 0.1)) peaks.push(p);
  for (const c of st.crests) c.target = 0;
  for (const p of peaks) {
    let c = st.crests.find(c => Math.abs(c.x - p.x) < 0.06);
    if (!c) { c = {x: p.x, H: 0}; st.crests.push(c); }
    c.x += (p.x - c.x) * 0.35; c.target = p.h * (0.45 + 0.5 * st.mids);
  }
  for (const c of st.crests) c.H += (c.target - c.H) * 0.3;
  st.crests = st.crests.filter(c => c.H > 0.005 || c.target > 0).sort((p, q) => q.target - p.target).slice(0, 2);
  // spectrum peaks where the mid signal is strong
  st.spikes = [];
  for (let r = 3; r < R - 3; r++) {
    const x = r / (R - 1), m = st.M[r];
    if (m > 0.35 && lin(MODEL_WINDOW(), x) > 0.25 && m >= st.M[r - 1] && m > st.M[r + 1] && m >= st.M[r - 3] && m > st.M[r + 3]) st.spikes.push({x, m});
  }
  st.spikes = st.spikes.sort((p, q) => q.m - p.m).slice(0, 10);
}

// The window of the decimated signals shown this frame (normalized by slow peaks).
function signal(st, wave) {
  const {window: N, shift: S, points: R} = WAVE, low = wave.low, mid = wave.mid, len = low.length;
  if (len < N + S + 2) return null;
  const at = (arr, o, x) => { const p = o + x * (N - 1), i = Math.min(arr.length - 2, Math.floor(p)), f = p - i; return arr[i] * (1 - f) + arr[i + 1] * f; };
  // oscilloscope trigger: the offset most like the last frame, else the first rising zero crossing
  const maxOff = len - N - S;
  let best = -1;
  if (st.raw) {
    let err = Infinity;
    for (let o = 0; o <= maxOff; o += 2) {
      let e = 0;
      for (let k = 0; k < 32; k++) { const d = at(low, o + S, k / 31) / st.peakLow - st.raw[k]; e += d * d; }
      if (e < err) { err = e; best = o; }
    }
  }
  if (best < 0) { best = 0; for (let o = 0; o < maxOff; o++) if (low[o + S] <= 0 && low[o + S + 1] > 0) { best = o; break; } }
  // normalized by slow peaks of the shown part, so the wave fills the window
  let pl = 1e-6, pm = 1e-6, rms = 0;
  for (let i = best; i < best + S + N; i++) { pl = Math.max(pl, Math.abs(low[i])); pm = Math.max(pm, Math.abs(mid[i])); }
  st.peakLow = Math.max(pl, st.peakLow * 0.92, 1e-5); st.peakMid = Math.max(pm, st.peakMid * 0.92, 1e-5);
  st.raw = Array.from({length: 32}, (_, k) => at(low, best + S, k / 31) / st.peakLow);
  for (let i = 0; i < N; i++) { const v = low[best + S + i], m = mid[best + S + i]; rms += v * v + m * m; }
  const out = {a: [], b: [], m: [], rms: Math.sqrt(rms / N)};
  for (let r = 0; r < R; r++) {
    const x = r / (R - 1);
    out.a.push(at(low, best + S, x) / st.peakLow); out.b.push(at(low, best, x) / st.peakLow); out.m.push(at(mid, best + S, x) / st.peakMid);
  }
  return out;
}

const lin = (P, x) => { if (x <= P[0][0]) return P[0][1]; if (x >= P[P.length - 1][0]) return P[P.length - 1][1]; let i = 1; while (P[i][0] < x) i++; const a = P[i - 1], b = P[i]; return a[1] + (b[1] - a[1]) * (x - a[0]) / (b[0] - a[0]); };
let MODEL_WINDOW = () => [[0, 0], [1, 0]];

function makeWave(M) {
MODEL_WINDOW = () => M.window;
const hash = i => { const s = Math.sin(i * 12.9898 + 78.233) * 43758.5453; return s - Math.floor(s); };
// crest outline over A: a steep straight rise to the apex, a long fall (the cover's crests)
const crestKernel = d => d < -0.03 || d > 0.12 ? 0 : d < 0 ? 1 + d / 0.03 : Math.pow(1 - d / 0.12, 2);
return function draw(P, W, H, st = makeAudio(), frac = 1) {
  const G = M.gain, s = W / 1000, n = Math.round(W / 1.5), mid = H * 0.555, unit = H * 0.525;
  const amp = st.activity * st.presence, xs = Array.from({length: n + 1}, (_, i) => i / n);
  const R = st.A ? st.A.length : 0;
  const sample = arr => xs.map(x => { if (!R) return 0; const p = x * (R - 1), k = Math.min(R - 2, Math.floor(p)), f = p - k; return arr[k] * (1 - f) + arr[k + 1] * f; });
  const L = {A: sample(st.A || []), B: sample(st.B || [])}, Mabs = sample(st.M || []);
  const win = xs.map(x => lin(M.window, x));
  const top = xs.map((_, i) => Math.max(L.A[i], L.B[i])), bot = xs.map((_, i) => Math.min(L.A[i], L.B[i]));
  L.D = xs.map((_, i) => bot[i] - win[i] * amp * (0.05 + 0.28 * Mabs[i])); // dotted jagged edge under the ribbon
  st.crests.forEach((c, k) => { L['C' + (k + 1)] = xs.map((x, i) => { const d = x - c.x - 0.03, v = crestKernel(d); return v > 0 || (d >= -0.03 && d <= 0.12) ? L.A[i] + c.H * v : NaN; }); });
  // light: slope and amplitude of the line (the cover's flanks and crests glow)
  const lightOf = h => h.map((v, i) => { if (isNaN(v)) return 0; const j = Math.min(n, i + 1), k = Math.max(0, i - 1), slope = Math.abs((h[j] - h[k]) / ((j - k) / n)) || 0;
    return Math.min(1, 0.3 + 0.9 * Math.abs(v) + 0.05 * slope) * Math.min(1, amp * 4); });
  const light = {A: lightOf(L.A)}; light.B = light.A.map(v => v * 0.8); light.D = win.map(w => 0.55 * Math.min(1, amp * 4) * (w > 0.05 ? 1 : 0));
  for (const k of ['C1', 'C2']) if (L[k]) light[k] = L[k].map(v => isNaN(v) ? 0 : 0.55 * Math.min(1, amp * 4));
  const fill = light.A.map(v => 0.12 + 0.45 * v), inner = light.A.map(v => 0.25 + 0.8 * v), outer = light.A.map(v => 0.15 + 0.7 * v);
  const boost = xs.map(() => 1 + amp * 0.45 * st.pulse); // onsets flash
  const names = Object.keys(L);
  const clip = h => { const m = Math.abs(h); return m <= 0.85 ? h : Math.sign(h) * (0.85 + 0.2 * Math.tanh((m - 0.85) / 0.2)); };
  const X = i => i / n * W, Y = h => mid - clip(h) * unit, W_ = w => Math.max(0.5, w * s);
  const rgba = (c, a) => `rgba(${c[0]},${c[1]},${c[2]},${Math.max(0, Math.min(1, a))})`;
  const poly = (ctx, arr, from, to) => { ctx.beginPath(); let first = true; for (let i = from; i <= to; i++) { if (isNaN(arr[i])) { first = true; continue; } first ? ctx.moveTo(X(i), Y(arr[i])) : ctx.lineTo(X(i), Y(arr[i])); first = false; } };
  // a line drawn in chunks so its brightness follows its light
  const lit = (ctx, k, col, alpha, width, step = 4, dash, prof) => { const h = L[k], li = prof || light[k]; if (!h) return; ctx.lineWidth = W_(width); ctx.lineCap = 'round'; if (dash) ctx.setLineDash(dash.map(W_));
    for (let i = 0; i < n; i += step) { const j = Math.min(n, i + step); if (isNaN(h[i]) || isNaN(h[j])) continue; const a = alpha * (li[i] + li[j]) / 2 * (boost[i] + boost[j]) / 2; if (a < 0.02) continue; poly(ctx, h, i, j); ctx.strokeStyle = rgba(col, a); ctx.stroke(); } ctx.setLineDash([]); };
  const halo = (ctx, cx, cy, rx, ry, col, a) => { if (a <= 0) return; ctx.save(); ctx.translate(cx, cy); ctx.scale(rx / ry, 1); const g = ctx.createRadialGradient(0, 0, 0, 0, 0, ry); g.addColorStop(0, rgba(col, a)); g.addColorStop(1, rgba(col, 0)); ctx.fillStyle = g; ctx.fillRect(-ry, -ry, 2 * ry, 2 * ry); ctx.restore(); };
  // hairlines batched by color and alpha (rounded to 0.05)
  const hair = (ctx, segs, width) => { ctx.lineWidth = width; const buckets = {}; for (const [x0, y0, x1, y1, c, a] of segs) { const key = c + '|' + Math.round(Math.min(1, a) * 20) / 20; (buckets[key] = buckets[key] || []).push([x0, y0, x1, y1]); }
    for (const key in buckets) { const [c, a] = key.split('|'); if (+a <= 0) continue; ctx.strokeStyle = `rgba(${c},${a})`; ctx.beginPath(); for (const [x0, y0, x1, y1] of buckets[key]) { ctx.moveTo(x0, y0); ctx.lineTo(x1, y1); } ctx.stroke(); } };
  const ribbon = ctx => { ctx.beginPath(); for (let i = 0; i <= n; i++) ctx.lineTo(X(i), Y(top[i])); for (let i = n; i >= 0; i--) ctx.lineTo(X(i), Y(bot[i])); ctx.closePath(); };
  const thick = xs.map((_, i) => Math.min(1, (top[i] - bot[i]) / 0.25));

  // ---- GLOW plane (strong blur): ribbon light per column, light the edges pour inside it, wide halos
  let ctx = P.glow;
  if (amp > 0.01) halo(ctx, W * 0.53, mid, W * 0.40, H * 0.42, [22, 45, 80], 0.45 * amp);
  const cols = [];
  for (let i = 0; i <= n; i++) { if (top[i] - bot[i] < 0.005) continue;
    if (top[i] > 0) cols.push([X(i), Y(top[i]), X(i), Y(Math.max(0, bot[i])), '40,110,195', G.fill * fill[i] * boost[i]]);
    if (bot[i] < 0) cols.push([X(i), Y(Math.min(0, top[i])), X(i), Y(bot[i]), '40,110,195', G.fill * fill[i] * boost[i]]); }
  hair(ctx, cols, W / n + 0.5 * s);
  ctx.save(); ribbon(ctx); ctx.clip();
  for (const k of ['A', 'B']) { const g = G.inner * (k === 'A' ? 1 : G.innerB), p = k === 'A' ? inner : undefined; lit(ctx, k, [45, 185, 235], g, G.innerW, 6, null, p); lit(ctx, k, [90, 215, 250], g, G.innerW * 0.4, 6, null, p); }
  lit(ctx, 'B', [50, 140, 230], G.ramp, 40, 6);
  ctx.restore();
  for (const k of names) lit(ctx, k, [35, 165, 230], G.outer * (k === 'A' ? 1 : G.outerB), G.outerW, 6, null, k === 'A' ? outer : undefined);
  // the axis glows where it is free, like the flat ends of the cover
  hair(ctx, xs.map((_, i) => [X(i), mid - W_(4), X(i), mid + W_(4), '110,235,255', G.axisHalo * 0.6 * (1 - thick[i])]), W / n + 0.5 * s);

  // ---- FAR plane (soft): tight glows
  ctx = P.far;
  for (const k of names) lit(ctx, k, [60, 195, 240], G.far * (k === 'A' ? 1 : G.outerB), G.farW, 4);

  // ---- MID plane (barely soft): hatch, spectrum peaks, hanging hairs, fans, secondary edges
  ctx = P.mid;
  const segs = [];
  for (let i = 0; i <= n; i++) { const r = hash(i + 40); if (top[i] - bot[i] < 0.01) continue;
    const c = r > 0.93 ? '120,210,255' : '55,125,215', a = G.hatch * fill[i] * (0.25 + 1.1 * r) * boost[i] * 2;
    segs.push([X(i), Y(top[i]), X(i), Y(bot[i]), c, a]); }
  for (let i = 0; i <= n; i++) if (hash(i + 61) < 0.5 && bot[i] - L.D[i] > 0.02) segs.push([X(i), Y(bot[i]), X(i), Y(L.D[i]), '55,125,215', 0.1 * light.D[i] * boost[i]]); // sparse under the ribbon
  hair(ctx, segs, W_(0.55));
  const sp = [];
  for (const p of st.spikes) { // narrow glowing peaks with concave flanks, the tallest go on as a hairline with a light tip
    const i = Math.round(p.x * n), b = top[i], tip = b + (0.06 + 0.45 * p.m) * amp * win[i] * (0.6 + 0.8 * st.mids); if (tip - b < 0.03) continue;
    const th = Math.min(0.22, tip - b), hw = (0.003 + 0.02 * th) * W, ax = X(i), ay = Y(b + th), pk = G.peak * boost[i];
    const g = ctx.createLinearGradient(0, Y(b), 0, ay); g.addColorStop(0, rgba([70, 170, 245], pk)); g.addColorStop(1, rgba([70, 170, 245], pk * 0.3));
    ctx.beginPath(); ctx.moveTo(ax - hw, Y(b)); ctx.quadraticCurveTo(ax - hw * 0.15, Y(b + th * 0.25), ax, ay); ctx.quadraticCurveTo(ax + hw * 0.15, Y(b + th * 0.25), ax + hw, Y(b)); ctx.closePath(); ctx.fillStyle = g; ctx.fill();
    ctx.strokeStyle = rgba([110, 210, 250], pk * 1.2); ctx.lineWidth = W_(0.5); ctx.stroke();
    if (tip - b > th + 0.02) { sp.push([ax, ay, ax, Y(tip), '110,200,250', G.spike * boost[i]]); if (tip > 0.45) halo(ctx, ax, Y(tip), W_(2), W_(2), [170, 240, 255], 0.5 * boost[i]); } }
  for (let i = 2; i <= n - 2; i++) { // hairs over strong mids, hanging under troughs with the bass
    const up = Mabs[i] * win[i] * amp * 0.8, down = Math.min(1, -bot[i] * 2.5) * amp;
    if (hash(i + 7) < up) { const len = Math.pow(hash(i + 11), 2) * 0.3 * (0.5 + Mabs[i]); sp.push([X(i), Y(top[i]), X(i), Y(top[i] + len), '60,140,225', G.hairs * (0.4 + 0.6 * hash(i + 3)) * boost[i]]); }
    if (bot[i] < -0.1 && hash(i + 17) < down * 0.7) { const len = (0.04 + Math.pow(hash(i + 19), 1.5) * 0.22) * (0.5 + st.bass), a = G.hairs * (0.4 + 0.6 * hash(i + 23)) * boost[i], m = bot[i] - len / 2;
      sp.push([X(i), Y(bot[i]), X(i), Y(m), '60,140,225', a], [X(i), Y(m), X(i), Y(bot[i] - len), '60,140,225', a * 0.4]); }
    if (bot[i] < -0.18 && bot[i] <= bot[i - 1] && bot[i] < bot[i + 1] && bot[i] <= bot[i - 2] && bot[i] < bot[i + 2]) { // the long hairs at the bottom of troughs
      const tip = bot[i] - (0.12 + 0.25 * st.bass) * amp, m = (bot[i] + tip) / 2;
      sp.push([X(i), Y(bot[i]), X(i), Y(m), '90,170,240', G.spike * boost[i]], [X(i), Y(m), X(i), Y(tip), '90,170,240', G.spike * 0.45 * boost[i]]); } }
  hair(ctx, sp, W_(0.6));
  for (const [k, alpha] of [['C1', G.fanC1], ['C2', G.fan]]) { const hs = L[k]; if (!hs) continue; // nested contours from A up to the crest (moire)
    for (let f = 1; f <= 22; f++) { const q = f / 22; ctx.beginPath(); let first = true;
      for (let i = 0; i <= n; i++) { if (isNaN(hs[i])) continue; const h = L.A[i] + (hs[i] - L.A[i]) * q; first ? ctx.moveTo(X(i), Y(h)) : ctx.lineTo(X(i), Y(h)); first = false; }
      ctx.strokeStyle = rgba([75, 155, 230], alpha * (0.35 + 0.65 * q) * Math.min(1, amp * 4)); ctx.lineWidth = W_(0.5); ctx.stroke(); } }
  lit(ctx, 'B', [98, 205, 231], G.core, G.coreB, 3);
  lit(ctx, 'C1', [120, 215, 245], 0.9, 0.8, 3); lit(ctx, 'C2', [120, 215, 245], 0.9, 0.8, 3);
  lit(ctx, 'D', [120, 215, 245], 1.0, 1.1, 3, [1.4, 2.2]);

  // ---- NEAR plane (sharp): bright edge, center line, light points
  ctx = P.near;
  lit(ctx, 'A', [98, 205, 231], G.core, G.coreW, 3); lit(ctx, 'A', [190, 248, 255], 0.8 * G.core, 0.6, 3);
  // center line: bright cyan where free (the flat line), royal blue and dim under the ribbon
  const th = W_(G.axisW), flash = amp * st.pulse, cyan = [110, 240, 255], royal = [40, 90, 200];
  hair(ctx, xs.map((_, i) => { const t = Math.round(thick[i] * 6) / 6, c = cyan.map((v, k) => Math.round(v + (royal[k] - v) * t)); return [X(i), mid - th / 2, X(i), mid + th / 2, c.join(','), (0.95 - 0.55 * t) * (1 + 0.8 * flash)]; }), W / n + 0.5 * s);
  const flare = 1 + 0.6 * flash;
  halo(ctx, W * 0.06, mid, W * 0.09 * flare, W_(G.axisGlowW), [110, 240, 255], G.axisGlow * flare); halo(ctx, W * 0.945, mid, W * 0.03 * flare, W_(5), [120, 250, 255], 0.7);
  if (amp > 0.01) halo(ctx, W * 0.76, mid, W * 0.07 * flare, W_(5), [45, 110, 230], 0.45 * amp * flare);
  const head = W * frac; ctx.fillStyle = 'rgba(7,15,24,0.45)'; ctx.fillRect(head, mid - th / 2, W - head, th); if (frac > 0 && frac < 1) halo(ctx, head, mid, W_(10), W_(3), [180, 245, 255], 0.9);
  for (let i = 1; i < n; i++) { // light points where the edges cross and on crest tops
    if ((L.A[i] - L.B[i]) * (L.A[i + 1] - L.B[i + 1]) < 0 && Math.abs(L.A[i]) > 0.04) halo(ctx, X(i), Y(L.A[i]), W_(G.lightR), W_(G.lightR), [160, 235, 255], 0.45 * boost[i] * Math.min(1, amp * 4)); }
  for (const k of ['C1', 'C2']) { const hs = L[k]; if (!hs) continue; let best = -1; for (let i = 0; i <= n; i++) if (!isNaN(hs[i]) && (best < 0 || hs[i] > hs[best])) best = i;
    if (best >= 0) halo(ctx, X(best), Y(hs[best]), W_(G.lightR * 0.6), W_(G.lightR * 0.6), [160, 235, 255], 0.35 * Math.min(1, amp * 4)); }
};
}
