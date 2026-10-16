// skyland media widget: floating glass overlay with the now playing media of
// any app (Spotify, Brave/YouTube, Music...), draggable, on every workspace.
// Now playing comes from third_party/mediaremote-adapter (MediaRemote through
// the entitled /usr/bin/perl, needed since macOS 15.4). Colors follow the
// current skyland theme (~/.cache/skyland/theme.css). Toggled by bin/skyland-media.
// Audio-reactive bars (cava-like): system audio from ScreenCaptureKit (audio only,
// while something plays; uses the Screen Recording permission of the launching
// app), FFT with Accelerate, log-spaced bands with auto gain.
// --style audioware: the bars become a luminous blue ribbon around a cyan center line
// (after the cover of github.com/cyb3rpsych0s1s/audioware, model in tools/media-widget/
// audioware), the line is the progress.
import Accelerate
import AppKit
import CoreImage
import ScreenCaptureKit

let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let repo = exe.deletingLastPathComponent().deletingLastPathComponent() // exe is <repo>/.build/skyland-media
let adapterScript = repo.appending(path: "third_party/mediaremote-adapter/bin/mediaremote-adapter.pl").path
let adapterFramework = repo.appending(path: ".build/mediaremote/MediaRemoteAdapter.framework").path
let themeFile = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cache/skyland/theme.css")
let defaults = UserDefaults(suiteName: "com.waxdred.skyland-media")!
// --opacity <percent>, from [media] opacity (bin/skyland-media)
let opacity = CommandLine.arguments.firstIndex(of: "--opacity")
    .flatMap { CommandLine.arguments.indices.contains($0 + 1) ? Double(CommandLine.arguments[$0 + 1]) : nil }
    .map { max(10, min(100, $0)) / 100 } ?? 1
// --style classic | audioware, from [media] style (bin/skyland-media)
let audioware = CommandLine.arguments.firstIndex(of: "--style")
    .map { CommandLine.arguments.indices.contains($0 + 1) && CommandLine.arguments[$0 + 1] == "audioware" } ?? false

func adapter(_ args: [String]) -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    p.arguments = [adapterScript, adapterFramework] + args
    return p
}

/// `@define-color key #rrggbb;` lines of a 43PR-style theme.
func themeColors() -> [String: NSColor] {
    guard let css = try? String(contentsOf: themeFile, encoding: .utf8) else { return [:] }
    var result: [String: NSColor] = [:]
    let regex = try! NSRegularExpression(pattern: #"@define-color\s+([A-Za-z0-9_]+)\s+#([0-9A-Fa-f]{6})\s*;"#)
    for m in regex.matches(in: css, range: NSRange(css.startIndex..., in: css)) {
        guard let k = Range(m.range(at: 1), in: css), let h = Range(m.range(at: 2), in: css), let v = UInt32(css[h], radix: 16) else { continue }
        result[String(css[k])] = NSColor(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
    return result
}

final class Progress: NSView {
    var fraction: CGFloat = 0 { didSet { needsDisplay = true } }
    var track = NSColor.gray, fill = NSColor.white
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.height / 2
        track.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
        fill.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width * max(0, min(1, fraction)), height: bounds.height), xRadius: r, yRadius: r).fill()
    }
}

/// Bars of the audio visualizer, levels 0...1, colored with the theme accent.
final class Bars: NSView {
    var levels: [Float] = [] { didSet { needsDisplay = true } }
    var color = NSColor.white
    override func draw(_ dirtyRect: NSRect) {
        guard !levels.isEmpty else { return }
        let gap: CGFloat = 3, width = (bounds.width - gap * CGFloat(levels.count - 1)) / CGFloat(levels.count)
        for (i, level) in levels.enumerated() {
            let height = max(2, bounds.height * CGFloat(level))
            let bar = NSRect(x: CGFloat(i) * (width + gap), y: 0, width: width, height: height)
            color.withAlphaComponent(0.45 + 0.55 * CGFloat(level)).setFill()
            NSBezierPath(roundedRect: bar, xRadius: width / 2, yRadius: width / 2).fill()
        }
    }
}

/// Audioware style visualizer, after the cover of github.com/cyb3rpsych0s1s/audioware:
/// a luminous ribbon twisting around a cyan center line on night blue. Everything is
/// measured on the cover and kept in tools/media-widget/audioware/model.json, which
/// render.js there draws the same way (it is the reference, scored against the cover):
/// seven lines (x 0...1, height above the axis in units of 0.525 x the view height,
/// cusp keys for sharp corners) with their light along x, the ribbon light per column,
/// the glow of the bright edge, spectrum peaks, hanging hairs, axis colors and gains.
/// Four depth planes, each a layer blurred by Core Image: glow (ribbon light, inner and
/// outer glows), far (tight glows), mid (hatch, peaks, crest fans, secondary edges),
/// near (bright edge, center line = progress, light points) sharp. Paused it is the
/// cover as is. Playing (advance, 30 times a second) the bands spread over the drawn
/// part: troughs dig with the bass, crests rise on their band, spectrum peaks and
/// hanging hairs grow, light follows the band, onsets make everything jump and flash
/// the axis, highs shimmer, and the lines drift faster when it is loud.
final class AudiowareWave: NSView {
    var progress: CGFloat = 0 { didSet { if progress != oldValue { near.needsDisplay = true } } }
    // audio state (render.js makeAudio / advanceAudio)
    private var time: CGFloat = 0
    private var activity: CGFloat = 0 // 0 paused (the still cover) ... 1 playing
    private var bands: [CGFloat] = []
    private var loud: CGFloat = 0, loudSlow: CGFloat = 0, pulse: CGFloat = 0
    private var seen = false // audio captured lately (else: no permission, silence)
    private var bass: CGFloat = 0.6, treble: CGFloat = 0.6

    static let night = rgb(0x0A121A), deep = rgb(0x153054), electric = rgb(0x168FC6)
    static let cyan = rgb(0x28CFFF), light = rgb(0x69E7FF), ice = rgb(0xB4F5FF)

    typealias RGB = (r: CGFloat, g: CGFloat, b: CGFloat)
    typealias Curve = [(x: CGFloat, v: CGFloat)]
    struct Key { var x: CGFloat, h: CGFloat, cusp: Bool }

    /// tools/media-widget/audioware/model.json
    struct Model {
        var lines: [String: (keys: [Key], light: Curve)] = [:]
        var fillUp: Curve = [], fillDown: Curve = [], innerA: Curve = [], outerA: Curve = [], haze: Curve = []
        var spikesUp: Curve = [], spikesDown: Curve = []
        var axis: [(x: CGFloat, color: CGColor)] = []
        var lights: [(x: CGFloat, h: CGFloat, alpha: CGFloat)] = []
        var gain: [String: CGFloat] = [:]

        init() {}

        init?(url: URL) {
            guard let data = try? Data(contentsOf: url),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            for (name, value) in json["lines"] as? [String: [String: Any]] ?? [:] {
                let keys = Self.rows(value["keys"]).filter { $0.count >= 2 }.map { Key(x: $0[0], h: $0[1], cusp: $0.count > 2 && $0[2] != 0) }
                if keys.count >= 2 { lines[name] = (keys, Self.curve(value["light"])) }
            }
            let fill = json["fill"] as? [String: Any] ?? [:], glowA = json["glowA"] as? [String: Any] ?? [:]
            fillUp = Self.curve(fill["up"])
            fillDown = Self.curve(fill["down"])
            innerA = Self.curve(glowA["inner"])
            outerA = Self.curve(glowA["outer"])
            haze = Self.curve(json["haze"])
            spikesUp = Self.curve(json["spikesUp"])
            spikesDown = Self.curve(json["spikesDown"])
            for stop in json["axisStops"] as? [[Any]] ?? [] {
                guard stop.count == 3, let x = stop[0] as? Double, let c = stop[1] as? [Double], c.count == 3, let a = stop[2] as? Double else { continue }
                axis.append((CGFloat(x), AudiowareWave.rgba((CGFloat(c[0]), CGFloat(c[1]), CGFloat(c[2])), CGFloat(a))))
            }
            lights = Self.rows(json["lights"]).filter { $0.count >= 3 }.map { ($0[0], $0[1], $0[2]) }
            for (key, value) in json["gain"] as? [String: Double] ?? [:] { gain[key] = CGFloat(value) }
        }

        private static func rows(_ any: Any?) -> [[CGFloat]] { (any as? [[Double]] ?? []).map { $0.map { CGFloat($0) } } }
        private static func curve(_ any: Any?) -> Curve { rows(any).filter { $0.count >= 2 }.map { ($0[0], $0[1]) } }
    }

    private final class Plane: NSView {
        var paint: (CGContext) -> Void = { _ in }
        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            paint(ctx)
        }
    }

    private let model = Model(url: repo.appending(path: "tools/media-widget/audioware/model.json")) ?? Model()
    private static let names = ["A", "B", "T", "E", "C1", "C2", "D"]
    private lazy var lineNames = Self.names.filter { model.lines[$0] != nil }
    private let glow = Plane(), far = Plane(), mid = Plane(), near = Plane()

    // sampled once per width
    private var n = 0
    private var xs: [CGFloat] = []
    private var baseHeight: [String: [CGFloat]] = [:] // NaN outside the line
    private var lightOf: [String: [CGFloat]] = [:]
    private var fillUp: [CGFloat] = [], fillDown: [CGFloat] = [], innerA: [CGFloat] = [], outerA: [CGFloat] = []
    // each frame
    private var heights: [String: [CGFloat]] = [:]
    private var top: [CGFloat] = [], bottom: [CGFloat] = []
    private var coverTop: [CGFloat] = [], coverBottom: [CGFloat] = [] // ribbon edges of the cover, the base of the spikes
    private var levelAt: [CGFloat] = [], boost: [CGFloat] = [] // audio level and light boost per sample

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        glow.paint = { [weak self] in self?.drawGlow($0) }
        far.paint = { [weak self] in self?.drawFar($0) }
        mid.paint = { [weak self] in self?.drawMid($0) }
        near.paint = { [weak self] in self?.drawNear($0) }
        for plane in [glow, far, mid, near] {
            plane.frame = bounds
            plane.autoresizingMask = [.width, .height]
            plane.wantsLayer = true
            plane.layerUsesCoreImageFilters = true
            addSubview(plane)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        recompute()
    }

    // MARK: model math (same as render.js)

    /// Cardinal spline through the keys, cusp keys take the secant on each side.
    private static func spline(_ p: [Key], _ x: CGFloat) -> CGFloat {
        guard let first = p.first, let last = p.last else { return 0 }
        if x <= first.x { return first.h }
        if x >= last.x { return last.h }
        var i = 1
        while i < p.count - 1, p[i].x < x { i += 1 }
        let a = p[i - 1], b = p[i], dx = b.x - a.x, t = (x - a.x) / dx, secant = (b.h - a.h) / dx
        let ta = a.cusp || i < 2 ? secant : (b.h - p[i - 2].h) / (b.x - p[i - 2].x)
        let tb = b.cusp || i + 1 >= p.count ? secant : (p[i + 1].h - a.h) / (p[i + 1].x - a.x)
        let t2 = t * t, t3 = t2 * t
        let ends: CGFloat = (2 * t3 - 3 * t2 + 1) * a.h + (-2 * t3 + 3 * t2) * b.h
        let slopes: CGFloat = ((t3 - 2 * t2 + t) * ta + (t3 - t2) * tb) * dx * 0.9
        return ends + slopes
    }
    private static func linear(_ p: Curve, _ x: CGFloat) -> CGFloat {
        guard let first = p.first, let last = p.last else { return 0 }
        if x <= first.x { return first.v }
        if x >= last.x { return last.v }
        var i = 1
        while p[i].x < x { i += 1 }
        let a = p[i - 1], b = p[i]
        return a.v + (b.v - a.v) * (x - a.x) / (b.x - a.x)
    }
    /// Deterministic pseudo random 0..<1 (strokes stay put between frames).
    private static func hash(_ i: Int) -> CGFloat {
        let s = sin(Double(i) * 12.9898 + 78.233) * 43758.5453
        return CGFloat(s - floor(s))
    }
    private static func gauss(_ x: CGFloat, _ c: CGFloat, _ w: CGFloat) -> CGFloat { exp(-(x - c) * (x - c) / (2 * w * w)) }
    static func rgba(_ c: RGB, _ a: CGFloat) -> CGColor {
        CGColor(srgbRed: c.r / 255, green: c.g / 255, blue: c.b / 255, alpha: max(0, min(1, a)))
    }
    private func gain(_ key: String) -> CGFloat { model.gain[key] ?? 0 }

    /// 30 times a second with the band levels (0...1, fast rise, slow fall): eases between
    /// the still cover and the music, smooths the bands, finds onsets, redraws.
    func advance(levels input: [Float], playing: Bool) {
        let target: CGFloat = playing ? 1 : 0, settling = abs(activity - target) > 0.002
        guard playing || settling || pulse > 0.001 || bands.contains(where: { $0 > 0.002 }) else { return } // still cover
        activity = settling ? activity + (target - activity) * 0.08 : target
        if bands.count != input.count { bands = [CGFloat](repeating: 0, count: input.count) }
        for i in bands.indices { // fast attack, softer release
            let v = CGFloat(input[i])
            bands[i] += (v - bands[i]) * (v > bands[i] ? 0.6 : 0.18)
        }
        let mean = { (part: ArraySlice<CGFloat>) -> CGFloat in part.isEmpty ? 0 : part.reduce(0, +) / CGFloat(part.count) }
        loud = mean(bands[...])
        loudSlow += (loud - loudSlow) * 0.05
        seen = loudSlow > 0.01
        pulse = seen ? max(pulse * 0.86, min(1, max(0, (loud - loudSlow) * 4))) : 0 // onsets: kick, attack
        bass = seen ? mean(bands.prefix(3)) : 0.6
        treble = seen ? mean(bands.dropFirst(9)) : 0.6
        if playing { time += (0.5 + 1.5 * loud) / 30 } // louder, livelier
        recompute()
    }

    /// Audio level under x: the bands spread over the drawn part of the cover (0.1...0.92).
    private func level(_ x: CGFloat) -> CGFloat {
        guard seen, bands.count >= 2 else { return 0.6 }
        let u = max(0, min(1, (x - 0.1) / 0.82)) * CGFloat(bands.count - 1), i = min(bands.count - 2, Int(u)), f = u - CGFloat(i)
        return bands[i] * (1 - f) + bands[i + 1] * f
    }
    /// Growth of a line at level l, 1 = the cover: troughs dig with the bass, crests rise
    /// on their band, all jump on onsets.
    private func response(_ name: String, _ l: CGFloat) -> CGFloat {
        let v: CGFloat
        switch name {
        case "B", "T": v = 0.4 + 0.5 * l + 0.5 * bass + 0.25 * pulse
        case "C1", "C2": v = 0.3 + 1.15 * l + 0.15 * pulse
        default: v = 0.4 + l + 0.12 * pulse
        }
        return 1 + activity * (v - 1)
    }
    private func spikeGrow(_ l: CGFloat) -> CGFloat { 1 + activity * (0.04 + 1.6 * l - 1) }
    private func hangGrow(_ l: CGFloat) -> CGFloat { 1 + activity * (0.4 + 0.5 * l + 0.5 * bass + 0.6 * pulse - 1) }

    private func recompute() {
        let count = max(60, Int((bounds.width / 1.5).rounded()))
        if count != n {
            n = count
            xs = (0 ... n).map { CGFloat($0) / CGFloat(n) }
            for (name, line) in model.lines {
                let a = line.keys[0].x, b = line.keys[line.keys.count - 1].x
                baseHeight[name] = xs.map { $0 >= a && $0 <= b ? Self.spline(line.keys, $0) : .nan }
                lightOf[name] = xs.map { $0 >= a && $0 <= b ? Self.linear(line.light, $0) : 0 }
            }
            fillUp = xs.map { Self.linear(model.fillUp, $0) }
            fillDown = xs.map { Self.linear(model.fillDown, $0) }
            innerA = xs.map { Self.linear(model.innerA, $0) }
            outerA = xs.map { Self.linear(model.outerA, $0) }
            (coverTop, coverBottom) = edges(baseHeight)
            // blur radii follow the width, like the prototype (glow 6, far 1.2, mid 0.35 per 1000)
            for (plane, radius) in [(glow, 6.0), (far, 1.2), (mid, 0.35)] {
                plane.layer?.filters = [CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: radius * Double(bounds.width) / 1000])!]
            }
        }
        levelAt = xs.map { level($0) }
        boost = levelAt.map { 1 + activity * (0.5 * ($0 - 0.6) + 0.45 * pulse) } // light follows the band, flashes on onsets
        for name in lineNames {
            guard let base = baseHeight[name] else { continue }
            let k = CGFloat(name.unicodeScalars.first!.value)
            heights[name] = base.indices.map { i -> CGFloat in
                let x = xs[i], wobble = 1 + 0.06 * activity * (sin(time * 0.9 + x * 23 + k) - sin(x * 23 + k))
                let shimmer = activity * treble * 0.025 * sin(x * 90 - time * 7 + k) * min(1, abs(base[i]) * 8)
                return base[i] * response(name, levelAt[i]) * wobble + shimmer
            }
        }
        (top, bottom) = edges(heights)
        for plane in [glow, far, mid, near] { plane.needsDisplay = true }
    }

    /// Ribbon edges: highest and lowest line per sample, crests aside.
    private func edges(_ lines: [String: [CGFloat]]) -> ([CGFloat], [CGFloat]) {
        var high = [CGFloat](), low = [CGFloat]()
        for i in 0 ... n {
            var a = -CGFloat.infinity, b = CGFloat.infinity
            for name in lineNames where !(name == "C1" || (name == "C2" && xs[i] < 0.72)) {
                guard let h = lines[name]?[i], !h.isNaN else { continue }
                a = max(a, h)
                b = min(b, h)
            }
            high.append(a.isFinite ? a : 0)
            low.append(b.isFinite ? b : 0)
        }
        return (high, low)
    }

    // MARK: drawing helpers

    private var unitScale: CGFloat { bounds.width / 1000 }
    private var axisY: CGFloat { bounds.height * 0.445 } // 0.555 from the top, like the cover
    private func px(_ i: Int) -> CGFloat { CGFloat(i) / CGFloat(n) * bounds.width }
    /// Soft knee above 0.85 so loud crests round off instead of flattening.
    private func py(_ h: CGFloat) -> CGFloat {
        let m = abs(h), clipped = m <= 0.85 ? h : (h < 0 ? -1 : 1) * (0.85 + 0.2 * tanh((m - 0.85) / 0.2))
        return axisY + clipped * bounds.height * 0.525
    }
    private func point(_ i: Int, _ h: CGFloat) -> CGPoint { CGPoint(x: px(i), y: py(h)) }
    /// Width given at 1000 px wide, at least half a point.
    private func lw(_ w: CGFloat) -> CGFloat { max(0.5, w * unitScale) }

    /// A line in chunks of `step` samples whose alpha follows its light (or `profile`), batched by alpha.
    private func lit(_ ctx: CGContext, _ name: String, _ color: RGB, _ alpha: CGFloat, _ width: CGFloat, step: Int = 4, dash: [CGFloat]? = nil, profile: [CGFloat]? = nil) {
        guard let h = heights[name], let light = profile ?? lightOf[name] else { return }
        var buckets: [Int: CGMutablePath] = [:]
        for i in stride(from: 0, to: n, by: step) {
            let j = min(n, i + step)
            guard !h[i].isNaN, !h[j].isNaN else { continue }
            let bucket = Int((min(1, alpha * (light[i] + light[j]) / 2 * (boost[i] + boost[j]) / 2) * 20).rounded())
            guard bucket > 0 else { continue }
            let path = buckets[bucket] ?? CGMutablePath()
            buckets[bucket] = path
            path.move(to: point(i, h[i]))
            for k in i + 1 ... j { path.addLine(to: point(k, h[k])) }
        }
        ctx.saveGState()
        ctx.setLineWidth(lw(width))
        ctx.setLineCap(.round)
        if let dash { ctx.setLineDash(phase: 0, lengths: dash.map { lw($0) }) }
        for (bucket, path) in buckets {
            ctx.addPath(path)
            ctx.setStrokeColor(Self.rgba(color, CGFloat(bucket) / 20))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    private typealias Hair = (from: CGPoint, to: CGPoint, color: Int, alpha: CGFloat)
    private static let hairColors: [RGB] = [(55, 125, 215), (120, 210, 255), (110, 200, 250), (90, 170, 240), (60, 140, 225), (40, 110, 195)]
    /// Straight segments batched by color and alpha (rounded to 0.05), `width` in points.
    private func hairs(_ ctx: CGContext, _ list: [Hair], width: CGFloat) {
        var buckets: [Int: [CGPoint]] = [:]
        for hair in list {
            let bucket = Int((min(1, hair.alpha) * 20).rounded())
            guard bucket > 0 else { continue }
            buckets[hair.color * 100 + bucket, default: []] += [hair.from, hair.to]
        }
        ctx.saveGState()
        ctx.setLineWidth(width)
        ctx.setLineCap(.butt)
        for (key, points) in buckets {
            ctx.setStrokeColor(Self.rgba(Self.hairColors[key / 100], CGFloat(key % 100) / 20))
            ctx.strokeLineSegments(between: points)
        }
        ctx.restoreGState()
    }

    /// Elliptic glow `rx` wide, `ry` tall.
    private func halo(_ ctx: CGContext, _ center: CGPoint, _ rx: CGFloat, _ ry: CGFloat, _ color: RGB, _ alpha: CGFloat) {
        guard rx > 0, ry > 0 else { return }
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [Self.rgba(color, alpha), Self.rgba(color, 0)] as CFArray, locations: [0, 1])!
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: rx / ry, y: 1)
        ctx.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: ry, options: [])
        ctx.restoreGState()
    }

    private func ribbonPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: point(0, top[0]))
        for i in 1 ... n { path.addLine(to: point(i, top[i])) }
        for i in (0 ... n).reversed() { path.addLine(to: point(i, bottom[i])) }
        path.closeSubpath()
        return path
    }

    private func axisGradient() -> CGGradient? {
        guard !model.axis.isEmpty else { return nil }
        return CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: model.axis.map(\.color) as CFArray, locations: model.axis.map(\.x))
    }

    private var ready: Bool { n > 0 && top.count == n + 1 && boost.count == n + 1 && !lineNames.isEmpty }

    // MARK: planes

    /// Ribbon light per column, the light the edges pour inside it, wide halos, haze.
    private func drawGlow(_ ctx: CGContext) {
        guard ready else { return }
        let w = bounds.width, h = bounds.height
        halo(ctx, CGPoint(x: w * 0.53, y: axisY), w * 0.40, h * 0.42, (22, 45, 80), 0.45)
        var columns: [Hair] = []
        for i in 0 ... n where top[i] - bottom[i] >= 0.005 {
            if top[i] > 0 { columns.append((point(i, top[i]), point(i, max(0, bottom[i])), 5, gain("fill") * fillUp[i] * boost[i])) }
            if bottom[i] < 0 { columns.append((point(i, min(0, top[i])), point(i, bottom[i]), 5, gain("fill") * fillDown[i] * boost[i])) }
        }
        hairs(ctx, columns, width: max(0.5, w / CGFloat(n) + 0.5 * unitScale))
        ctx.saveGState()
        ctx.addPath(ribbonPath())
        ctx.clip()
        for name in lineNames {
            let a = gain("inner") * (name == "A" ? 1 : gain("innerB")), profile = name == "A" ? innerA : nil
            lit(ctx, name, (45, 185, 235), a, gain("innerW"), step: 6, profile: profile)
            lit(ctx, name, (90, 215, 250), a, gain("innerW") * 0.4, step: 6, profile: profile)
        }
        lit(ctx, "B", (50, 140, 230), gain("ramp"), 40, step: 6)
        lit(ctx, "T", (50, 140, 230), gain("ramp"), 40, step: 6)
        ctx.restoreGState()
        for name in lineNames {
            lit(ctx, name, (35, 165, 230), gain("outer") * (name == "A" ? 1 : gain("outerB")), gain("outerW"), step: 6, profile: name == "A" ? outerA : nil)
        }
        if let axis = axisGradient() {
            ctx.saveGState()
            ctx.setAlpha(gain("axisHalo"))
            ctx.clip(to: CGRect(x: 0, y: axisY - lw(4), width: w, height: lw(8)))
            ctx.drawLinearGradient(axis, start: .zero, end: CGPoint(x: w, y: 0), options: [])
            ctx.restoreGState()
        }
        // haze behind the cluster of spectrum peaks (a luminous jagged mountain on the cover)
        if let first = model.haze.first, let last = model.haze.last {
            let range = xs.indices.filter { xs[$0] >= first.x && xs[$0] <= last.x }
            if let start = range.first {
                let path = CGMutablePath()
                path.move(to: point(start, max(top[start], Self.linear(model.haze, xs[start]) * response("A", levelAt[start]))))
                for i in range.dropFirst() { path.addLine(to: point(i, max(top[i], Self.linear(model.haze, xs[i]) * response("A", levelAt[i])))) }
                for i in range.reversed() { path.addLine(to: point(i, top[i])) }
                path.closeSubpath()
                let haze = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [Self.rgba((60, 150, 240), 0), Self.rgba((60, 150, 240), gain("haze"))] as CFArray, locations: [0, 1])!
                ctx.saveGState()
                ctx.addPath(path)
                ctx.clip()
                ctx.drawLinearGradient(haze, start: CGPoint(x: 0, y: py(0.9)), end: CGPoint(x: 0, y: py(0.3)), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                ctx.restoreGState()
            }
        }
    }

    /// Tight glows around every line.
    private func drawFar(_ ctx: CGContext) {
        guard ready else { return }
        for name in lineNames {
            lit(ctx, name, (60, 195, 240), gain("far") * (name == "A" ? 1 : gain("outerB")), gain("farW"))
        }
    }

    /// Hatch, spectrum peaks, hanging hairs, crest fans, secondary edges.
    private func drawMid(_ ctx: CGContext) {
        guard ready else { return }
        let w = bounds.width
        var hatch: [Hair] = []
        for i in 0 ... n where top[i] - bottom[i] >= 0.01 {
            let r = Self.hash(i + 40), color = r > 0.93 ? 1 : 0
            if top[i] > 0 { hatch.append((point(i, top[i]), point(i, max(0, bottom[i])), color, gain("hatch") * fillUp[i] * (0.25 + 1.1 * r) * boost[i])) }
            if bottom[i] < 0 { hatch.append((point(i, min(0, top[i])), point(i, bottom[i]), color, gain("hatch") * fillDown[i] * (0.25 + 1.1 * Self.hash(i + 91)) * boost[i])) }
        }
        hairs(ctx, hatch, width: lw(0.55))
        // spectrum peaks: narrow glowing peaks on the top edge, concave flanks; the tallest
        // go on as a hairline with a light tip
        var spikes: [Hair] = []
        for spike in model.spikesUp {
            let i = Int((spike.x * CGFloat(n)).rounded()), base = top[i]
            let flicker = 1 + 0.12 * activity * (sin(time * 1.7 + spike.x * 40) - sin(spike.x * 40))
            let tip = base + max(0, spike.v - coverTop[i]) * spikeGrow(levelAt[i]) * flicker
            guard tip - base >= 0.03 else { continue }
            let height = min(0.22, tip - base), half = (0.003 + 0.02 * height) * w, apex = point(i, base + height)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: apex.x - half, y: py(base)))
            path.addQuadCurve(to: apex, control: CGPoint(x: apex.x - half * 0.15, y: py(base + height * 0.25)))
            path.addQuadCurve(to: CGPoint(x: apex.x + half, y: py(base)), control: CGPoint(x: apex.x + half * 0.15, y: py(base + height * 0.25)))
            path.closeSubpath()
            let peak = gain("peak") * boost[i]
            let fill = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [Self.rgba((70, 170, 245), peak), Self.rgba((70, 170, 245), peak * 0.3)] as CFArray, locations: [0, 1])!
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            ctx.drawLinearGradient(fill, start: CGPoint(x: 0, y: py(base)), end: apex, options: [])
            ctx.restoreGState()
            ctx.addPath(path)
            ctx.setStrokeColor(Self.rgba((110, 210, 250), peak * 1.2))
            ctx.setLineWidth(lw(0.5))
            ctx.strokePath()
            if tip - base > height + 0.02 {
                spikes.append((apex, point(i, tip), 2, gain("spike") * boost[i]))
                if tip > 0.5 { halo(ctx, point(i, tip), lw(2), lw(2), (170, 240, 255), 0.5 * boost[i]) }
            }
        }
        for spike in model.spikesDown {
            let i = Int((spike.x * CGFloat(n)).rounded()), base = bottom[i], tip = base - max(0, coverBottom[i] - spike.v) * hangGrow(levelAt[i])
            guard base - tip >= 0.03 else { continue }
            let middle = (base + tip) / 2
            spikes.append((point(i, base), point(i, middle), 3, gain("spike") * boost[i]))
            spikes.append((point(i, middle), point(i, tip), 3, gain("spike") * 0.45 * boost[i]))
        }
        for i in 0 ... n {
            let x = xs[i]
            // where hairs rise over the ribbon and hang under it
            let aboveLeft: CGFloat = 0.6 * Self.gauss(x, 0.40, 0.03) + 0.4 * Self.gauss(x, 0.30, 0.01)
            let above: CGFloat = aboveLeft + 0.4 * Self.gauss(x, 0.60, 0.02) + 0.3 * Self.gauss(x, 0.74, 0.01)
            let below: CGFloat = min(1, Self.gauss(x, 0.40, 0.02) + Self.gauss(x, 0.52, 0.025) + 0.4 * Self.gauss(x, 0.66, 0.04))
            if Self.hash(i + 7) < above {
                let length = pow(Self.hash(i + 11), 2) * 0.3 * 1.35 * spikeGrow(levelAt[i])
                spikes.append((point(i, top[i]), point(i, top[i] + length), 4, gain("hairs") * (0.4 + 0.6 * Self.hash(i + 3)) * boost[i]))
            }
            if Self.hash(i + 17) < below {
                let length = (0.04 + pow(Self.hash(i + 19), 1.5) * 0.22) * 1.35 * hangGrow(levelAt[i]), a = gain("hairs") * (0.4 + 0.6 * Self.hash(i + 23)) * boost[i]
                let middle = bottom[i] - length / 2
                spikes.append((point(i, bottom[i]), point(i, middle), 4, a))
                spikes.append((point(i, middle), point(i, bottom[i] - length), 4, a * 0.4))
            }
        }
        hairs(ctx, spikes, width: lw(0.6))
        // crest fans: nested contours from A up to each crest (moire)
        if let a = heights["A"] {
            for (name, low, high, alpha) in [("C1", 0.4525, 0.565, gain("fanC1")), ("C2", 0.645, 0.7475, gain("fan"))] as [(String, CGFloat, CGFloat, CGFloat)] {
                guard let crest = heights[name] else { continue }
                let range = xs.indices.filter { xs[$0] >= low && xs[$0] <= high && !crest[$0].isNaN && !a[$0].isNaN }
                guard let start = range.first else { continue }
                ctx.setLineWidth(lw(0.5))
                for f in 1 ... 22 {
                    let q = CGFloat(f) / 22, path = CGMutablePath()
                    path.move(to: point(start, a[start] + (crest[start] - a[start]) * q))
                    for i in range.dropFirst() { path.addLine(to: point(i, a[i] + (crest[i] - a[i]) * q)) }
                    ctx.addPath(path)
                    ctx.setStrokeColor(Self.rgba((75, 155, 230), alpha * (0.35 + 0.65 * q)))
                    ctx.strokePath()
                }
            }
        }
        for name in ["B", "T", "E"] { lit(ctx, name, (98, 205, 231), gain("core"), gain("coreB"), step: 3) }
        lit(ctx, "C1", (120, 215, 245), 0.9, 0.8, step: 3)
        lit(ctx, "C2", (98, 205, 231), 1.0, 1.2, step: 3)
        lit(ctx, "D", (120, 215, 245), 1.0, 1.1, step: 3, dash: [1.4, 2.2])
    }

    /// Bright edge, center line (brighter up to the playhead), light points.
    private func drawNear(_ ctx: CGContext) {
        guard ready else { return }
        let w = bounds.width
        lit(ctx, "A", (98, 205, 231), gain("core"), gain("coreW"), step: 3)
        lit(ctx, "A", (190, 248, 255), 0.8 * gain("core"), 0.6, step: 3)
        let thickness = lw(gain("axisW")), flash = activity * pulse
        if let axis = axisGradient() {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: axisY - thickness / 2, width: w, height: thickness))
            ctx.drawLinearGradient(axis, start: .zero, end: CGPoint(x: w, y: 0), options: [])
            if flash > 0.02 { // the axis flashes on onsets
                ctx.setAlpha(min(1, flash * 0.8))
                ctx.drawLinearGradient(axis, start: .zero, end: CGPoint(x: w, y: 0), options: [])
            }
            ctx.restoreGState()
        }
        let flare = 1 + 0.6 * flash
        halo(ctx, CGPoint(x: w * 0.06, y: axisY), w * 0.09 * flare, lw(gain("axisGlowW")), (110, 240, 255), gain("axisGlow") * flare)
        halo(ctx, CGPoint(x: w * 0.945, y: axisY), w * 0.03 * flare, lw(5), (120, 250, 255), 0.7)
        halo(ctx, CGPoint(x: w * 0.76, y: axisY), w * 0.07 * flare, lw(5), (45, 110, 230), 0.45 * flare)
        let head = w * max(0, min(1, progress))
        ctx.setFillColor(Self.rgba((7, 15, 24), 0.45))
        ctx.fill(CGRect(x: head, y: axisY - thickness / 2, width: w - head, height: thickness))
        if progress > 0, progress < 1 { halo(ctx, CGPoint(x: head, y: axisY), lw(10), lw(3), (180, 245, 255), 0.9) }
        for light in model.lights {
            let i = Int((light.x * CGFloat(n)).rounded())
            halo(ctx, point(i, light.h * response("A", levelAt[i])), lw(gain("lightR")), lw(gain("lightR")), (160, 235, 255), light.alpha * boost[i])
        }
    }
}

func rgb(_ v: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
}

/// System audio -> band levels. Runs only between start() and stop().
final class AudioBands: NSObject, SCStreamOutput, @unchecked Sendable {
    static let fftSize = 1024
    let bandCount: Int
    let onLevels: ([Float]) -> Void // called on the main queue
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "skyland-media.audio")
    private var samples: [Float] = []
    private let dft = vDSP.DFT(count: fftSize, direction: .forward, transformType: .complexReal, ofType: Float.self)!
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)
    private var peak: Float = 1e-3 // auto gain, like cava autosens
    private let tilt: Float = 1.5 // music has less energy up high: band gain (1 + band)^tilt, raise for livelier highs
    private var sampleRate: Double = 48000

    init(bands: Int, onLevels: @escaping ([Float]) -> Void) {
        bandCount = bands
        self.onLevels = onLevels
    }

    func start() {
        guard stream == nil else { return }
        Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
                  let display = content.displays.first else { return }
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = Int(sampleRate)
            config.channelCount = 1
            config.width = 2 // audio only: the smallest video, one frame per second
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: nil)
            try? stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            guard (try? await stream.startCapture()) != nil else { return }
            self.stream = stream
        }
    }

    func stop() {
        let stream = self.stream
        self.stream = nil
        Task { try? await stream?.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        try? buffer.withAudioBufferList { list, _ in
            guard let data = list.first?.mData else { return }
            let count = Int(list.first!.mDataByteSize) / MemoryLayout<Float>.size
            samples.append(contentsOf: UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
        }
        while samples.count >= Self.fftSize {
            let block = Array(samples.prefix(Self.fftSize))
            samples.removeFirst(Self.fftSize / 2) // 50% overlap
            let levels = bands(of: block)
            DispatchQueue.main.async { self.onLevels(levels) }
        }
    }

    private func bands(of block: [Float]) -> [Float] {
        let windowed = vDSP.multiply(block, window)
        // complexReal DFT input: even samples as real, odd samples as imaginary
        let even = stride(from: 0, to: Self.fftSize, by: 2).map { windowed[$0] }
        let odd = stride(from: 1, to: Self.fftSize, by: 2).map { windowed[$0] }
        var re = [Float](repeating: 0, count: Self.fftSize / 2), im = re
        dft.transform(inputReal: even, inputImaginary: odd, outputReal: &re, outputImaginary: &im)
        let binHz = sampleRate / Double(Self.fftSize)
        var levels = [Float](repeating: 0, count: bandCount)
        for band in 0 ..< bandCount { // log spaced 50 Hz ... 12 kHz
            let low = 50 * pow(240, Double(band) / Double(bandCount)), high = 50 * pow(240, Double(band + 1) / Double(bandCount))
            let first = max(1, Int(low / binHz)), last = max(first, min(re.count - 1, Int(high / binHz)))
            var sum: Float = 0
            for k in first ... last { sum += sqrt(re[k] * re[k] + im[k] * im[k]) }
            levels[band] = sum / Float(last - first + 1) * pow(Float(1 + band), tilt)
        }
        peak = max(levels.max() ?? 0, peak * 0.995, 1e-3)
        return levels.map { min(1, sqrt($0 / peak)) }
    }
}

final class Widget: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let size = audioware ? NSSize(width: 440, height: 180) : NSSize(width: 380, height: 116)
    let radius: CGFloat = 18
    var panel: NSPanel!
    var tint: NSView!
    let artwork = NSImageView()
    let title = NSTextField(labelWithString: "Rien en lecture")
    let artist = NSTextField(labelWithString: "")
    let source = NSTextField(labelWithString: "")
    let progress = Progress()
    var playButton: NSButton!
    let bars = Bars()
    let wave = AudiowareWave(frame: .zero)
    var shownLevels = [Float](repeating: 0, count: 14)
    var targetLevels = [Float](repeating: 0, count: 14)
    lazy var audio = AudioBands(bands: 14) { [weak self] levels in self?.targetLevels = levels }
    var buttons: [NSButton] = []

    var state: [String: Any] = [:]
    var stream: Process?
    var themeDate: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let origin = defaults.string(forKey: "origin").map(NSPointFromString)
            ?? NSPoint(x: screen.visibleFrame.maxX - size.width - 20, y: screen.visibleFrame.minY + 20)
        panel = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = true // drag anywhere with the mouse
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.alphaValue = opacity
        panel.delegate = self

        let glass = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        glass.material = .hudWindow
        glass.state = .active
        // A mask image (not layer.cornerRadius) also shapes the window border and
        // shadow: with cornerRadius macOS kept drawing a 1 px rectangular outline.
        glass.maskImage = roundedMask(radius: radius)
        panel.contentView = glass
        tint = NSView(frame: glass.bounds)
        tint.wantsLayer = true
        tint.layer?.cornerRadius = radius
        glass.addSubview(tint)

        artwork.frame = audioware ? NSRect(x: 14, y: 124, width: 46, height: 46) : NSRect(x: 14, y: 14, width: 88, height: 88)
        artwork.imageScaling = .scaleProportionallyUpOrDown
        artwork.wantsLayer = true
        artwork.layer?.cornerRadius = 12
        artwork.layer?.masksToBounds = true
        glass.addSubview(artwork)

        for (field, y, font) in [(title, 80.0, NSFont.systemFont(ofSize: 14, weight: .semibold)),
                                 (artist, 62.0, NSFont.systemFont(ofSize: 12)),
                                 (source, 46.0, NSFont.systemFont(ofSize: 10, weight: .medium))]
        {
            field.frame = NSRect(x: 114, y: y, width: size.width - 128, height: 18)
            if audioware { // title over the whole width, artist and source left of the controls
                field.frame = field === title ? NSRect(x: 72, y: 154, width: size.width - 86, height: 18)
                    : NSRect(x: 72, y: field === artist ? 138 : 122, width: size.width - 72 - 132, height: 16)
            }
            field.font = font
            field.lineBreakMode = .byTruncatingTail
            glass.addSubview(field)
        }
        progress.frame = NSRect(x: 114, y: 38, width: size.width - 128, height: 4)
        if audioware { // the wave sits under the text, edge to edge; its center line is the progress
            wave.frame = NSRect(x: 0, y: 0, width: size.width, height: 118)
            glass.addSubview(wave)
        } else {
            glass.addSubview(progress)
        }

        let controls: [(String, Int)] = [("backward.fill", 5), ("play.fill", 2), ("forward.fill", 4)]
        for (i, (symbol, command)) in controls.enumerated() {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!, target: self, action: #selector(send(_:)))
            button.isBordered = false
            button.tag = command
            button.symbolConfiguration = .init(pointSize: i == 1 ? 18 : 14, weight: .semibold)
            button.frame = audioware ? NSRect(x: size.width - 14 - 114 + CGFloat(i) * 40, y: 128, width: 34, height: 26)
                : NSRect(x: 114 + CGFloat(i) * 44, y: 8, width: 36, height: 26)
            glass.addSubview(button)
            buttons.append(button)
        }
        playButton = buttons[1]
        bars.frame = NSRect(x: 254, y: 10, width: size.width - 254 - 16, height: 22)
        if !audioware { glass.addSubview(bars) }
        // 30 fps: rise at once, fall slowly (cava gravity)
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let playing = self.state["playing"] as? Bool ?? false
                for i in self.shownLevels.indices {
                    let target = playing ? self.targetLevels[i] : 0
                    self.shownLevels[i] = max(target, self.shownLevels[i] * 0.85)
                }
                if audioware {
                    self.wave.advance(levels: self.shownLevels, playing: playing) // paused: settles back to the still cover
                } else if self.bars.levels != self.shownLevels {
                    self.bars.levels = self.shownLevels
                }
            }
        }

        applyTheme()
        render()
        startStream()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateProgress()
                self?.applyThemeIfChanged()
            }
        }
        panel.orderFrontRegardless()
    }

    // MARK: theme

    func applyThemeIfChanged() {
        let date = (try? themeFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if date != themeDate { applyTheme() }
    }

    func applyTheme() {
        themeDate = (try? themeFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if audioware { applyAudioware(); return }
        let c = themeColors()
        let fg = c["fg"] ?? .white, dim = c["fg_dim"] ?? .lightGray
        tint.layer?.backgroundColor = (c["bg_card"] ?? .black).withAlphaComponent(0.55).cgColor
        title.textColor = fg
        artist.textColor = dim
        source.textColor = (c["accent"] ?? fg).withAlphaComponent(0.9)
        progress.track = (c["bg_hover"] ?? .darkGray)
        progress.fill = c["accent"] ?? fg
        progress.needsDisplay = true
        for button in buttons { button.contentTintColor = fg }
        bars.color = c["accent"] ?? fg
        artwork.layer?.backgroundColor = (c["bg_hover"] ?? .darkGray).cgColor
    }

    /// Fixed cold palette of the audioware style, the skyland theme is ignored.
    func applyAudioware() {
        tint.layer?.backgroundColor = AudiowareWave.night.withAlphaComponent(0.92).cgColor
        title.textColor = AudiowareWave.ice
        artist.textColor = AudiowareWave.electric
        source.textColor = AudiowareWave.cyan.withAlphaComponent(0.9)
        for button in buttons { button.contentTintColor = AudiowareWave.light }
        artwork.layer?.backgroundColor = AudiowareWave.deep.cgColor
        artwork.contentTintColor = AudiowareWave.cyan
    }

    // MARK: now playing

    func startStream() {
        let p = adapter(["stream", "--no-diff", "--micros", "--debounce=100"])
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        var buffer = Data()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            buffer.append(handle.availableData)
            while let newline = buffer.firstIndex(of: 0x0a) {
                let line = buffer[buffer.startIndex ..< newline]
                buffer.removeSubrange(buffer.startIndex ... newline)
                guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let payload = json["payload"] as? [String: Any] else { continue }
                DispatchQueue.main.async { self?.state = payload; self?.render() }
            }
        }
        p.terminationHandler = { _ in // perl died (e.g. adapter broken): retry later
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.startStream() }
        }
        try? p.run()
        stream = p
    }

    func render() {
        let playing = state["playing"] as? Bool ?? false
        title.stringValue = state["title"] as? String ?? "Rien en lecture"
        artist.stringValue = [state["artist"], state["album"]].compactMap { $0 as? String }.filter { !$0.isEmpty }.joined(separator: " — ")
        if let bundleId = state["bundleIdentifier"] as? String,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        {
            source.stringValue = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        } else {
            source.stringValue = ""
        }
        if let b64 = state["artworkData"] as? String, let data = Data(base64Encoded: b64) {
            artwork.image = NSImage(data: data)
        } else if state["title"] == nil {
            artwork.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
        }
        playButton.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill", accessibilityDescription: nil)
        if playing { audio.start() } else { audio.stop() } // capture only while something plays
        updateProgress()
    }

    func updateProgress() {
        guard let duration = state["durationMicros"] as? Double, duration > 0,
              let elapsed = state["elapsedTimeMicros"] as? Double else { progress.fraction = 0; wave.progress = 0; return }
        var now = elapsed
        if state["playing"] as? Bool == true, let stamp = state["timestampEpochMicros"] as? Double {
            now += (Date().timeIntervalSince1970 * 1e6 - stamp) * (state["playbackRate"] as? Double ?? 1)
        }
        progress.fraction = CGFloat(now / duration)
        wave.progress = progress.fraction
    }

    @objc func send(_ sender: NSButton) {
        try? adapter(["send", String(sender.tag)]).run()
    }

    // MARK: window

    func windowDidMove(_ notification: Notification) {
        defaults.set(NSStringFromPoint(panel.frame.origin), forKey: "origin")
    }

    func applicationWillTerminate(_ notification: Notification) {
        stream?.terminationHandler = nil
        stream?.terminate()
        audio.stop()
    }
}

/// Resizable rounded rect mask for NSVisualEffectView.maskImage.
func roundedMask(radius: CGFloat) -> NSImage {
    let edge = radius * 2 + 1
    let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
}

// SIGTERM (bin/skyland-media toggle) quits cleanly so the perl stream stops too
signal(SIGTERM, SIG_IGN)
let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminate.setEventHandler { NSApp.terminate(nil) }
terminate.resume()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let widget = Widget()
app.delegate = widget
app.run()
