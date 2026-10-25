import AppKit
import Common

// skyland: a panel while skyland starts (finds the windows, sends them back to their
// workspaces, lays them out): the icon, "starting", the windows found so far and a running
// line. It goes once the startup layout is done, scaled down as it fades; after 10 s anyway.
// [decoration] startup-hud = false turns it off.

@MainActor private var startupHud: NSPanel? = nil
@MainActor private var startupHudTimer: Timer? = nil
@MainActor private var startupHudShown = Date.distantPast

@MainActor
func showStartupHud() {
    guard config.decoration.startupHud, startupHud == nil, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
    let size = NSSize(width: 280, height: 104)
    let frame = screen.visibleFrame
    let panel = NSPanel(contentRect: NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = .statusBar
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.isReleasedWhenClosed = false
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    panel.appearance = isGlyphStyle ? themeAppearance() : NSAppearance(named: .darkAqua)
    let root = makePanelRoot(radius: 22, for: panel) // ui-style
    root.frame = NSRect(origin: .zero, size: size)
    root.wantsLayer = true
    let theme = skylandThemeColors()
    let accent = theme["accent"] ?? .systemBlue

    let icon = NSImageView(frame: NSRect(x: 20, y: 34, width: 48, height: 48))
    icon.image = NSApp.applicationIconImage
    icon.imageScaling = .scaleProportionallyUpOrDown
    root.addSubview(icon)
    // glyph: the name in dots, the status in Space Mono caps, the runner the one live (red) thing
    let title = NSTextField(labelWithString: PanelFont.caps("skyland"))
    title.font = isGlyphStyle ? PanelFont.dots(22) : .systemFont(ofSize: 18, weight: .bold)
    title.textColor = isGlyphStyle ? theme["fg"] ?? accent : accent
    title.frame = NSRect(x: 82, y: 56, width: 180, height: 24)
    root.addSubview(title)
    let status = NSTextField(labelWithString: PanelFont.caps("starting…"))
    status.font = PanelFont.label(isGlyphStyle ? 11 : 12)
    status.textColor = isGlyphStyle ? theme["fg_dim"] ?? .secondaryLabelColor : .secondaryLabelColor
    status.frame = NSRect(x: 82, y: 36, width: 180, height: 18)
    root.addSubview(status)

    // a running line: a short bright segment going along a faint track
    let track = CALayer()
    track.frame = CGRect(x: 20, y: 18, width: size.width - 40, height: 3)
    track.cornerRadius = 1.5
    track.backgroundColor = accent.withAlphaComponent(0.18).cgColor
    track.masksToBounds = true
    let runner = CAGradientLayer()
    runner.frame = CGRect(x: 0, y: 0, width: 70, height: 3)
    runner.startPoint = CGPoint(x: 0, y: 0.5)
    runner.endPoint = CGPoint(x: 1, y: 0.5)
    let live = isGlyphStyle ? theme["highlight"] ?? accent : accent
    runner.colors = [live.withAlphaComponent(0).cgColor, live.cgColor, live.withAlphaComponent(0).cgColor]
    track.addSublayer(runner)
    root.layer?.addSublayer(track)
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        let run = CABasicAnimation(keyPath: "position.x")
        run.fromValue = -35
        run.toValue = track.bounds.width + 35
        run.duration = 1.1
        run.repeatCount = .infinity
        run.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        runner.add(run, forKey: "run")
    }

    panel.contentView = root
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
    startupHud = panel
    startupHudShown = .now
    let started = Date.now
    let timer = Timer(timeInterval: 0.2, repeats: true) { _ in
        MainActor.assumeIsolated {
            let count = MacWindow.allWindowsMap.count
            status.stringValue = count == 0 ? "starting…" : "\(count) window\(count == 1 ? "" : "s")"
            if Date.now.timeIntervalSince(started) > 10 {
                FileHandle.standardError.write(Data("skyland: startup took more than 10 s, startup HUD hidden\n".utf8))
                hideStartupHud()
            }
        }
    }
    RunLoop.main.add(timer, forMode: .common)
    startupHudTimer = timer
}

/// Gone with a short scale down and fade (at once with Reduce Motion), after the windows
/// had a moment to settle.
@MainActor
func hideStartupHud() {
    guard let panel = startupHud else { return }
    startupHud = nil
    startupHudTimer?.invalidate()
    startupHudTimer = nil
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        panel.orderOut(nil)
        return
    }
    // shown for 2 s at least: a fast start flashed it for a moment, nothing could be read
    let wait = max(0.3, 2 - Date.now.timeIntervalSince(startupHudShown))
    DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
        if let layer = panel.contentView?.layer {
            let bounds = layer.bounds
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            let shrink = CABasicAnimation(keyPath: "transform.scale")
            shrink.fromValue = 1
            shrink.toValue = 0.9
            shrink.duration = 0.25
            shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
            layer.transform = CATransform3DMakeScale(0.9, 0.9, 1)
            layer.add(shrink, forKey: "shrink")
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }
}
