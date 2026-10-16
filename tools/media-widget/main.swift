// skyland media widget: floating glass overlay with the now playing media of
// any app (Spotify, Brave/YouTube, Music...), draggable, on every workspace.
// Now playing comes from third_party/mediaremote-adapter (MediaRemote through
// the entitled /usr/bin/perl, needed since macOS 15.4). Colors follow the
// current skyland theme (~/.cache/skyland/theme.css). Toggled by bin/skyland-media.
// Audio-reactive bars (cava-like): system audio from ScreenCaptureKit (audio only,
// while something plays; uses the Screen Recording permission of the launching
// app), FFT with Accelerate, log-spaced bands with auto gain.
// --style audioware: the bars become the live audio wave drawn like the cover of
// github.com/cyb3rpsych0s1s/audioware (tools/media-widget/audioware): a luminous ribbon
// around a cyan center line, flat when silent; the line is the progress.
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

/// Audioware style visualizer: the live audio wave drawn like the cover of
/// github.com/cyb3rpsych0s1s/audioware (tools/media-widget/audioware: render.js is the
/// reference drawing, model.json the look tuned on the cover). Silent or paused: a flat
/// line. Playing, like an oscilloscope on the low signal (advance): the bright edge A is
/// the bass, the second edge B the same 10 ms earlier, a ribbon that twists, shaped by
/// the cover's amplitude window; crest fans on the two highest peaks, a dotted jagged
/// edge hanging by |mid|, spectrum peaks where mid is strong, hairs under troughs with
/// the bass, light from slope and amplitude, onsets flash. Four depth planes, each a
/// layer blurred by Core Image: glow (ribbon light, inner and outer glows), far (tight
/// glows), mid (hatch, peaks, fans, secondary edges), near (bright edge, center line =
/// progress, light points) sharp.
final class AudiowareWave: NSView {
    var progress: CGFloat = 0 { didSet { if progress != oldValue { near.needsDisplay = true } } }
    /// Height of the center line from the bottom, 0...1 (on the cover 0.445).
    var axisFraction: CGFloat = 0.445 { didSet { recompute() } }

    static let night = rgb(0x0A121A), deep = rgb(0x153054), electric = rgb(0x168FC6)
    static let cyan = rgb(0x28CFFF), light = rgb(0x69E7FF), ice = rgb(0xB4F5FF)

    typealias RGB = (r: CGFloat, g: CGFloat, b: CGFloat)
    typealias Curve = [(x: CGFloat, v: CGFloat)]

    /// tools/media-widget/audioware/model.json: gains tuned on the cover, its amplitude window.
    struct Model {
        var gain: [String: CGFloat] = [:]
        var window: Curve = [(0, 0), (1, 0)]

        init() {}

        init?(url: URL) {
            guard let data = try? Data(contentsOf: url),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            for (key, value) in json["gain"] as? [String: Double] ?? [:] { gain[key] = CGFloat(value) }
            let keys = (json["window"] as? [[Double]] ?? []).filter { $0.count >= 2 }.map { (x: CGFloat($0[0]), v: CGFloat($0[1])) }
            if keys.count >= 2 { window = keys }
        }
    }

    private final class Plane: NSView {
        var paint: (CGContext) -> Void = { _ in }
        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            paint(ctx)
        }
    }

    private let model = Model(url: repo.appending(path: "tools/media-widget/audioware/model.json")) ?? Model()
    private let glow = Plane(), far = Plane(), mid = Plane(), near = Plane()

    // shape resolution; samples shown (80 ms) and B's delay (10 ms) at 6 kHz (render.js WAVE)
    private static let points = 256, shown = 480, shift = 60

    // audio state (render.js makeAudio / advanceAudio)
    private var activity: CGFloat = 0 // 0 paused ... 1 playing
    private var presence: CGFloat = 0 // 0 silent (flat line) ... 1 sound
    private var bands: [CGFloat] = []
    private var loud: CGFloat = 0, loudSlow: CGFloat = 0, pulse: CGFloat = 0, bass: CGFloat = 0, mids: CGFloat = 0
    private var peakLow: CGFloat = 1e-5, peakMid: CGFloat = 1e-5
    private var raw: [CGFloat]? // last window, for the trigger
    private var shapeA = [CGFloat](repeating: 0, count: AudiowareWave.points)
    private var shapeB = [CGFloat](repeating: 0, count: AudiowareWave.points)
    private var shapeM = [CGFloat](repeating: 0, count: AudiowareWave.points)
    private struct Crest { var x: CGFloat, height: CGFloat, target: CGFloat }
    private var crests: [Crest] = []
    private var spikes: [(x: CGFloat, m: CGFloat)] = []
    private var flatDrawn = false

    // per width
    private var n = 0
    private var xs: [CGFloat] = [], win: [CGFloat] = []
    // per frame
    private var heights: [String: [CGFloat]] = [:], lightOf: [String: [CGFloat]] = [:]
    private var top: [CGFloat] = [], bottom: [CGFloat] = [], thick: [CGFloat] = [], strength: [CGFloat] = []
    private var fill: [CGFloat] = [], inner: [CGFloat] = [], outer: [CGFloat] = [], boost: [CGFloat] = []
    private var amp: CGFloat { activity * presence }

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

    // MARK: audio

    /// 30 times a second: band levels (0...1, fast rise, slow fall) and the decimated low /
    /// mid signals of AudioBands (nil when paused).
    func advance(levels input: [Float], playing: Bool, wave: (low: [Float], mid: [Float])?) {
        let target: CGFloat = playing ? 1 : 0, settling = abs(activity - target) > 0.002
        activity = settling ? activity + (target - activity) * 0.08 : target
        if bands.count != input.count { bands = [CGFloat](repeating: 0, count: input.count) }
        for i in bands.indices { // fast attack, softer release
            let v = CGFloat(input[i])
            bands[i] += (v - bands[i]) * (v > bands[i] ? 0.6 : 0.18)
        }
        let mean = { (part: ArraySlice<CGFloat>) -> CGFloat in part.isEmpty ? 0 : part.reduce(0, +) / CGFloat(part.count) }
        loud = mean(bands[...])
        loudSlow += (loud - loudSlow) * 0.05
        pulse = max(pulse * 0.86, min(1, max(0, (loud - loudSlow) * 4))) // onsets
        bass = mean(bands.prefix(3))
        mids = mean(bands.dropFirst(3).prefix(6))
        let signal = playing ? wave.flatMap { shownSignal($0.low, $0.mid) } : nil
        // silence (or no capture, or paused): back to the flat line
        let gate = signal.map { max(0, min(1, ($0.rms - 0.002) / 0.008)) } ?? 0
        presence += (gate - presence) * (gate > presence ? 0.25 : 0.08)
        let size = 0.9 * (0.65 + 0.5 * loud)
        for r in 0 ..< Self.points {
            let w = Self.linear(model.window, CGFloat(r) / CGFloat(Self.points - 1)) * amp * size
            let a = signal.map { w * Self.soft($0.a[r]) } ?? 0, b = signal.map { w * 0.9 * Self.soft($0.b[r]) } ?? 0
            let m = signal.map { abs($0.m[r]) } ?? 0
            shapeA[r] += (a - shapeA[r]) * 0.5
            shapeB[r] += (b - shapeB[r]) * 0.5
            shapeM[r] += (m - shapeM[r]) * 0.5
        }
        followCrests()
        findSpikes()
        let flat = !shapeA.contains { abs($0) > 1e-4 } && !shapeB.contains { abs($0) > 1e-4 } && pulse < 0.001
        if flat, flatDrawn { return } // the flat line is on screen already
        flatDrawn = flat
        recompute()
    }

    /// Round off the loudest swings; troughs 0.72 of crests, like the cover (+0.84 / -0.6).
    private static func soft(_ v: CGFloat) -> CGFloat {
        let k = tanh(v * 1.1) / tanh(1.1)
        return k < 0 ? k * 0.72 : k
    }

    /// The 80 ms of the low / mid signals shown this frame, normalized by slow peaks.
    private func shownSignal(_ low: [Float], _ mid: [Float]) -> (a: [CGFloat], b: [CGFloat], m: [CGFloat], rms: CGFloat)? {
        let count = Self.shown, delay = Self.shift, length = min(low.count, mid.count)
        guard length >= count + delay + 2 else { return nil }
        func at(_ values: [Float], _ start: Int, _ x: CGFloat) -> CGFloat {
            let p = CGFloat(start) + x * CGFloat(count - 1), i = min(values.count - 2, Int(p)), f = p - CGFloat(i)
            return CGFloat(values[i]) * (1 - f) + CGFloat(values[i + 1]) * f
        }
        // oscilloscope trigger: the offset most like the last frame, else the first rising zero crossing
        let maxOffset = length - count - delay
        var best = -1
        if let raw {
            var error = CGFloat.infinity
            for offset in stride(from: 0, through: maxOffset, by: 2) {
                var e: CGFloat = 0
                for k in 0 ..< 32 {
                    let d = at(low, offset + delay, CGFloat(k) / 31) / peakLow - raw[k]
                    e += d * d
                }
                if e < error { error = e; best = offset }
            }
        }
        if best < 0 {
            best = (0 ..< maxOffset).first { low[$0 + delay] <= 0 && low[$0 + delay + 1] > 0 } ?? 0
        }
        // normalized by slow peaks of the shown part, so the wave fills the window
        var highLow: Float = 1e-6, highMid: Float = 1e-6, energy: Float = 0
        for i in best ..< best + delay + count {
            highLow = max(highLow, abs(low[i]))
            highMid = max(highMid, abs(mid[i]))
        }
        peakLow = max(CGFloat(highLow), peakLow * 0.92, 1e-5)
        peakMid = max(CGFloat(highMid), peakMid * 0.92, 1e-5)
        raw = (0 ..< 32).map { at(low, best + delay, CGFloat($0) / 31) / peakLow }
        for i in best + delay ..< best + delay + count { energy += low[i] * low[i] + mid[i] * mid[i] }
        let steps = (0 ..< Self.points).map { CGFloat($0) / CGFloat(Self.points - 1) }
        return (steps.map { at(low, best + delay, $0) / peakLow }, steps.map { at(low, best, $0) / peakLow },
                steps.map { at(mid, best + delay, $0) / peakMid }, CGFloat(sqrt(energy / Float(count))))
    }

    /// Crest fans on the two highest peaks of A, followed from frame to frame.
    private func followCrests() {
        let last = Self.points - 1
        var found: [(x: CGFloat, h: CGFloat)] = []
        for r in 2 ..< last - 1 {
            let x = CGFloat(r) / CGFloat(last), h = shapeA[r]
            if x > 0.22, x < 0.84, h > 0.1, h >= shapeA[r - 1], h >= shapeA[r + 1], h >= shapeA[r - 2], h >= shapeA[r + 2] { found.append((x, h)) }
        }
        var peaks: [(x: CGFloat, h: CGFloat)] = []
        for p in found.sorted(by: { $0.h > $1.h }) where peaks.count < 2 && peaks.allSatisfy({ abs($0.x - p.x) > 0.1 }) { peaks.append(p) }
        for i in crests.indices { crests[i].target = 0 }
        for p in peaks {
            let i: Int
            if let found = crests.firstIndex(where: { abs($0.x - p.x) < 0.06 }) {
                i = found
            } else {
                crests.append(Crest(x: p.x, height: 0, target: 0))
                i = crests.count - 1
            }
            crests[i].x += (p.x - crests[i].x) * 0.35
            crests[i].target = p.h * (0.45 + 0.5 * mids)
        }
        for i in crests.indices { crests[i].height += (crests[i].target - crests[i].height) * 0.3 }
        crests = Array(crests.filter { $0.height > 0.005 || $0.target > 0 }.sorted { $0.target > $1.target }.prefix(2))
    }

    /// Spectrum peaks where the mid signal is strong.
    private func findSpikes() {
        let last = Self.points - 1
        var found: [(x: CGFloat, m: CGFloat)] = []
        for r in 3 ..< last - 2 {
            let x = CGFloat(r) / CGFloat(last), m = shapeM[r]
            if m > 0.35, Self.linear(model.window, x) > 0.25, m >= shapeM[r - 1], m > shapeM[r + 1], m >= shapeM[r - 3], m > shapeM[r + 3] { found.append((x, m)) }
        }
        spikes = Array(found.sorted { $0.m > $1.m }.prefix(10))
    }

    // MARK: geometry

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
    /// Crest outline over A: a steep straight rise to the apex, a long fall (the cover's crests).
    private static func crestKernel(_ d: CGFloat) -> CGFloat { d < -0.03 || d > 0.12 ? 0 : d < 0 ? 1 + d / 0.03 : pow(1 - d / 0.12, 2) }
    private static func cgColor(_ c: RGB, _ a: CGFloat) -> CGColor {
        CGColor(srgbRed: c.r / 255, green: c.g / 255, blue: c.b / 255, alpha: max(0, min(1, a)))
    }
    /// A color of the design, in the theme's colors.
    private func rgba(_ c: RGB, _ a: CGFloat) -> CGColor { Self.cgColor(tone(c), a) }

    // MARK: theme (render.js makeTone)

    private var hueShift: CGFloat = 0, saturationScale: CGFloat = 1, inkOnPaper = false, themed = false
    private var softInk = false // the glow planes take the lighter ink on light themes
    private var background: RGB = (10, 18, 26)
    private var toned: [String: RGB] = [:]

    /// Follow the skyland theme: every color of the design turns from the cover's cyan to
    /// `accent` (hue rotated, saturation scaled, brightness kept). On a light `background`
    /// it is ink on paper: brightness inverted for the sharp lines, a lighter ink for the
    /// glows, dark tints of the cover's atmosphere turn pale. nil: the cover's colors.
    func setTheme(accent: NSColor?, background color: NSColor?) {
        let reference = Self.hsv((98, 205, 231))
        themed = accent != nil
        if let accent, let accentRGB = Self.components(accent) {
            let target = Self.hsv(accentRGB)
            hueShift = target.h - reference.h
            saturationScale = max(0, min(1.3, target.s / reference.s))
        }
        background = color.flatMap { Self.components($0) } ?? (10, 18, 26)
        inkOnPaper = themed && (0.2126 * background.r + 0.7152 * background.g + 0.0722 * background.b) / 255 > 0.5
        toned = [:]
        for plane in [glow, far, mid, near] { plane.needsDisplay = true }
    }

    private func tone(_ c: RGB) -> RGB {
        guard themed else { return c }
        let key = "\(c.r),\(c.g),\(c.b),\(softInk)"
        if let cached = toned[key] { return cached }
        var (h, s, v) = Self.hsv(c)
        h = (h + hueShift).truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        s = min(1, s * saturationScale)
        if inkOnPaper {
            s *= pow(min(1, v / 0.6), 2)
            if softInk {
                s *= 0.75
                v = max(0.45, min(0.92, 1.02 - 0.5 * v))
            } else {
                v = max(0.22, min(0.8, 1.08 - v))
            }
        }
        let result = Self.fromHSV(h: h, s: s, v: v)
        toned[key] = result
        return result
    }

    private static func components(_ color: NSColor) -> RGB? {
        guard let c = color.usingColorSpace(.sRGB) else { return nil }
        return (c.redComponent * 255, c.greenComponent * 255, c.blueComponent * 255)
    }
    private static func hsv(_ c: RGB) -> (h: CGFloat, s: CGFloat, v: CGFloat) {
        let r = c.r / 255, g = c.g / 255, b = c.b / 255, high = max(r, g, b), d = high - min(r, g, b)
        var h: CGFloat = 0
        if d > 0 {
            if high == r {
                h = 60 * ((g - b) / d).truncatingRemainder(dividingBy: 6)
            } else if high == g {
                h = 60 * ((b - r) / d + 2)
            } else {
                h = 60 * ((r - g) / d + 4)
            }
        }
        if h < 0 { h += 360 }
        return (h, high > 0 ? d / high : 0, high)
    }
    private static func fromHSV(h: CGFloat, s: CGFloat, v: CGFloat) -> RGB {
        let c = v * s, x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1)), m = v - c
        let parts: (CGFloat, CGFloat, CGFloat)
        switch Int(h / 60) % 6 {
        case 0: parts = (c, x, 0)
        case 1: parts = (x, c, 0)
        case 2: parts = (0, c, x)
        case 3: parts = (0, x, c)
        case 4: parts = (x, 0, c)
        default: parts = (c, 0, x)
        }
        return (((parts.0 + m) * 255).rounded(), ((parts.1 + m) * 255).rounded(), ((parts.2 + m) * 255).rounded())
    }
    private func gain(_ key: String) -> CGFloat { model.gain[key] ?? 0 }

    private func recompute() {
        let count = max(60, Int((bounds.width / 1.5).rounded()))
        if count != n {
            n = count
            xs = (0 ... n).map { CGFloat($0) / CGFloat(n) }
            win = xs.map { Self.linear(model.window, $0) }
            // blur radii follow the width, like the prototype (glow 6, far 1.2, mid 0.35 per 1000)
            for (plane, radius) in [(glow, 6.0), (far, 1.2), (mid, 0.35)] {
                plane.layer?.filters = [CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: radius * Double(bounds.width) / 1000])!]
            }
        }
        let sample = { (shape: [CGFloat]) -> [CGFloat] in
            self.xs.map { x -> CGFloat in
                let p = x * CGFloat(shape.count - 1), k = min(shape.count - 2, Int(p)), f = p - CGFloat(k)
                return shape[k] * (1 - f) + shape[k + 1] * f
            }
        }
        let a = sample(shapeA), b = sample(shapeB), m = sample(shapeM)
        top = (0 ... n).map { max(a[$0], b[$0]) }
        bottom = (0 ... n).map { min(a[$0], b[$0]) }
        thick = (0 ... n).map { min(1, (top[$0] - bottom[$0]) / 0.25) }
        heights = ["A": a, "B": b, "D": (0 ... n).map { bottom[$0] - win[$0] * amp * (0.05 + 0.28 * m[$0]) }] // dotted jagged edge
        for (k, crest) in crests.enumerated() {
            heights["C\(k + 1)"] = (0 ... n).map { i -> CGFloat in
                let d = xs[i] - crest.x - 0.03
                return d >= -0.03 && d <= 0.12 ? a[i] + crest.height * Self.crestKernel(d) : .nan
            }
        }
        // light: slope and amplitude of the line (the cover's flanks and crests glow)
        let on = min(1, amp * 4)
        let lightA = (0 ... n).map { i -> CGFloat in
            let j = min(n, i + 1), k = max(0, i - 1), slope = abs((a[j] - a[k]) / (CGFloat(j - k) / CGFloat(n)))
            return min(1, 0.3 + 0.9 * abs(a[i]) + 0.05 * slope) * on
        }
        lightOf = ["A": lightA, "B": lightA.map { $0 * 0.8 }, "D": win.map { $0 > 0.05 ? 0.55 * on : 0 }]
        for name in ["C1", "C2"] { if let h = heights[name] { lightOf[name] = h.map { $0.isNaN ? 0 : 0.55 * on } } }
        fill = lightA.map { 0.12 + 0.45 * $0 }
        inner = lightA.map { 0.25 + 0.8 * $0 }
        outer = lightA.map { 0.15 + 0.7 * $0 }
        boost = [CGFloat](repeating: 1 + amp * 0.45 * pulse, count: n + 1) // onsets flash
        strength = m
        for plane in [glow, far, mid, near] { plane.needsDisplay = true }
    }

    // MARK: drawing helpers

    private var unitScale: CGFloat { bounds.width / 1000 }
    private var axisY: CGFloat { bounds.height * axisFraction }
    private func px(_ i: Int) -> CGFloat { CGFloat(i) / CGFloat(n) * bounds.width }
    /// Soft knee above 0.85 so loud crests round off instead of flattening.
    private func py(_ h: CGFloat) -> CGFloat {
        let m = abs(h), clipped = m <= 0.85 ? h : (h < 0 ? -1 : 1) * (0.85 + 0.2 * tanh((m - 0.85) / 0.2))
        return axisY + clipped * bounds.height * 0.525
    }
    private func point(_ i: Int, _ h: CGFloat) -> CGPoint { CGPoint(x: px(i), y: py(h)) }
    /// Width given at 1000 px wide, at least half a point.
    private func lw(_ w: CGFloat) -> CGFloat { max(0.5, w * unitScale) }
    private var column: CGFloat { bounds.width / CGFloat(n) + 0.5 * unitScale }
    private var lineNames: [String] { ["A", "B", "C1", "C2", "D"].filter { heights[$0] != nil } }

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
            ctx.setStrokeColor(rgba(color, CGFloat(bucket) / 20))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    private typealias Hair = (from: CGPoint, to: CGPoint, color: Int, alpha: CGFloat)
    /// Hair colors; 6... the center line from cyan (free) to royal blue (under the ribbon) in 6 steps.
    private static let hairColors: [RGB] = [(55, 125, 215), (120, 210, 255), (110, 200, 250), (90, 170, 240), (60, 140, 225), (40, 110, 195)]
        + (0 ... 6).map { step -> RGB in
            let t = CGFloat(step) / 6
            return ((110 + (40 - 110) * t).rounded(), (240 + (90 - 240) * t).rounded(), (255 + (200 - 255) * t).rounded())
        }
        + [(110, 235, 255)]
    private static let axisColor = 6, axisGlowColor = 13
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
            ctx.setStrokeColor(rgba(Self.hairColors[key / 100], CGFloat(key % 100) / 20))
            ctx.strokeLineSegments(between: points)
        }
        ctx.restoreGState()
    }

    /// Elliptic glow `rx` wide, `ry` tall.
    private func halo(_ ctx: CGContext, _ center: CGPoint, _ rx: CGFloat, _ ry: CGFloat, _ color: RGB, _ alpha: CGFloat) {
        guard rx > 0, ry > 0, alpha > 0 else { return }
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgba(color, alpha), rgba(color, 0)] as CFArray, locations: [0, 1])!
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

    private var ready: Bool { n > 0 && top.count == n + 1 && boost.count == n + 1 }

    // MARK: planes

    /// Ribbon light per column, the light the edges pour inside it, wide halos, axis glow.
    private func drawGlow(_ ctx: CGContext) {
        guard ready else { return }
        softInk = true
        defer { softInk = false }
        let w = bounds.width, h = bounds.height
        if amp > 0.01 { halo(ctx, CGPoint(x: w * 0.53, y: axisY), w * 0.40, h * 0.42, (22, 45, 80), 0.45 * amp) }
        var columns: [Hair] = []
        for i in 0 ... n where top[i] - bottom[i] >= 0.005 {
            let a = gain("fill") * fill[i] * boost[i]
            if top[i] > 0 { columns.append((point(i, top[i]), point(i, max(0, bottom[i])), 5, a)) }
            if bottom[i] < 0 { columns.append((point(i, min(0, top[i])), point(i, bottom[i]), 5, a)) }
        }
        hairs(ctx, columns, width: column)
        ctx.saveGState()
        ctx.addPath(ribbonPath())
        ctx.clip()
        for name in ["A", "B"] {
            let a = gain("inner") * (name == "A" ? 1 : gain("innerB")), profile = name == "A" ? inner : nil
            lit(ctx, name, (45, 185, 235), a, gain("innerW"), step: 6, profile: profile)
            lit(ctx, name, (90, 215, 250), a, gain("innerW") * 0.4, step: 6, profile: profile)
        }
        lit(ctx, "B", (50, 140, 230), gain("ramp"), 40, step: 6)
        ctx.restoreGState()
        for name in lineNames {
            lit(ctx, name, (35, 165, 230), gain("outer") * (name == "A" ? 1 : gain("outerB")), gain("outerW"), step: 6, profile: name == "A" ? outer : nil)
        }
        // the axis glows where it is free, like the flat ends of the cover
        hairs(ctx, (0 ... n).map { i -> Hair in
            (CGPoint(x: px(i), y: axisY - lw(4)), CGPoint(x: px(i), y: axisY + lw(4)), Self.axisGlowColor, gain("axisHalo") * 0.6 * (1 - thick[i]))
        }, width: column)
    }

    /// Tight glows around every line.
    private func drawFar(_ ctx: CGContext) {
        guard ready else { return }
        softInk = true
        defer { softInk = false }
        for name in lineNames {
            lit(ctx, name, (60, 195, 240), gain("far") * (name == "A" ? 1 : gain("outerB")), gain("farW"))
        }
    }

    /// Hatch, spectrum peaks, hanging hairs, crest fans, secondary edges.
    private func drawMid(_ ctx: CGContext) {
        guard ready, let d = heights["D"], let a = heights["A"], let lightD = lightOf["D"] else { return }
        let w = bounds.width, on = min(1, amp * 4)
        var hatch: [Hair] = []
        for i in 0 ... n where top[i] - bottom[i] >= 0.01 {
            let r = Self.hash(i + 40)
            hatch.append((point(i, top[i]), point(i, bottom[i]), r > 0.93 ? 1 : 0, gain("hatch") * fill[i] * (0.25 + 1.1 * r) * boost[i] * 2))
        }
        for i in 0 ... n where Self.hash(i + 61) < 0.5 && bottom[i] - d[i] > 0.02 { // sparse under the ribbon
            hatch.append((point(i, bottom[i]), point(i, d[i]), 0, 0.1 * lightD[i] * boost[i]))
        }
        hairs(ctx, hatch, width: lw(0.55))
        // spectrum peaks: narrow glowing peaks with concave flanks, the tallest go on as a
        // hairline with a light tip
        var lines: [Hair] = []
        for spike in spikes {
            let i = Int((spike.x * CGFloat(n)).rounded()), base = top[i]
            let tip = base + (0.06 + 0.45 * spike.m) * amp * win[i] * (0.6 + 0.8 * mids)
            guard tip - base >= 0.03 else { continue }
            let height = min(0.22, tip - base), half = (0.003 + 0.02 * height) * w, apex = point(i, base + height), peak = gain("peak") * boost[i]
            let path = CGMutablePath()
            path.move(to: CGPoint(x: apex.x - half, y: py(base)))
            path.addQuadCurve(to: apex, control: CGPoint(x: apex.x - half * 0.15, y: py(base + height * 0.25)))
            path.addQuadCurve(to: CGPoint(x: apex.x + half, y: py(base)), control: CGPoint(x: apex.x + half * 0.15, y: py(base + height * 0.25)))
            path.closeSubpath()
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgba((70, 170, 245), peak), rgba((70, 170, 245), peak * 0.3)] as CFArray, locations: [0, 1])!
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: py(base)), end: apex, options: [])
            ctx.restoreGState()
            ctx.addPath(path)
            ctx.setStrokeColor(rgba((110, 210, 250), peak * 1.2))
            ctx.setLineWidth(lw(0.5))
            ctx.strokePath()
            if tip - base > height + 0.02 {
                lines.append((apex, point(i, tip), 2, gain("spike") * boost[i]))
                if tip > 0.45 { halo(ctx, point(i, tip), lw(2), lw(2), (170, 240, 255), 0.5 * boost[i]) }
            }
        }
        // hairs over strong mids, hanging under troughs with the bass
        for i in 2 ... max(2, n - 2) {
            let up = strength[i] * win[i] * amp * 0.8, down = min(1, -bottom[i] * 2.5) * amp
            if Self.hash(i + 7) < up {
                let length = pow(Self.hash(i + 11), 2) * 0.3 * (0.5 + strength[i])
                lines.append((point(i, top[i]), point(i, top[i] + length), 4, gain("hairs") * (0.4 + 0.6 * Self.hash(i + 3)) * boost[i]))
            }
            if bottom[i] < -0.1, Self.hash(i + 17) < down * 0.7 {
                let length = (0.04 + pow(Self.hash(i + 19), 1.5) * 0.22) * (0.5 + bass), alpha = gain("hairs") * (0.4 + 0.6 * Self.hash(i + 23)) * boost[i]
                let middle = bottom[i] - length / 2
                lines.append((point(i, bottom[i]), point(i, middle), 4, alpha))
                lines.append((point(i, middle), point(i, bottom[i] - length), 4, alpha * 0.4))
            }
            let trough = bottom[i] <= bottom[i - 1] && bottom[i] < bottom[i + 1] && bottom[i] <= bottom[i - 2] && bottom[i] < bottom[i + 2]
            if bottom[i] < -0.18, trough { // the long hairs at the bottom of troughs
                let tip = bottom[i] - (0.12 + 0.25 * bass) * amp, middle = (bottom[i] + tip) / 2
                lines.append((point(i, bottom[i]), point(i, middle), 3, gain("spike") * boost[i]))
                lines.append((point(i, middle), point(i, tip), 3, gain("spike") * 0.45 * boost[i]))
            }
        }
        hairs(ctx, lines, width: lw(0.6))
        // crest fans: nested contours from A up to the crest (moire)
        for (name, alpha) in [("C1", gain("fanC1")), ("C2", gain("fan"))] {
            guard let crest = heights[name] else { continue }
            let range = (0 ... n).filter { !crest[$0].isNaN }
            guard let start = range.first else { continue }
            ctx.setLineWidth(lw(0.5))
            for f in 1 ... 22 {
                let q = CGFloat(f) / 22, path = CGMutablePath()
                path.move(to: point(start, a[start] + (crest[start] - a[start]) * q))
                for i in range.dropFirst() { path.addLine(to: point(i, a[i] + (crest[i] - a[i]) * q)) }
                ctx.addPath(path)
                ctx.setStrokeColor(rgba((75, 155, 230), alpha * (0.35 + 0.65 * q) * on))
                ctx.strokePath()
            }
        }
        lit(ctx, "B", (98, 205, 231), gain("core"), gain("coreB"), step: 3)
        lit(ctx, "C1", (120, 215, 245), 0.9, 0.8, step: 3)
        lit(ctx, "C2", (120, 215, 245), 0.9, 0.8, step: 3)
        lit(ctx, "D", (120, 215, 245), 1.0, 1.1, step: 3, dash: [1.4, 2.2])
    }

    /// Bright edge, center line (cyan where free, the flat line; royal blue under the
    /// ribbon; dimmer after the playhead), light points.
    private func drawNear(_ ctx: CGContext) {
        guard ready, let a = heights["A"], let b = heights["B"] else { return }
        let w = bounds.width, on = min(1, amp * 4)
        lit(ctx, "A", (98, 205, 231), gain("core"), gain("coreW"), step: 3)
        lit(ctx, "A", (190, 248, 255), 0.8 * gain("core"), 0.6, step: 3)
        let thickness = lw(gain("axisW")), flash = amp * pulse
        hairs(ctx, (0 ... n).map { i -> Hair in
            let step = Int((thick[i] * 6).rounded()), t = CGFloat(step) / 6
            return (CGPoint(x: px(i), y: axisY - thickness / 2), CGPoint(x: px(i), y: axisY + thickness / 2), Self.axisColor + step, (0.95 - 0.55 * t) * (1 + 0.8 * flash))
        }, width: column)
        let flare = 1 + 0.6 * flash
        halo(ctx, CGPoint(x: w * 0.06, y: axisY), w * 0.09 * flare, lw(gain("axisGlowW")), (110, 240, 255), gain("axisGlow") * flare)
        halo(ctx, CGPoint(x: w * 0.945, y: axisY), w * 0.03 * flare, lw(5), (120, 250, 255), 0.7)
        if amp > 0.01 { halo(ctx, CGPoint(x: w * 0.76, y: axisY), w * 0.07 * flare, lw(5), (45, 110, 230), 0.45 * amp * flare) }
        let head = w * max(0, min(1, progress))
        ctx.setFillColor(Self.cgColor(background, 0.45)) // what is left of the track
        ctx.fill(CGRect(x: head, y: axisY - thickness / 2, width: w - head, height: thickness))
        if progress > 0, progress < 1 { halo(ctx, CGPoint(x: head, y: axisY), lw(10), lw(3), (180, 245, 255), 0.9) }
        // light points where the edges cross and on crest tops
        for i in 1 ..< n where (a[i] - b[i]) * (a[i + 1] - b[i + 1]) < 0 && abs(a[i]) > 0.04 {
            halo(ctx, point(i, a[i]), lw(gain("lightR")), lw(gain("lightR")), (160, 235, 255), 0.45 * boost[i] * on)
        }
        for name in ["C1", "C2"] {
            guard let crest = heights[name], let apex = (0 ... n).filter({ !crest[$0].isNaN }).max(by: { crest[$0] < crest[$1] }) else { continue }
            halo(ctx, point(apex, crest[apex]), lw(gain("lightR") * 0.6), lw(gain("lightR") * 0.6), (160, 235, 255), 0.35 * on)
        }
    }
}

func rgb(_ v: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
}

/// RBJ biquad filter, one sample at a time.
struct Biquad {
    private let b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    init(lowpass frequency: Double, q: Double, rate: Double) {
        let w = 2 * Double.pi * frequency / rate, c = cos(w)
        self.init(b: ((1 - c) / 2, 1 - c, (1 - c) / 2), alpha: sin(w) / (2 * q), cosine: c)
    }

    /// Constant 0 dB peak gain.
    init(bandpass frequency: Double, q: Double, rate: Double) {
        let w = 2 * Double.pi * frequency / rate, alpha = sin(w) / (2 * q)
        self.init(b: (alpha, 0, -alpha), alpha: alpha, cosine: cos(w))
    }

    private init(b: (Double, Double, Double), alpha: Double, cosine: Double) {
        let a0 = 1 + alpha
        b0 = Float(b.0 / a0); b1 = Float(b.1 / a0); b2 = Float(b.2 / a0)
        a1 = Float(-2 * cosine / a0); a2 = Float((1 - alpha) / a0)
    }

    mutating func callAsFunction(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }
}

/// System audio -> band levels (and, with onWave, the signals of the audioware wave).
/// Runs only between start() and stop().
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
    /// The audio low-passed (~180 Hz) and band-passed (~1 kHz), decimated by 8 (6 kHz),
    /// the last 768 points of each (oldest first), about 30 times a second, on the main
    /// queue. Set before start().
    var onWave: (([Float], [Float]) -> Void)?
    private var lowFilter = Biquad(lowpass: 180, q: 0.707, rate: 48000), midFilter = Biquad(bandpass: 1000, q: 0.8, rate: 48000)
    private var lowRing = [Float](repeating: 0, count: 768), midRing = [Float](repeating: 0, count: 768), ringIndex = 0
    private var lowSum: Float = 0, midSum: Float = 0, decimation = 0, sinceWave = 0

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
            let chunk = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count)
            samples.append(contentsOf: chunk)
            if onWave != nil { follow(chunk) }
        }
        while samples.count >= Self.fftSize {
            let block = Array(samples.prefix(Self.fftSize))
            samples.removeFirst(Self.fftSize / 2) // 50% overlap
            let levels = bands(of: block)
            DispatchQueue.main.async { self.onLevels(levels) }
        }
    }

    /// Filters and decimates the new samples into the rings, hands them out ~30 times a second.
    private func follow(_ chunk: UnsafeBufferPointer<Float>) {
        for x in chunk {
            lowSum += lowFilter(x)
            midSum += midFilter(x)
            decimation += 1
            guard decimation == 8 else { continue }
            lowRing[ringIndex] = lowSum / 8
            midRing[ringIndex] = midSum / 8
            ringIndex = (ringIndex + 1) % lowRing.count
            lowSum = 0; midSum = 0; decimation = 0
        }
        sinceWave += chunk.count
        guard sinceWave >= 1600, let onWave else { return } // 30 times a second at 48 kHz
        sinceWave = 0
        let low = Array(lowRing[ringIndex...] + lowRing[..<ringIndex]), mid = Array(midRing[ringIndex...] + midRing[..<ringIndex])
        DispatchQueue.main.async { onWave(low, mid) }
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
    let size = NSSize(width: 380, height: 116)
    let radius: CGFloat = 18
    var panel: NSPanel!
    var tint: NSView!
    let artwork = NSImageView()
    let title = NSTextField(labelWithString: "Rien en lecture")
    let artist = NSTextField(labelWithString: "")
    let source = NSTextField(labelWithString: "")
    let progress = Progress()
    var playButton: NSButton!
    var watchdogTicks = 0
    let bars = Bars()
    let wave = AudiowareWave(frame: .zero)
    var shownLevels = [Float](repeating: 0, count: 14)
    var targetLevels = [Float](repeating: 0, count: 14)
    lazy var audio = AudioBands(bands: 14) { [weak self] levels in self?.targetLevels = levels }
    var signals: (low: [Float], mid: [Float])? // audioware: the latest filtered signals
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

        artwork.frame = NSRect(x: 14, y: 14, width: 88, height: 88)
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
            field.font = font
            field.lineBreakMode = .byTruncatingTail
            glass.addSubview(field)
        }
        progress.frame = NSRect(x: 114, y: 38, width: size.width - 128, height: 4)
        if audioware { // the wave is the background, under the artwork, text and buttons; its center line is the progress
            wave.frame = glass.bounds
            wave.axisFraction = progress.frame.midY / size.height
            glass.addSubview(wave, positioned: .above, relativeTo: tint)
            audio.onWave = { [weak self] low, mid in self?.signals = (low, mid) }
        } else {
            glass.addSubview(progress)
        }

        let controls: [(String, Int)] = [("backward.fill", 5), ("play.fill", 2), ("forward.fill", 4)]
        for (i, (symbol, command)) in controls.enumerated() {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!, target: self, action: #selector(send(_:)))
            button.isBordered = false
            button.tag = command
            button.symbolConfiguration = .init(pointSize: i == 1 ? 18 : 14, weight: .semibold)
            button.frame = NSRect(x: 114 + CGFloat(i) * 44, y: 8, width: 36, height: 26)
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
                    self.wave.advance(levels: self.shownLevels, playing: playing, wave: playing ? self.signals : nil) // silent or paused: flat line
                } else if self.bars.levels != self.shownLevels {
                    self.bars.levels = self.shownLevels
                }
            }
        }

        applyTheme()
        render()
        // streams left by a widget that did not stop them (now children of launchd)
        try? Process.run(URL(fileURLWithPath: "/usr/bin/pkill"), arguments: ["-P", "1", "-f", "mediaremote-adapter\\.pl .* stream "])
        startStream()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateProgress()
                self?.applyThemeIfChanged()
                self?.watchdogTicks += 1
                if (self?.watchdogTicks ?? 0) % 8 == 0 { self?.checkStream() } // every 4 s
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
    /// The wave in the theme's colors: its glow is the accent, or the highlight when the
    /// accent has no color (white, black, gray); the cover's cyan without a theme.
    func applyAudioware() {
        let c = themeColors()
        let colorful = { (color: NSColor?) in color.flatMap { $0.usingColorSpace(.sRGB) }.map { $0.saturationComponent >= 0.25 } ?? false }
        let glow: NSColor? = c.isEmpty ? nil : [c["accent"], c["highlight"]].first(where: colorful) ?? c["accent"]
        let background = c["bg"] ?? AudiowareWave.night
        wave.setTheme(accent: glow, background: c["bg"])
        tint.layer?.backgroundColor = background.withAlphaComponent(0.92).cgColor
        title.textColor = c["fg"] ?? AudiowareWave.ice
        artist.textColor = c["fg_dim"] ?? AudiowareWave.electric
        source.textColor = (glow ?? AudiowareWave.cyan).withAlphaComponent(0.9)
        for button in buttons { button.contentTintColor = c["fg"] ?? AudiowareWave.light }
        artwork.layer?.backgroundColor = (c["bg_hover"] ?? AudiowareWave.deep).cgColor
        artwork.contentTintColor = glow ?? AudiowareWave.cyan
        // the wave glows behind the text and buttons: a soft halo of the background keeps them legible
        for view in [title, artist, source] + buttons {
            let legible = NSShadow()
            legible.shadowColor = background.withAlphaComponent(0.95)
            legible.shadowBlurRadius = 4
            legible.shadowOffset = .zero
            view.shadow = legible
        }
    }

    // MARK: now playing

    /// The stream sometimes stops sending (the perl process lives on, silent): every few
    /// seconds the real state is asked once; if it differs from what is shown, it is shown
    /// and the stream is started again.
    func checkStream() {
        let shown = (state["title"] as? String, state["playing"] as? Bool ?? false)
        let p = adapter(["get", "--micros"])
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        DispatchQueue.global(qos: .utility).async {
            guard (try? p.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let real = (payload["title"] as? String, payload["playing"] as? Bool ?? false)
            guard real.0 != shown.0 || real.1 != shown.1 else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.state = payload
                self.render()
                self.stream?.terminationHandler = nil
                self.stream?.terminate()
                self.startStream()
            }
        }
    }

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
            artwork.image = NSImage(data: data).map(squared) // a 16:9 video thumbnail fills the square
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

/// The middle square of an image (aspect fill), for a thumbnail that is not square.
func squared(_ image: NSImage) -> NSImage {
    let size = image.size
    let side = min(size.width, size.height)
    guard side > 0, size.width != size.height else { return image }
    let crop = NSRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
    return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
        image.draw(in: rect, from: crop, operation: .copy, fraction: 1)
        return true
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
