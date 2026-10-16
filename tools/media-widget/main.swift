// skyland media widget: floating glass overlay with the now playing media of
// any app (Spotify, Brave/YouTube, Music...), draggable, on every workspace.
// Now playing comes from third_party/mediaremote-adapter (MediaRemote through
// the entitled /usr/bin/perl, needed since macOS 15.4). Colors follow the
// current skyland theme (~/.cache/skyland/theme.css). Toggled by bin/skyland-media.
// Audio-reactive bars (cava-like): system audio from ScreenCaptureKit (audio only,
// while something plays; uses the Screen Recording permission of the launching
// app), FFT with Accelerate, log-spaced bands with auto gain.
// --style audioware: the bars become a cyan light wave on night blue (after the
// cover of github.com/cyb3rpsych0s1s/audioware), its center line is the progress.
import Accelerate
import AppKit
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

/// Audioware style visualizer: an electroluminescent cyan wave on night blue, flat
/// at the edges, dense in the middle, its big crest at two thirds. The silhouette is
/// fixed (deterministic), audio scales it and drives the fine ripples. Drawn back to
/// front: background, halo, vertical depth strokes, secondary curves, membrane,
/// sharp contour, center line (brighter up to the playhead), peak highlights.
final class AudiowareWave: NSView {
    var levels: [Float] = [] { didSet { needsDisplay = true } }
    var time: CGFloat = 0
    var progress: CGFloat = 0 { didSet { if progress != oldValue { needsDisplay = true } } }

    static let night = rgb(0x050A12), deep = rgb(0x091727), steel = rgb(0x12618A), electric = rgb(0x168FC6)
    static let cyan = rgb(0x28CFFF), light = rgb(0x69E7FF), ice = rgb(0xB4F5FF)

    private static func gauss(_ x: CGFloat, _ c: CGFloat, _ w: CGFloat) -> CGFloat { exp(-(x - c) * (x - c) / (2 * w * w)) }
    private static func smooth(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }
    /// Deterministic pseudo random 0..<1 (the strokes stay put between frames).
    private static func hash(_ i: Int) -> CGFloat {
        let s = sin(CGFloat(i) * 12.9898 + 78.233) * 43758.5453
        return s - floor(s)
    }

    /// Silhouette, + up, in half heights: first crest at 1/4, triangular trough at
    /// 40 %, dense center, main crest at 2/3 then a smaller one, back to flat.
    private func shape(_ x: CGFloat, _ t: CGFloat) -> CGFloat {
        let g = Self.gauss
        let d = { (k: CGFloat) -> CGFloat in 0.006 * sin(t * 0.7 + k) } // slow drift of the crests
        let left: CGFloat = 0.30 * g(x, 0.25 + d(1), 0.045) + 0.12 * g(x, 0.31, 0.02)
        let trough: CGFloat = -0.85 * exp(-pow(abs(x - 0.405 - d(2)) / 0.03, 1.25))
        let center: CGFloat = 0.62 * g(x, 0.465 + d(3), 0.018) - 0.48 * g(x, 0.515, 0.012) + 0.50 * g(x, 0.555 + d(4), 0.02) - 0.22 * g(x, 0.60, 0.015)
        let crest: CGFloat = 0.95 * g(x, 0.665 + d(5), 0.045) + 0.48 * g(x, 0.75 + d(6), 0.028)
        let tail: CGFloat = -0.15 * g(x, 0.81, 0.02) + 0.08 * g(x, 0.87, 0.02)
        return left + trough + center + crest + tail
    }
    /// Detail density: almost nothing on the outer 10-15 %.
    private func envelope(_ x: CGFloat) -> CGFloat { 0.04 + 0.96 * Self.smooth(0.08, 0.35, x) * Self.smooth(0.08, 0.32, 1 - x) }
    private func ripple(_ x: CGFloat, _ t: CGFloat, _ k: CGFloat) -> CGFloat {
        let a: CGFloat = sin(x * 97 + t * 2.1 + k) * 0.5
        let b: CGFloat = sin(x * 173 - t * 1.3 + k * 2) * 0.3
        let c: CGFloat = sin(x * 311 + t * 3.7 + k * 3) * 0.2
        return a + b + c
    }
    /// Audio level at x: half the mean, half the band under x (interpolated).
    private func level(_ x: CGFloat) -> CGFloat {
        guard levels.count >= 2 else { return 0 }
        let mean = CGFloat(levels.reduce(0, +)) / CGFloat(levels.count)
        let p = x * CGFloat(levels.count - 1), i = min(levels.count - 2, Int(p)), f = p - CGFloat(i)
        let band = CGFloat(levels[i]) * (1 - f) + CGFloat(levels[i + 1]) * f
        return 0.5 * mean + 0.5 * band
    }
    /// Signed height of a curve, soft clipped so a loud crest never leaves the view.
    private func height(_ x: CGFloat, phase: CGFloat = 0, scale: CGFloat = 1, rippleGain: CGFloat = 1) -> CGFloat {
        let l = level(x)
        let body: CGFloat = shape(x, time + phase * 0.3) * scale * (0.45 + 0.75 * l)
        let fine: CGFloat = envelope(x) * ripple(x, time, phase) * (0.05 + 0.10 * l) * rippleGain
        return 1.1 * tanh((body + fine) / 1.1)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let w = bounds.width, mid = bounds.height * 0.5, amp = bounds.height * 0.42
        let loud = CGFloat(levels.isEmpty ? 0 : levels.reduce(0, +) / Float(levels.count))
        let count = max(60, Int(w / 1.5))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!

        // 1-2. the night background is the widget tint; faint blue then cyan atmosphere
        // behind the center, ellipses fading inside the view so it has no visible edge
        halo(ctx, space, center: CGPoint(x: w * 0.58, y: mid), width: w * 0.45, Self.deep.withAlphaComponent(0.9))
        halo(ctx, space, center: CGPoint(x: w * 0.6, y: mid), width: w * 0.25, Self.cyan.withAlphaComponent(0.05 + 0.05 * loud))

        // 3. vertical depth strokes, irregular, denser and longer around big amplitudes
        let strokes = Int(w / 6)
        ctx.setLineWidth(1)
        for i in 0 ..< strokes {
            let x = (CGFloat(i) + Self.hash(i) * 0.9) / CGFloat(strokes)
            let s = abs(shape(x, time))
            guard Self.hash(i + 500) <= envelope(x) * (0.3 + s * 2) else { continue }
            let h = height(x)
            let direction: CGFloat = Self.hash(i + 77) < 0.5 ? 1 : -0.6
            let reach: CGFloat = abs(h) * (0.3 + 1.3 * Self.hash(i + 900)) + 0.04 * Self.hash(i + 33)
            let length = reach * amp * direction
            let bright = Self.hash(i + 222) > 0.88
            let color = bright ? Self.light.withAlphaComponent(0.35 + 0.3 * loud) : Self.electric.withAlphaComponent(0.12 + 0.18 * Self.hash(i + 3))
            ctx.setStrokeColor(color.cgColor)
            ctx.move(to: CGPoint(x: x * w, y: mid + h * amp))
            ctx.addLine(to: CGPoint(x: x * w + (Self.hash(i + 4) - 0.5) * 3, y: mid + h * amp + length))
            ctx.strokePath()
        }

        // 4. secondary translucent curves, offset copies (two of them below the axis)
        let secondary: [(CGFloat, CGFloat, NSColor)] = [
            (0.82, 0.6, Self.electric.withAlphaComponent(0.35)), (0.64, 1.7, Self.steel.withAlphaComponent(0.4)),
            (1.12, 2.9, Self.electric.withAlphaComponent(0.22)), (-0.38, 4.1, Self.steel.withAlphaComponent(0.35)),
            (-0.6, 5.3, Self.steel.withAlphaComponent(0.2)),
        ]
        ctx.setLineWidth(0.8)
        for (scale, phase, color) in secondary {
            ctx.addLines(between: (0 ... count).map { i in
                let x = CGFloat(i) / CGFloat(count)
                let h = height(x, phase: phase, scale: scale, rippleGain: 1.2 + 1.2 * (1 - level(x)))
                return CGPoint(x: x * w, y: mid + h * amp)
            })
            ctx.setStrokeColor(color.cgColor)
            ctx.strokePath()
        }

        // 5. membrane between the main curve and the axis, hazy, transparent
        let main = (0 ... count).map { i in
            let x = CGFloat(i) / CGFloat(count)
            return CGPoint(x: x * w, y: mid + height(x) * amp)
        }
        ctx.saveGState()
        ctx.move(to: CGPoint(x: 0, y: mid))
        ctx.addLines(between: main)
        ctx.addLine(to: CGPoint(x: w, y: mid))
        ctx.closePath()
        ctx.clip()
        let haze = [Self.cyan.withAlphaComponent(0.25), Self.electric.withAlphaComponent(0.10), Self.light.withAlphaComponent(0.30)]
        let membrane = CGGradient(colorsSpace: space, colors: haze.map(\.cgColor) as CFArray, locations: [0, 0.5, 1])!
        ctx.drawLinearGradient(membrane, start: CGPoint(x: 0, y: mid - amp), end: CGPoint(x: 0, y: mid + amp), options: [])
        ctx.restoreGState()

        // 6. sharp cyan contour with a short glow, a paler core on top
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 7, color: Self.cyan.withAlphaComponent(0.8).cgColor)
        ctx.addLines(between: main)
        ctx.setStrokeColor(Self.cyan.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1.4)
        ctx.strokePath()
        ctx.restoreGState()
        ctx.addLines(between: main)
        ctx.setStrokeColor(Self.ice.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(0.6)
        ctx.strokePath()

        // 7. center line edge to edge: bright up to the playhead, steel after it
        let head = w * max(0, min(1, progress))
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 4, color: Self.cyan.withAlphaComponent(0.9).cgColor)
        ctx.setFillColor(Self.light.withAlphaComponent(0.85).cgColor)
        ctx.fill(CGRect(x: 0, y: mid - 0.6, width: head, height: 1.2))
        ctx.restoreGState()
        ctx.setFillColor(Self.electric.withAlphaComponent(0.55).cgColor)
        ctx.fill(CGRect(x: head, y: mid - 0.5, width: w - head, height: 1))

        // 8. subtle light points on the crests and at the playhead
        for i in 2 ..< count - 1 {
            let y = main[i].y, h = (y - mid) / amp
            guard y > main[i - 1].y, y >= main[i + 1].y, h > 0.5 else { continue }
            radial(ctx, space, center: main[i], radius: 2 + 4 * h, Self.ice.withAlphaComponent(0.35 * h), Self.ice.withAlphaComponent(0))
        }
        if progress > 0 {
            radial(ctx, space, center: CGPoint(x: head, y: mid), radius: 5, Self.ice.withAlphaComponent(0.8), Self.ice.withAlphaComponent(0))
        }
    }

    /// Elliptic glow, `width` wide, as tall as the view allows.
    private func halo(_ ctx: CGContext, _ space: CGColorSpace, center: CGPoint, width: CGFloat, _ color: NSColor) {
        let radius = bounds.height * 0.5
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: width / radius, y: 1)
        radial(ctx, space, center: .zero, radius: radius, color, color.withAlphaComponent(0))
        ctx.restoreGState()
    }

    private func radial(_ ctx: CGContext, _ space: CGColorSpace, center: CGPoint, radius: CGFloat, _ inner: NSColor, _ outer: NSColor) {
        let gradient = CGGradient(colorsSpace: space, colors: [inner.cgColor, outer.cgColor] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
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
    let size = audioware ? NSSize(width: 420, height: 150) : NSSize(width: 380, height: 116)
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
    let wave = AudiowareWave()
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

        artwork.frame = audioware ? NSRect(x: 14, y: 90, width: 50, height: 50) : NSRect(x: 14, y: 14, width: 88, height: 88)
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
                field.frame = field === title ? NSRect(x: 76, y: 122, width: size.width - 90, height: 18)
                    : NSRect(x: 76, y: field === artist ? 106 : 90, width: size.width - 76 - 132, height: 16)
            }
            field.font = font
            field.lineBreakMode = .byTruncatingTail
            glass.addSubview(field)
        }
        progress.frame = NSRect(x: 114, y: 38, width: size.width - 128, height: 4)
        if audioware { // the wave sits under the text, edge to edge; its center line is the progress
            wave.frame = NSRect(x: 0, y: 0, width: size.width, height: 84)
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
            button.frame = audioware ? NSRect(x: size.width - 14 - 114 + CGFloat(i) * 40, y: 92, width: 34, height: 26)
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
                    if self.wave.levels != self.shownLevels || playing { self.wave.levels = self.shownLevels }
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
