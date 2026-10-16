// skyland media widget: floating glass overlay with the now playing media of
// any app (Spotify, Brave/YouTube, Music...), draggable, on every workspace.
// Now playing comes from third_party/mediaremote-adapter (MediaRemote through
// the entitled /usr/bin/perl, needed since macOS 15.4). Colors follow the
// current skyland theme (~/.cache/skyland/theme.css). Toggled by bin/skyland-media.
// Audio-reactive bars (cava-like): system audio from ScreenCaptureKit (audio only,
// while something plays; uses the Screen Recording permission of the launching
// app), FFT with Accelerate, log-spaced bands with auto gain.
// --style audioware: the bars become a luminous blue ribbon around a cyan center line
// (after the cover of github.com/cyb3rpsych0s1s/audioware), the line is the progress.
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
/// a luminous ribbon twisting around a cyan center line on night blue. Its two edges
/// cross the axis (the bright one dives into the 40 % trough then climbs to the first
/// crest), the inside is hatched with hairlines and ruled lines, two crests are fans of
/// nested contours (moiré), a spectrum of fine spikes rises over the middle. Keypoints
/// are measured on the cover (x 0...1, height in half heights above the axis); audio
/// scales them and drives slow wobbles and ripples. Three depth planes, each its own
/// layer blurred by Core Image: far (back copy, ruled lines, echoes, bloom) blurred
/// most, mid (spectrum, hatched ribbon, crests, lower edge) barely, near (bright edge,
/// center line = progress, light points) sharp.
final class AudiowareWave: NSView {
    var levels: [Float] = [] { didSet { recompute() } }
    var time: CGFloat = 0
    var progress: CGFloat = 0 { didSet { if progress != oldValue { near.needsDisplay = true } } }

    static let night = rgb(0x070F18), deep = rgb(0x153054), electric = rgb(0x168FC6)
    static let cyan = rgb(0x28CFFF), light = rgb(0x69E7FF), ice = rgb(0xB4F5FF)

    typealias Keys = [(x: CGFloat, h: CGFloat)]
    /// Bright edge: flat, small bumps, crest at 1/4, dives to the 40 % trough, climbs to the first crest.
    static let upperKeys: Keys = [
        (0, 0), (0.10, 0.01), (0.113, 0.03), (0.13, 0.11), (0.15, 0.09), (0.165, 0.02), (0.178, 0.06), (0.19, 0.02),
        (0.205, 0.05), (0.225, 0.10), (0.25, 0.23), (0.265, 0.26), (0.28, 0.24), (0.30, 0.13), (0.325, 0.02),
        (0.35, -0.06), (0.365, -0.2), (0.39, -0.6), (0.41, -0.4), (0.425, -0.12), (0.44, 0.25), (0.457, 0.55),
        (0.47, 0.47), (0.49, 0.26), (0.51, 0.14), (0.53, 0.10), (0.557, 0.14), (0.585, 0.25), (0.614, 0.34),
        (0.643, 0.46), (0.665, 0.52), (0.69, 0.38), (0.705, 0.22), (0.72, 0.10), (0.74, 0.09), (0.755, 0.14),
        (0.77, 0.25), (0.79, 0.24), (0.81, 0.12), (0.83, 0.06), (0.865, 0.09), (0.88, 0.07), (0.895, 0.02), (0.92, 0), (1, 0),
    ]
    /// Second edge: the spectrum top over the trough, then the lower troughs, jagged on the right.
    static let lowerKeys: Keys = [
        (0, 0), (0.11, 0), (0.125, -0.03), (0.16, -0.03), (0.2, -0.01), (0.225, -0.08), (0.25, -0.16), (0.27, -0.15),
        (0.29, -0.09), (0.312, -0.13), (0.325, 0.0), (0.338, 0.21), (0.36, 0.30), (0.39, 0.33), (0.41, 0.31),
        (0.425, 0.30), (0.44, 0.12), (0.455, -0.02), (0.468, -0.04), (0.485, -0.15), (0.512, -0.52), (0.53, -0.38),
        (0.55, -0.12), (0.565, -0.03), (0.58, -0.23), (0.60, -0.33), (0.615, -0.16), (0.64, -0.38), (0.662, -0.47),
        (0.678, -0.14), (0.70, -0.02), (0.715, -0.13), (0.73, -0.12), (0.745, -0.02), (0.765, -0.05), (0.79, -0.19),
        (0.805, -0.16), (0.82, -0.02), (0.85, -0.03), (0.88, -0.01), (0.93, 0), (1, 0),
    ]
    /// Crests drawn as fans of nested contours.
    static let crestKeys: [Keys] = [
        [(0.43, 0), (0.457, 0.55), (0.47, 0.72), (0.485, 0.84), (0.50, 0.6), (0.52, 0.35), (0.545, 0.12), (0.56, 0)],
        [(0.62, 0), (0.64, 0.47), (0.652, 0.57), (0.668, 0.69), (0.688, 0.65), (0.70, 0.46), (0.713, 0.25), (0.735, 0)],
    ]
    /// Tall isolated spikes (x, tip), a light point on each tip.
    static let spikes: [(x: CGFloat, h: CGFloat)] = [
        (0.263, 0.55), (0.301, 0.73), (0.412, 0.55), (0.428, 0.93), (0.44, 0.86), (0.451, 0.65), (0.487, 1.08),
        (0.571, 0.45), (0.601, 0.84), (0.613, 0.89), (0.619, 0.78), (0.746, 0.33),
        (0.377, -0.47), (0.415, -0.5), (0.509, -0.68), (0.516, -0.6), (0.688, -0.56),
    ]

    private final class Plane: NSView {
        var paint: (CGContext) -> Void = { _ in }
        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            paint(ctx)
        }
    }

    private let far = Plane(), mid = Plane(), near = Plane()
    // keypoint splines sampled once per width, then audio and time applied each frame
    private var count = 0
    private var upperBase: [CGFloat] = [], lowerBase: [CGFloat] = [], crestBase: [[CGFloat?]] = []
    private var upper: [CGFloat] = [], lower: [CGFloat] = [], crests: [[CGFloat]] = []
    private var loud: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // blur radii in points: far plane out of focus, mid just softened, near sharp
        far.paint = { [weak self] in self?.drawFar($0) }
        mid.paint = { [weak self] in self?.drawMid($0) }
        near.paint = { [weak self] in self?.drawNear($0) }
        for (plane, blur) in [(far, 1.1), (mid, 0.3), (near, 0.0)] {
            plane.frame = bounds
            plane.autoresizingMask = [.width, .height]
            plane.wantsLayer = true
            if blur > 0 {
                plane.layerUsesCoreImageFilters = true
                plane.layer?.filters = [CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: blur])!]
            }
            addSubview(plane)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        recompute()
    }

    // MARK: geometry

    private static func spline(_ p: Keys, _ x: CGFloat) -> CGFloat {
        var i = 1
        while i < p.count - 1, p[i].x < x { i += 1 }
        let a = p[i - 1], b = p[i], dx = b.x - a.x
        let t = max(0, min(1, (x - a.x) / dx)), t2 = t * t, t3 = t2 * t
        let ta: CGFloat = i >= 2 ? (b.h - p[i - 2].h) / (b.x - p[i - 2].x) : 0
        let tb: CGFloat = i + 1 < p.count ? (p[i + 1].h - a.h) / (p[i + 1].x - a.x) : 0
        let ends: CGFloat = (2 * t3 - 3 * t2 + 1) * a.h + (-2 * t3 + 3 * t2) * b.h
        let slopes: CGFloat = ((t3 - 2 * t2 + t) * ta + (t3 - t2) * tb) * dx * 0.9
        return ends + slopes
    }
    private static func smooth(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }
    private static func gauss(_ x: CGFloat, _ c: CGFloat, _ w: CGFloat) -> CGFloat { exp(-(x - c) * (x - c) / (2 * w * w)) }
    /// Deterministic pseudo random 0..<1: strokes stay put between frames.
    private static func hash(_ i: Int) -> CGFloat {
        let s = sin(CGFloat(i) * 12.9898 + 78.233) * 43758.5453
        return s - floor(s)
    }
    /// Detail amount: almost nothing on the outer 10 %.
    private static func envelope(_ x: CGFloat) -> CGFloat { 0.04 + 0.96 * smooth(0.08, 0.3, x) * smooth(0.06, 0.25, 1 - x) }
    /// Where the spectrum spikes cluster.
    private static func density(_ x: CGFloat) -> CGFloat {
        max(gauss(x, 0.40, 0.035), gauss(x, 0.59, 0.03), 0.6 * gauss(x, 0.29, 0.02), 0.5 * gauss(x, 0.75, 0.02))
    }
    private static func ripple(_ x: CGFloat, _ t: CGFloat, _ k: CGFloat) -> CGFloat {
        let a: CGFloat = sin(x * 97 + t * 2.1 + k) * 0.5
        let b: CGFloat = sin(x * 173 - t * 1.3 + k * 2) * 0.3
        let c: CGFloat = sin(x * 311 + t * 3.7 + k * 3) * 0.2
        return a + b + c
    }
    /// Audio level at x: half the mean, half the band under x (interpolated).
    private func level(_ x: CGFloat) -> CGFloat {
        guard levels.count >= 2 else { return 0 }
        let p = x * CGFloat(levels.count - 1), i = min(levels.count - 2, Int(p)), f = p - CGFloat(i)
        return 0.5 * loud + 0.5 * (CGFloat(levels[i]) * (1 - f) + CGFloat(levels[i + 1]) * f)
    }

    private func recompute() {
        let n = max(60, Int(bounds.width / 1.5))
        if n != count {
            count = n
            let xs = (0 ... n).map { CGFloat($0) / CGFloat(n) }
            upperBase = xs.map { Self.spline(Self.upperKeys, $0) }
            lowerBase = xs.map { x in // narrow upward points between rounded valleys on the right
                let jag: CGFloat = 0.13 * pow(abs(sin(x * .pi * 26 + 0.6)), 7) * Self.smooth(0.56, 0.6, x) * Self.smooth(0.15, 0.19, 1 - x)
                return Self.spline(Self.lowerKeys, x) + jag
            }
            crestBase = Self.crestKeys.map { keys in xs.map { x in x > keys[0].x && x < keys[keys.count - 1].x ? Self.spline(keys, x) : nil } }
        }
        loud = levels.isEmpty ? 0 : CGFloat(levels.reduce(0, +) / Float(levels.count))
        upper = []; lower = []
        crests = crestBase.map { _ in [] }
        for i in 0 ... n {
            let x = CGFloat(i) / CGFloat(n), l = level(x), gain = 0.55 + 0.6 * l
            let wobble = { (k: CGFloat) -> CGFloat in 1 + 0.07 * sin(self.time * 0.9 + x * 23 + k) }
            let r = Self.envelope(x) * Self.ripple(x, time, 0) * (0.015 + 0.03 * l)
            let u = upperBase[i] * gain * wobble(0) + r, d = lowerBase[i] * gain * wobble(2) + r * 0.7
            upper.append(u)
            lower.append(d)
            for k in crestBase.indices {
                crests[k].append(max(crestBase[k][i].map { $0 * gain * wobble(4 + CGFloat(k)) } ?? -1, u, d))
            }
        }
        for plane in [far, mid, near] { plane.needsDisplay = true }
    }

    // MARK: drawing helpers

    private var scale: CGFloat { bounds.width / 880 } // the prototype was tuned at 880 px wide
    private var axis: CGFloat { bounds.height * 0.445 } // a bit below the middle, like the cover
    private var amp: CGFloat { bounds.height * 0.53 }
    private func px(_ i: Int) -> CGFloat { CGFloat(i) / CGFloat(count) * bounds.width }
    private func py(_ h: CGFloat) -> CGFloat { axis + max(-1.05, min(1.05, h)) * amp }
    private func width(_ w: CGFloat) -> CGFloat { max(0.5, w * scale) }

    private func color(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat) -> CGColor {
        CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
    }
    private func stroke(_ ctx: CGContext, _ values: [CGFloat], _ color: CGColor, _ w: CGFloat, from: Int = 0) {
        guard values.count > from + 1 else { return }
        ctx.addLines(between: (from ..< values.count).map { CGPoint(x: px($0), y: py(values[$0])) })
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width(w))
        ctx.strokePath()
    }
    /// Vertical hairlines batched by color: [(color, segments)].
    private func hairlines(_ ctx: CGContext, _ batches: [CGColor: [(CGPoint, CGPoint)]], _ w: CGFloat) {
        ctx.setLineWidth(width(w))
        for (color, segments) in batches {
            ctx.setStrokeColor(color)
            ctx.strokeLineSegments(between: segments.flatMap { [$0.0, $0.1] })
        }
    }
    private func ribbon(_ ctx: CGContext) {
        ctx.addLines(between: (0 ... count).map { CGPoint(x: px($0), y: py(upper[$0])) })
        ctx.addLines(between: (0 ... count).reversed().map { CGPoint(x: px($0), y: py(lower[$0])) })
        ctx.closePath()
    }
    /// Elliptic glow `rx` wide, `ry` tall.
    private func halo(_ ctx: CGContext, _ center: CGPoint, _ rx: CGFloat, _ ry: CGFloat, _ color: CGColor) {
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color, color.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: rx / ry, y: 1)
        ctx.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: ry, options: [])
        ctx.restoreGState()
    }

    // MARK: planes

    private func drawFar(_ ctx: CGContext) {
        guard count > 0, upper.count == count + 1 else { return }
        let w = bounds.width
        halo(ctx, CGPoint(x: w * 0.52, y: axis), w * 0.42, bounds.height * 0.5, color(20, 48, 90, 0.55))
        // back of the ribbon: shifted, smaller copy of both edges
        let shift = Int(CGFloat(count) * 0.012)
        let back = { (a: [CGFloat]) in a.indices.map { a[min(self.count, $0 + shift)] * 0.86 } }
        stroke(ctx, back(upper), color(50, 140, 230, 0.45), 1.2)
        stroke(ctx, back(lower), color(50, 140, 230, 0.35), 1.0)
        // ruled lines across the ribbon (a twisted surface)
        for k in 1 ..< 9 {
            let f = CGFloat(k) / 9, s = sin(CGFloat(k) * 1.7)
            stroke(ctx, upper.indices.map { upper[$0] * (1 - f) + lower[$0] * f }, color(70, 150, 230, 0.10 + 0.06 * s * s), 0.5)
        }
        // echoes of both edges, stepping inside the ribbon
        for k in 1 ... 4 {
            let step = CGFloat(k)
            stroke(ctx, upper.indices.map { upper[$0] + 0.022 * step * (lower[$0] > upper[$0] ? 1 : -1) }, color(60, 140, 220, 0.22 - 0.04 * step), 0.5)
            stroke(ctx, lower.indices.map { lower[$0] + 0.02 * step * (upper[$0] > lower[$0] ? 1 : -1) }, color(60, 140, 220, 0.20 - 0.04 * step), 0.5)
        }
        // bloom, softened by this plane's blur
        stroke(ctx, upper, color(50, 170, 255, 0.45), 4)
        stroke(ctx, lower, color(50, 170, 255, 0.30), 3)
    }

    private func drawMid(_ ctx: CGContext) {
        guard count > 0, upper.count == count + 1 else { return }
        let n = count, l = loud
        // spectrum: dense fine spikes over the ribbon, fewer under it
        var spectrum: [CGColor: [(CGPoint, CGPoint)]] = [:]
        for i in 0 ... n {
            let x = CGFloat(i) / CGFloat(n), d = Self.density(x)
            guard Self.hash(i) <= min(1, d * 1.3) else { continue }
            let top = max(upper[i], lower[i]), bottom = min(upper[i], lower[i]), b = Self.hash(i + 3)
            let tip = max(top, 0) + pow(Self.hash(i + 7), 1.8) * 0.42 * d * (0.5 + l)
            let c = b > 0.8 ? color(110, 210, 250, 0.7) : b > 0.4 ? color(50, 130, 215, 0.5) : color(50, 130, 215, 0.3)
            spectrum[c, default: []].append((CGPoint(x: px(i), y: py(top - 0.15 * Self.hash(i + 5))), CGPoint(x: px(i), y: py(tip))))
            if Self.hash(i + 11) < d * 0.35 {
                let end = min(bottom, 0) - pow(Self.hash(i + 13), 2) * 0.3 * d * (0.5 + l)
                spectrum[color(50, 130, 215, 0.2 + 0.35 * (b > 0.5 ? 1 : 0)), default: []].append((CGPoint(x: px(i), y: py(bottom)), CGPoint(x: px(i), y: py(end))))
            }
        }
        hairlines(ctx, spectrum, 0.6)
        // tall isolated spikes with a light point on the tip
        for spike in Self.spikes {
            let i = Int((spike.x * CGFloat(n)).rounded()), from = spike.h > 0 ? max(upper[i], lower[i]) : min(upper[i], lower[i])
            let tip = spike.h * (0.55 + 0.6 * level(spike.x)) * (0.85 + 0.3 * sin(time * 1.7 + spike.x * 40))
            ctx.move(to: CGPoint(x: px(i), y: py(from)))
            ctx.addLine(to: CGPoint(x: px(i) + 0.3, y: py(tip)))
            ctx.setStrokeColor(color(90, 185, 240, 0.75))
            ctx.setLineWidth(width(0.8))
            ctx.strokePath()
            halo(ctx, CGPoint(x: px(i), y: py(tip)), width(2.5), width(2.5), color(160, 240, 255, 0.9))
        }
        // ribbon: translucent fill between the edges (even-odd where they cross)
        ctx.saveGState()
        ribbon(ctx)
        ctx.clip(using: .evenOdd)
        let fill = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(40, 120, 210, 0.40), color(25, 60, 140, 0.30), color(40, 120, 210, 0.40)] as CFArray, locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(fill, start: CGPoint(x: 0, y: axis + amp), end: CGPoint(x: 0, y: axis - amp * 0.7), options: [])
        // inner glow along both edges
        stroke(ctx, upper, color(60, 170, 240, 0.16), bounds.height * 0.05 / max(scale, 0.01))
        stroke(ctx, upper, color(90, 200, 250, 0.18), bounds.height * 0.016 / max(scale, 0.01))
        stroke(ctx, lower, color(60, 160, 240, 0.12), bounds.height * 0.04 / max(scale, 0.01))
        ctx.restoreGState()
        // hairline hatch inside the ribbon, irregular brightness: the organic texture
        var hatch: [CGColor: [(CGPoint, CGPoint)]] = [:]
        for i in 0 ... n where abs(upper[i] - lower[i]) > 0.01 {
            let k = Self.hash(i + 40)
            guard k >= 0.3 else { continue }
            let c = k > 0.9 ? color(120, 210, 255, 0.26) : k > 0.6 ? color(55, 120, 215, 0.16) : color(55, 120, 215, 0.09)
            hatch[c, default: []].append((CGPoint(x: px(i), y: py(upper[i])), CGPoint(x: px(i), y: py(lower[i]))))
        }
        hairlines(ctx, hatch, 0.5)
        // crests: nested contours from the ribbon top up to the crest (moiré)
        for crest in crests {
            for k in 1 ... 16 {
                let f = CGFloat(k) / 16
                let line = crest.indices.map { i -> CGFloat in
                    let base = max(upper[i], lower[i])
                    return base + (crest[i] - base) * f
                }
                stroke(ctx, line, k == 16 ? color(130, 220, 255, 0.7) : color(70, 150, 225, 0.12 + 0.12 * f), k == 16 ? 0.9 : 0.5)
            }
        }
        // lower edge: glowing up to 56 %, dotted after
        let split = Int(CGFloat(n) * 0.56)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 7 * scale, color: color(60, 200, 255, 0.9))
        stroke(ctx, Array(lower[0 ... split]), color(98, 205, 231, 0.9), 1.2)
        ctx.setLineDash(phase: 0, lengths: [width(1.2), width(1.8)])
        stroke(ctx, lower, color(120, 220, 250, 0.9), 1.0, from: split)
        ctx.restoreGState()
    }

    private func drawNear(_ ctx: CGContext) {
        guard count > 0, upper.count == count + 1 else { return }
        let w = bounds.width, n = count
        // bright edge: cyan with a short glow, a paler core
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 8 * scale, color: color(60, 200, 255, 0.9))
        stroke(ctx, upper, color(98, 205, 231, 0.95), 1.4)
        ctx.restoreGState()
        stroke(ctx, upper, color(180, 245, 255, 0.7), 0.6)
        // center line edge to edge: cyan streaks at both ends, royal blue under the ribbon
        let line = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
            color(120, 250, 255, 1), color(70, 210, 255, 0.95), color(40, 110, 220, 0.6), color(40, 90, 220, 0.7), color(110, 250, 255, 0.95), color(90, 220, 255, 0.5),
        ] as CFArray, locations: [0, 0.12, 0.3, 0.75, 0.93, 1])!
        let thickness = width(1.8)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 6 * scale, color: color(60, 200, 255, 0.9))
        ctx.clip(to: CGRect(x: 0, y: axis - thickness / 2, width: w, height: thickness))
        ctx.drawLinearGradient(line, start: .zero, end: CGPoint(x: w, y: 0), options: [])
        ctx.restoreGState()
        halo(ctx, CGPoint(x: w * 0.06, y: axis), w * 0.1, width(6), color(100, 240, 255, 0.7))
        halo(ctx, CGPoint(x: w * 0.96, y: axis), w * 0.05, width(5), color(100, 240, 255, 0.7))
        halo(ctx, CGPoint(x: w * 0.75, y: axis), w * 0.06, width(3), color(60, 110, 255, 0.45))
        // progress: what is left of the track is dimmer, a light point at the playhead
        let head = w * max(0, min(1, progress))
        ctx.setFillColor(color(5, 10, 18, 0.45))
        ctx.fill(CGRect(x: head, y: axis - thickness / 2, width: w - head, height: thickness))
        if progress > 0 { halo(ctx, CGPoint(x: head, y: axis), width(9), width(3), color(180, 245, 255, 0.9)) }
        // light points where the edges cross and on the crests of the bright edge
        for i in 1 ..< n {
            let crossing = (upper[i] - lower[i]) * (upper[i + 1] - lower[i + 1]) < 0
            let top = upper[i] > upper[i - 1] && upper[i] >= upper[i + 1] && upper[i] > 0.2
            if crossing || top { halo(ctx, CGPoint(x: px(i), y: py(upper[i])), width(4), width(4), color(170, 240, 255, 0.55)) }
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
                    if playing { self.wave.time += 1.0 / 30 } // paused: the wave freezes and settles
                    if self.wave.levels != self.shownLevels || playing { self.wave.levels = self.shownLevels } // recomputes and redraws
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
