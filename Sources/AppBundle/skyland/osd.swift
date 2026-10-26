import AppKit
import AudioToolbox
import CoreAudio

// skyland: `osd = 'skyland'` replaces macOS' volume and brightness popups (OSD) by
// skyland's: one popup for both, skyland's icon on its left, in the ui-style and the
// theme, where you drag it (remembered). The media keys are taken in an event tap and applied here, so macOS never shows
// its own: output volume and mute (CoreAudio), built-in display brightness
// (DisplayServices, private). What skyland cannot set (an output without volume, an
// external display, the keyboard backlight) goes on to macOS as before.

// NX_KEYTYPE_* of the media keys (IOKit/hidsystem/ev_keymap.h)
private let soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
private let osdKeys: Set<Int> = [soundUp, soundDown, brightnessUp, brightnessDown, mute]

nonisolated(unsafe) private var osdTap: CFMachPort? = nil // set once at startup
/// keys whose press skyland took: their release is taken too
nonisolated(unsafe) private var osdHeld: Set<Int> = []

@MainActor
func startOsdTap() {
    osdTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                               eventsOfInterest: 1 << 14, callback: osdCallback, userInfo: nil) // NSSystemDefined
    guard let osdTap = unsafe osdTap else { return }
    addToEventTapThread(osdTap)
}

/// On the event tap thread: only the media keys above wait for the main thread.
private func osdCallback(_: CGEventTapProxy, type: CGEventType, event: CGEvent, _: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let osdTap = unsafe osdTap { CGEvent.tapEnable(tap: osdTap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return Unmanaged.passUnretained(event) }
    let key = (ns.data1 & 0xFFFF_0000) >> 16, down = (ns.data1 & 0xFF00) >> 8 == 0xA
    guard osdKeys.contains(key) else { return Unmanaged.passUnretained(event) }
    if !down { return unsafe osdHeld.remove(key) != nil ? nil : Unmanaged.passUnretained(event) }
    let flags = ns.modifierFlags
    let taken = onMainForTap { handleOsdKey(key, fine: flags.contains(.option) && flags.contains(.shift)) }
    if taken { unsafe osdHeld.insert(key) }
    return taken ? nil : Unmanaged.passUnretained(event)
}

/// Applies a media key and shows skyland's popup; false: macOS keeps it (and its own popup).
@MainActor
private func handleOsdKey(_ key: Int, fine: Bool) -> Bool {
    guard config.osd == "skyland" else { return false }
    let step: Float = fine ? 1 / 64 : 1 / 16 // option-shift: quarter steps, as macOS
    switch key {
        case soundUp, soundDown, mute:
            guard let device = Volume.output(), var level = Volume.level(device) else { return false }
            var muted = Volume.muted(device)
            if key == mute {
                muted.toggle()
            } else {
                level = max(0, min(1, level + (key == soundUp ? step : -step)))
                guard Volume.setLevel(device, level) else { return false }
                muted = level == 0
            }
            Volume.setMuted(device, muted)
            showOsd(icon: muted ? "speaker.slash.fill" : level < 0.34 ? "speaker.wave.1.fill" : level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill",
                    value: muted ? 0 : level, off: muted)
        default:
            guard let display = Brightness.builtIn(), var level = Brightness.level(display) else { return false }
            level = max(0, min(1, level + (key == brightnessUp ? step : -step)))
            guard Brightness.setLevel(display, level) else { return false }
            showOsd(icon: "sun.max.fill", value: level, off: false)
    }
    return true
}

// MARK: volume (CoreAudio)

private enum Volume {
    static func output() -> AudioObjectID? {
        var device = AudioObjectID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    /// the main volume, 0...1; nil: the device has none (HDMI, some USB): macOS handles it
    static func level(_ device: AudioObjectID) -> Float? {
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var value: Float32 = 0, size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectHasProperty(device, &address), AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func setLevel(_ device: AudioObjectID, _ level: Float) -> Bool {
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var value = Float32(level)
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    static func muted(_ device: AudioObjectID) -> Bool {
        var address = address(kAudioDevicePropertyMute)
        var value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    static func setMuted(_ device: AudioObjectID, _ muted: Bool) {
        var address = address(kAudioDevicePropertyMute)
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}

// MARK: brightness (DisplayServices, private: what macOS' own keys call)

private enum Brightness {
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32
    nonisolated(unsafe) private static let framework = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let get = dlsym(framework, "DisplayServicesGetBrightness").map { unsafe unsafeBitCast($0, to: Get.self) }
    private static let set = dlsym(framework, "DisplayServicesSetBrightness").map { unsafe unsafeBitCast($0, to: Set.self) }

    static func builtIn() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16), count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    static func level(_ display: CGDirectDisplayID) -> Float? {
        var value: Float = 0
        guard let get, unsafe get(display, &value) == 0 else { return nil }
        return value
    }

    static func setLevel(_ display: CGDirectDisplayID, _ level: Float) -> Bool {
        guard let set else { return false }
        return set(display, level) == 0
    }
}

// MARK: the popup

@MainActor private var osdPanel: (panel: NSPanel, view: OsdView, hide: DispatchWorkItem?)? = nil

@MainActor
private func showOsd(icon: String, value: Float, off: Bool) {
    let size = NSSize(width: 280, height: 52)
    // hidden: made again, in the ui-style (metal, glass, glyph) and the theme of now
    if let old = osdPanel, !old.panel.isVisible { old.panel.close(); osdPanel = nil }
    var entry = osdPanel ?? {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        var origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.minY + 120)
        if let saved = UserDefaults.standard.string(forKey: "osdOrigin").map(NSPointFromString),
           NSScreen.screens.contains(where: { $0.frame.contains(saved) }) {
            origin = saved
        }
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true // drag it where it goes: remembered
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.appearance = isGlyphStyle ? themeAppearance() : NSAppearance(named: .darkAqua)
        let root = makePanelRoot(radius: 16, for: panel)
        root.frame = NSRect(origin: .zero, size: size)
        let view = OsdView(frame: root.bounds)
        root.addSubview(view)
        panel.contentView = root
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak panel] _ in // weak: a hidden panel is made again
            MainActor.assumeIsolated { panel.map { UserDefaults.standard.set(NSStringFromPoint($0.frame.origin), forKey: "osdOrigin") } }
        }
        return (panel, view, nil)
    }()
    entry.view.icon = icon
    entry.view.value = value
    entry.view.off = off
    entry.view.needsDisplay = true
    entry.panel.alphaValue = 1
    entry.panel.orderFrontRegardless()
    entry.hide?.cancel()
    let panel = entry.panel
    let hide = DispatchWorkItem {
        // under the mouse (being moved): stays
        if panel.frame.contains(NSEvent.mouseLocation) { return showOsdAgainLater() }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 }) { MainActor.assumeIsolated { panel.orderOut(nil) } }
    }
    entry.hide = hide
    osdPanel = entry
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: hide)
}

@MainActor
private func showOsdAgainLater() {
    guard let entry = osdPanel else { return }
    showOsd(icon: entry.view.icon, value: entry.view.value, off: entry.view.off)
}

/// skyland's icon, the key's symbol, 16 steps and the percent: glyph draws the steps as dots (off: the red one).
private final class OsdView: NSView {
    var icon = "speaker.wave.2.fill", value: Float = 0, off = false

    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }

    override func draw(_ dirtyRect: NSRect) {
        let theme = MainActor.assumeIsolated { skylandThemeColors() }
        let glyph = MainActor.assumeIsolated { isGlyphStyle }
        let fg = glyph ? theme["fg"] ?? .labelColor : .labelColor
        let faint = glyph ? theme["fg_faint"] ?? .tertiaryLabelColor : NSColor.white.withAlphaComponent(0.18)
        let accent = glyph ? fg : theme["accent"] ?? .controlAccentColor
        let red = theme["highlight"] ?? .systemRed

        let symbol = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .semibold).applying(.init(paletteColors: [off && glyph ? red : fg])))
        NSApp.applicationIconImage?.draw(in: NSRect(x: 12, y: (bounds.height - 30) / 2, width: 30, height: 30))
        symbol?.draw(in: NSRect(x: 52, y: (bounds.height - 20) / 2, width: 24, height: 20))

        let steps = 16, filled = Int((value * Float(steps)).rounded())
        let barX: CGFloat = 88, barWidth = bounds.width - barX - 58
        if glyph { // a row of dots, as the Glyph lights
            let pitch = barWidth / CGFloat(steps), dot: CGFloat = 6
            for i in 0 ..< steps {
                (i < filled ? accent : faint).setFill()
                NSBezierPath(ovalIn: NSRect(x: barX + CGFloat(i) * pitch + (pitch - dot) / 2, y: bounds.midY - dot / 2, width: dot, height: dot)).fill()
            }
        } else {
            let track = NSRect(x: barX, y: bounds.midY - 3, width: barWidth, height: 6)
            faint.setFill()
            NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
            accent.setFill()
            NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: track.width * CGFloat(filled) / CGFloat(steps), height: track.height), xRadius: 3, yRadius: 3).fill()
        }
        let percent = off ? "OFF" : "\(Int((value * 100).rounded()))"
        let font = glyph ? PanelFont.dots(20) : PanelFont.label(13, weight: .semibold)
        let text = NSAttributedString(string: percent, attributes: [.font: font, .foregroundColor: off && glyph ? red : fg])
        let width = text.size().width
        text.draw(at: NSPoint(x: bounds.width - 16 - width, y: (bounds.height - text.size().height) / 2))
    }
}
