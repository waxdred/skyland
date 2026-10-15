// skyland media widget: floating glass overlay with the now playing media of
// any app (Spotify, Brave/YouTube, Music...), draggable, on every workspace.
// Now playing comes from third_party/mediaremote-adapter (MediaRemote through
// the entitled /usr/bin/perl, needed since macOS 15.4). Colors follow the
// current skyland theme (~/.cache/skyland/theme.css). Toggled by bin/skyland-media.
// Audio-reactive bars (cava-like): system audio from ScreenCaptureKit (audio only,
// while something plays; uses the Screen Recording permission of the launching
// app), FFT with Accelerate, log-spaced bands with auto gain.
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
    let bars = Bars()
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
        glass.addSubview(progress)

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
        glass.addSubview(bars)
        // 30 fps: rise at once, fall slowly (cava gravity)
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let playing = self.state["playing"] as? Bool ?? false
                for i in self.shownLevels.indices {
                    let target = playing ? self.targetLevels[i] : 0
                    self.shownLevels[i] = max(target, self.shownLevels[i] * 0.85)
                }
                if self.bars.levels != self.shownLevels { self.bars.levels = self.shownLevels }
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
              let elapsed = state["elapsedTimeMicros"] as? Double else { progress.fraction = 0; return }
        var now = elapsed
        if state["playing"] as? Bool == true, let stamp = state["timestampEpochMicros"] as? Double {
            now += (Date().timeIntervalSince1970 * 1e6 - stamp) * (state["playbackRate"] as? Double ?? 1)
        }
        progress.fraction = CGFloat(now / duration)
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
