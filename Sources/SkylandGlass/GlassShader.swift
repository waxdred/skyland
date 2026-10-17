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
    float clear;        // 1: clear glass, 2: a lens inside the others
    float2 pad;         // x: a lens's lift, 0...1, while it moves
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

// the signed distance to a rounded rectangle centred on 0: below 0 inside
static float box(float2 p, float2 half_size, float r) {
    float2 q = abs(p) - half_size + r;
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

    // light from the top left: a bright rim facing it, a softer one opposite
    float2 light = normalize(float2(-0.45, -0.89));
    float facing = dot(n, light);
    float rim = pow(clamp(1.0 - inside / (1.8 * u.scale), 0.0, 1.0), 1.5);
    color += rim * (0.60 * max(facing, 0.0) + 0.22 * max(-facing, 0.0)) * (u.dark > 0.5 ? 0.85 : 1.0);

    // a sheen over the top half, a faint inner shadow along the bottom
    float from_top = clamp((px.y - sh.rect.y) / max(sh.rect.w, 1.0), 0.0, 1.0);
    color += (1.0 - smoothstep(0.0, 0.55, from_top)) * (u.dark > 0.5 ? 0.05 : 0.08);
    color *= 1.0 - 0.12 * lens * max(n.y, 0.0);

    // lenses: a thicker drop of glass over a selection, as Apple's tab bars. What is behind
    // a little magnified, a lighter body under the lens's tint, its own rim lit from the top
    // left, and a soft shade just outside it
    for (int i = 0; i < u.count; i++) {
        Shape ls = shapes[i];
        if (ls.clear < 1.5) continue;
        float lift = ls.pad.x;                                   // lifted while it moves
        float dl = shape_distance(ls, px);
        color *= 1.0 - (0.10 + 0.10 * lift) * (1.0 - smoothstep(0.0, (3.0 + 4.0 * lift) * u.scale, max(dl, 0.0))) * step(0.0, dl); // shade outside
        if (dl > 1.0) continue;
        float cl = clamp(0.5 - dl, 0.0, 1.0);
        float2 c = ls.rect.xy + ls.rect.zw * 0.5;
        float2 ml = float2(shape_distance(ls, px + float2(e, 0.0)) - shape_distance(ls, px - float2(e, 0.0)),
                           shape_distance(ls, px + float2(0.0, e)) - shape_distance(ls, px - float2(0.0, e)));
        ml = ml / max(length(ml), 1e-4);
        float edge = pow(clamp(1.0 - (-dl) / (0.35 * ls.rect.w + 1.0), 0.0, 1.0), 2.0);
        float2 lat = c + (px - c) / (1.08 + 0.10 * lift) - ml * edge * (2.0 + 2.0 * lift) * u.scale + u.origin;   // magnified, bent at its edge
        float3 lc = backdrop_at(backdrop, s, lat, blur, u.texSize);
        float ll = dot(lc, float3(0.2126, 0.7152, 0.0722));
        lc = mix(float3(ll), lc, u.saturation);
        lc = u.dark > 0.5 ? lc * 0.85 + 0.12 : lc * 0.80 + 0.22;               // lighter than the glass around
        lc = mix(lc, ls.tint.rgb, ls.tint.a);
        float lf = dot(ml, light);
        float lrim = pow(clamp(1.0 - (-dl) / (1.4 * u.scale), 0.0, 1.0), 1.5);
        lc += lrim * ((0.55 + 0.30 * lift) * max(lf, 0.0) + (0.25 + 0.10 * lift) * max(-lf, 0.0));
        float ltop = clamp((px.y - ls.rect.y) / max(ls.rect.w, 1.0), 0.0, 1.0);
        lc += (1.0 - smoothstep(0.0, 0.5, ltop)) * 0.06;
        color = mix(color, lc, cl);
    }

    return float4(clamp(color, 0.0, 1.0) * coverage, coverage);
}
"""
