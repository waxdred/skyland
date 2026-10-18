/// The Metal shader of MetalGlass, compiled when the bar starts. One full-window pass: each
/// pixel finds the glass shapes' distance field (rounded rectangles, melted together when
/// closer than `spacing`), and inside it looks at the captured backdrop through a lens.
let glassShader = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 size;        // the window, pixels
    float2 origin;      // the window's top-left in the captured picture, pixels
    float2 texSize;     // the captured picture, pixels
    float scale;        // pixels per point
    int count;
    float refraction;   // points
    float blur;         // points
    float saturation;
    float dark;
    float spacing;      // pixels
};

struct Shape {
    float4 rect;        // x, y, width, height: pixels, top-left origin
    float4 tint;        // rgb and its strength
    float radius;       // pixels
    float clear;        // 1: clear glass, 2: a lens inside the others, 3: a hover drop (a lighter lens)
    float2 pad;         // x: a lens's lift, 0...1, while it moves
    float4 tail;        // a lens: the drop it leaves behind while it moves (0 width: none)
};

struct VOut {
    float4 position [[position]];
    float2 uv;
};

vertex VOut glass_vertex(uint id [[vertex_id]]) {
    float2 p = float2((id & 1) ? 1.0 : -1.0, (id & 2) ? 1.0 : -1.0);
    VOut v;
    v.position = float4(p, 0.0, 1.0);
    v.uv = float2((p.x + 1.0) * 0.5, (1.0 - p.y) * 0.5);
    return v;
}

// the signed distance to a rounded rectangle centred on 0: below 0 inside. Its corners are
// continuous (a superellipse, as Apple's), a capsule's ends stay round
static float box(float2 p, float2 half_size, float r) {
    float2 q = abs(p) - half_size + r;
    if (q.x > 0.0 && q.y > 0.0 && r < min(half_size.x, half_size.y) - 0.5) {
        return pow(pow(q.x, 4.0) + pow(q.y, 4.0), 0.25) - r;
    }
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// a smooth minimum: two shapes within k of each other flow into one
static float smooth_min(float a, float b, float k) {
    if (k <= 0.0) return min(a, b);
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}

static float shape_distance(Shape s, float2 px) {
    float2 half_size = s.rect.zw * 0.5;
    float r = min(s.radius, min(half_size.x, half_size.y));
    return box(px - (s.rect.xy + half_size), half_size, r);
}

// a lens with the drop it leaves behind: the drop where it was, and a neck of liquid from
// there to the lens, thick at both ends and pinched in the middle, that thins as the drop
// shrinks and snaps; all melted together, so the lens looks pulled to its new item
static float lens_distance(Shape s, float2 px) {
    float d = shape_distance(s, px);
    if (s.tail.z <= 0.0) return d;
    float2 tail_half = s.tail.zw * 0.5;
    float2 a = s.tail.xy + tail_half, b = s.rect.xy + s.rect.zw * 0.5;
    float dt = box(px - a, tail_half, min(tail_half.x, tail_half.y));
    float head_r = s.rect.w * 0.5;
    float life = clamp(s.tail.w / max(s.rect.w, 1.0), 0.0, 1.0);   // the drop's height / the lens's
    float k = 0.45 * s.rect.w;
    float h0 = max(k - abs(d - dt), 0.0) / k;
    float shape = min(d, dt) - h0 * h0 * h0 * k / 6.0;
    float neck_life = smoothstep(0.45, 0.85, life);            // snaps when the drop is small
    if (neck_life > 0.0) {
        float2 pa = px - a, ba = b - a;
        float t = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-3), 0.0, 1.0);
        float pinch = 0.10 + 0.22 * neck_life;                    // the middle, of the head's radius
        float r = head_r * (pinch + (life * 0.9 - pinch) * pow(1.0 - t, 3.0) + (0.85 - pinch) * pow(t, 3.0));
        float dn = length(pa - ba * t) - r;
        float kn = 0.30 * s.rect.w;
        float hn = max(kn - abs(shape - dn), 0.0) / kn;
        shape = min(shape, dn) - hn * hn * hn * kn / 6.0;
    }
    return shape;
}

// the glass field at px; `nearest` is the shape it is closest to
static float field(float2 px, constant Shape* shapes, int count, float k, thread int& nearest) {
    float d = 1e5;
    float best = 1e5;
    nearest = 0;
    bool first = true;
    for (int i = 0; i < count; i++) {
        if (shapes[i].clear > 1.5) continue;    // lenses are drawn over the glass, not melted in
        float di = shape_distance(shapes[i], px);
        if (di < best) { best = di; nearest = i; }
        d = first ? di : smooth_min(d, di, k);
        first = false;
    }
    return d;
}

// brighter by `k` (0...1 of the way to white in lightness) keeping the hue and the chroma:
// light that picks up the color behind, not a white wash
static float3 lighten(float3 c, float k) {
    float l = dot(c, float3(0.2126, 0.7152, 0.0722));
    float target = l + (1.0 - l) * clamp(k, 0.0, 1.0);
    float3 r = c * (target / max(l, 0.02));
    float m = max(r.r, max(r.g, r.b));
    if (m > 1.0) r /= m;                                   // past white: as bright as it goes...
    float lr = dot(r, float3(0.2126, 0.7152, 0.0722));
    return mix(r, float3(1.0), clamp((target - lr) / max(1.0 - lr, 1e-3), 0.0, 1.0)); // ...then whiter
}

static float3 saturate_by(float3 c, float k) {
    float l = dot(c, float3(0.2126, 0.7152, 0.0722));
    return clamp(mix(float3(l), c, 1.0 + k), 0.0, 1.0);
}

// the glass's light at a point `inside` pixels in from its edge, `n` its outward normal:
// a fresnel brightening all around the edge, and glare, two lobes facing the light (top left)
// and the opposite side, that brightens and saturates the color behind
static float3 glass_light(float3 c, float inside, float2 n, float scale, float dark, float strength) {
    float2 light = normalize(float2(-0.55, -0.83));
    float fresnel = pow(clamp(1.0 - inside / (3.0 * scale), 0.0, 1.0), 3.0);
    float facing = max(dot(n, light), 0.0), opposite = max(dot(n, -light), 0.0);
    float lobes = pow(facing, 1.5) + 0.55 * pow(opposite, 1.5);
    float glare = lobes * pow(clamp(1.0 - inside / (7.0 * scale), 0.0, 1.0), 2.5);
    c = lighten(c, strength * (fresnel * (dark > 0.5 ? 0.28 : 0.38) + glare * 0.55));
    return saturate_by(c, strength * glare * 0.45);
}

constant float2 taps[12] = {
    float2(-0.326, -0.406), float2(-0.840, -0.074), float2(-0.696, 0.457), float2(-0.203, 0.621),
    float2(0.962, -0.195), float2(0.473, -0.480), float2(0.519, 0.767), float2(0.185, -0.893),
    float2(0.507, 0.064), float2(0.896, 0.412), float2(-0.322, -0.933), float2(-0.792, -0.598)
};

// the backdrop around a point (picture pixels), blurred over `radius` pixels
static float3 backdrop_at(texture2d<float> t, sampler s, float2 at, float radius, float2 texSize) {
    float3 sum = t.sample(s, at / texSize).rgb;
    for (int i = 0; i < 12; i++) sum += t.sample(s, (at + taps[i] * radius) / texSize).rgb;
    return sum / 13.0;
}

fragment float4 glass_fragment(VOut in [[stage_in]],
                               texture2d<float> backdrop [[texture(0)]],
                               constant Uniforms& u [[buffer(0)]],
                               constant Shape* shapes [[buffer(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 px = in.uv * u.size;
    int nearest = 0;
    float d = field(px, shapes, u.count, u.spacing, nearest);
    if (d > 1.0) return float4(0.0);
    float coverage = clamp(0.5 - d, 0.0, 1.0);   // antialiased edge

    // the surface's outward normal, from the field around
    int ignored = 0;
    float e = 0.75;
    float2 n = float2(field(px + float2(e, 0.0), shapes, u.count, u.spacing, ignored) - field(px - float2(e, 0.0), shapes, u.count, u.spacing, ignored),
                      field(px + float2(0.0, e), shapes, u.count, u.spacing, ignored) - field(px - float2(0.0, e), shapes, u.count, u.spacing, ignored));
    n = n / max(length(n), 1e-4);

    Shape sh = shapes[nearest];
    float2 half_size = sh.rect.zw * 0.5;
    float clear = sh.clear;
    float inside = -d;                                         // pixels in from the edge
    // the lens: `depth` at the edge, fading to nothing `band` in, band = 2.2 * depth so its
    // slope (2 * depth / band) stays under 1: what is behind is magnified toward the edge,
    // never folded back into a mirror image. Both fit in the shape's half height.
    float half_min = max(min(half_size.x, half_size.y), 1.0);
    float depth = min(u.refraction * u.scale * (clear > 0.5 ? 1.25 : 1.0), half_min / 2.2);
    float band = max(depth * 2.2, 1.0);
    float lens = pow(clamp(1.0 - inside / band, 0.0, 1.0), 2.0);   // 1 at the edge, 0 from band in
    float bend = lens * depth;
    float2 at = px + u.origin - n * bend;
    float blur = u.blur * u.scale * (clear > 0.5 ? 0.4 : 1.0);
    float split = bend * 0.07;                                  // colors part where it bends most
    float3 color;
    color.r = backdrop_at(backdrop, s, at - n * split, blur, u.texSize).r;
    color.g = backdrop_at(backdrop, s, at, blur, u.texSize).g;
    color.b = backdrop_at(backdrop, s, at + n * split, blur, u.texSize).b;

    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    color = mix(float3(luma), color, u.saturation);

    // the glass's own light: dimmer in dark mode, milkier in light mode; then its tint
    float density = clear > 0.5 ? 0.4 : 1.0;
    color = u.dark > 0.5 ? mix(color, color * 0.80 + 0.05, density) : mix(color, color * 0.88 + 0.14, density);
    color = mix(color, sh.tint.rgb, sh.tint.a);

    // its light: fresnel all around, glare from the top left and opposite, in the color behind
    color = glass_light(color, inside, n, u.scale, u.dark, clear > 0.5 ? 0.7 : 1.0);
    // a faint inner shadow along the bottom
    color *= 1.0 - 0.10 * lens * max(n.y, 0.0);

    // lenses: a thicker drop of glass over a selection (and, lighter, under the mouse), as
    // Apple's tab bars. What is behind magnified and bent at its rim, a light frost at rest
    // that clears while it moves (lifted), a sharp specular rim where the light hits and a
    // softer one opposite, a shade inside along its bottom and around it outside
    for (int i = 0; i < u.count; i++) {
        Shape ls = shapes[i];
        if (ls.clear < 1.5) continue;
        float weight = ls.clear > 2.5 ? 0.55 : 1.0;              // a hover drop: lighter
        float lift = ls.pad.x;                                   // 0 at rest, up to 1 while it moves
        float dl = lens_distance(ls, px);
        float shade_out = (0.14 + 0.10 * lift) * weight * (1.0 - smoothstep(0.0, (3.5 + 4.0 * lift) * u.scale, max(dl, 0.0))) * step(0.0, dl);
        color *= 1.0 - shade_out;
        if (dl > 1.0) continue;
        float cl = clamp(0.5 - dl, 0.0, 1.0);
        float2 c = ls.rect.xy + ls.rect.zw * 0.5;
        float2 ml = float2(lens_distance(ls, px + float2(e, 0.0)) - lens_distance(ls, px - float2(e, 0.0)),
                           lens_distance(ls, px + float2(0.0, e)) - lens_distance(ls, px - float2(0.0, e)));
        ml = ml / max(length(ml), 1e-4);
        float lin = -dl;                                         // pixels in from its edge
        // a dome: magnified in the middle, bent hard at the rim (slope under 1: no mirror)
        float rim_band = max(0.32 * ls.rect.w, 1.0);
        float edge = pow(clamp(1.0 - lin / rim_band, 0.0, 1.0), 2.0);
        float magnify = (1.06 + 0.12 * lift) * weight + (1.0 - weight);
        float bend_px = min((2.5 + 2.5 * lift) * weight * u.scale, rim_band * 0.45);
        float2 lat = c + (px - c) / magnify - ml * edge * bend_px + u.origin;
        float split = edge * bend_px * 0.10;
        float3 lc;
        lc.r = backdrop_at(backdrop, s, lat - ml * split, blur * 0.6, u.texSize).r;
        lc.g = backdrop_at(backdrop, s, lat, blur * 0.6, u.texSize).g;
        lc.b = backdrop_at(backdrop, s, lat + ml * split, blur * 0.6, u.texSize).b;
        lc = saturate_by(lc, u.saturation - 1.0 + 0.15 * weight);
        lc = u.dark > 0.5 ? lc * 0.88 + 0.08 * weight : lc * 0.84 + 0.18 * weight; // lighter than the glass around
        // frost at rest, clear while lifted
        float frost = (u.dark > 0.5 ? 0.22 : 0.40) * weight * (1.0 - smoothstep(0.0, 0.4, lift));
        lc = mix(lc, float3(1.0), frost);
        lc = mix(lc, ls.tint.rgb, ls.tint.a);
        // relief: its light, then a sharp specular line on the lit side and a softer opposite
        lc = glass_light(lc, lin, ml, u.scale, u.dark, (1.3 + 0.6 * lift) * weight);
        float2 light = normalize(float2(-0.55, -0.83));
        float lit = pow(max(dot(ml, light), 0.0), 2.0), back = pow(max(dot(ml, -light), 0.0), 2.0);
        float line = pow(clamp(1.0 - lin / (1.3 * u.scale), 0.0, 1.0), 2.0);
        lc = lighten(lc, line * (0.75 * lit + 0.35 * back) * weight);
        // a shade inside along the bottom: it stands up from the glass
        float bottom = clamp((px.y - c.y) / max(ls.rect.w * 0.5, 1.0), 0.0, 1.0);
        lc *= 1.0 - 0.16 * weight * pow(bottom, 3.0) * (1.0 - line);
        color = mix(color, lc, cl);
    }

    return float4(clamp(color, 0.0, 1.0) * coverage, coverage);
}
"""
