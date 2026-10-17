import AppKit
import QuartzCore

// skyland: Hyprland `animation = borderangle, ..., loop`. With [decoration]
// border-rotate-ms > 0, skyland draws the focused window border itself (instead of
// JankyBorders, which only knows fixed diagonal gradients): a click-through window
// around the focused one, a conic accent -> highlight gradient masked by a rounded
// stroke. The rotation is a Core Animation animation, run by the render server at
// most 30 fps: skyland does no per-frame work. It only moves the window when the
// layout, the focus or the theme changes.
//
// [decoration]
// border-width = 2
// border-rotate-ms = 4000   # one turn of the gradient, 0 = static JankyBorders border

@MainActor private var borderWindow: NSWindow?
@MainActor private var borderGradient: CAGradientLayer?
@MainActor private var borderMask: CAShapeLayer?
@MainActor private var borderState = "" // what is on screen: frame, level, colors, settings
// While windows animate their window server frame is the animated one: no border until then
@MainActor private var borderPausedUntil = Date.distantPast
/// Window and frame the border was last drawn around: a frame that changes while the
/// mouse button is down is a window dragged or resized by the mouse.
@MainActor private var borderShown: (windowId: UInt32, frame: CGRect)? = nil
@MainActor private var borderDragMonitor: Any? = nil

/// Hide the border for `ms` (windows animating), then put it back.
@MainActor
func pauseAnimatedBorder(ms: Int) {
    guard config.decoration.borderRotateMs > 0 else { return }
    borderPausedUntil = max(borderPausedUntil, .now + Double(ms) / 1000)
    hideAnimatedBorder()
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms + 20)) { updateAnimatedBorder() }
}

/// The border back `ms` from now, whatever pause was asked before (a swipe ends).
@MainActor
func resumeAnimatedBorder(afterMs ms: Int) {
    borderPausedUntil = .now + Double(ms) / 1000
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms + 20)) { updateAnimatedBorder() }
}

@MainActor
func updateAnimatedBorder() {
    let deco = config.decoration
    guard deco.borderRotateMs > 0, deco.borderWidth > 0, TrayMenuModel.shared.isEnabled, !isOverviewOpen, Date.now >= borderPausedUntil,
          let window = focus.windowOrNil, !window.isHiddenInCorner, !isHiddenGroupTab(window), !isSmartBorderless(window), !overrides(window.windowId).noBorder,
          let (frame, level) = windowServerFrame(window.windowId)
    else { return hideAnimatedBorder() }
    // dragged with the mouse (title bar, edges): the border lags behind the window, it
    // comes back at mouse up (GlobalObserver refresh)
    if NSEvent.pressedMouseButtons & 1 != 0, let shown = borderShown, shown.windowId == window.windowId, shown.frame != frame {
        borderWindow?.orderOut(nil)
        borderState = ""
        return
    }
    borderShown = (window.windowId, frame)
    // the AX moved events of a title bar drag come ~500 ms late: the first drag events
    // compare the window server frame, until the border is hidden
    borderDragMonitor = borderDragMonitor ?? NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { _ in
        MainActor.assumeIsolated {
            guard borderWindow?.isVisible == true, let shown = borderShown,
                  let (frame, _) = windowServerFrame(shown.windowId), frame != shown.frame else { return }
            borderWindow?.orderOut(nil)
            borderState = ""
        }
    }
    let width = CGFloat(deco.borderWidth)
    let colors = themeBorderColors()
    let state = "\(frame) \(level) \(deco.borderWidth) \(deco.rounding) \(deco.borderRotateMs) \(colors.map(\.hashValue))"
    if state == borderState, borderWindow?.isVisible == true {
        borderWindow?.order(.above, relativeTo: Int(window.windowId)) // keep it right above its window
        return
    }
    borderState = state
    let panel = borderWindow ?? makeBorderWindow()
    // around the window, like JankyBorders: the stroke sits outside the window frame
    let outer = frame.insetBy(dx: -width, dy: -width)
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    panel.setFrame(NSRect(x: outer.minX, y: primaryHeight - outer.maxY, width: outer.width, height: outer.height), display: false)
    panel.level = NSWindow.Level(rawValue: level)
    let bounds = CGRect(origin: .zero, size: outer.size)
    let radius = CGFloat(deco.rounding) + width / 2
    borderMask?.frame = bounds
    borderMask?.lineWidth = width
    borderMask?.path = CGPath(roundedRect: bounds.insetBy(dx: width / 2, dy: width / 2), cornerWidth: radius, cornerHeight: radius, transform: nil)
    // a square as large as the diagonal, so the rotating gradient always covers the border
    let side = hypot(outer.width, outer.height)
    borderGradient?.bounds = CGRect(x: 0, y: 0, width: side, height: side)
    borderGradient?.position = CGPoint(x: bounds.midX, y: bounds.midY)
    borderGradient?.colors = colors
    CATransaction.commit()
    if let gradient = borderGradient, gradient.animation(forKey: "rotate") == nil || gradient.animation(forKey: "rotate")?.duration != Double(deco.borderRotateMs) / 1000 {
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = Double(deco.borderRotateMs) / 1000
        spin.repeatCount = .infinity
        spin.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
        gradient.add(spin, forKey: "rotate")
    }
    panel.order(.above, relativeTo: Int(window.windowId))
}

@MainActor
func hideAnimatedBorder() {
    borderWindow?.orderOut(nil)
    borderState = ""
}

@MainActor private func makeBorderWindow() -> NSWindow {
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.transient, .ignoresCycle]
    // layer-hosting view (our own root layer): AppKit leaves its mask and
    // sublayers alone and never redraws it
    let view = NSView()
    view.layer = CALayer()
    view.wantsLayer = true
    let mask = CAShapeLayer()
    mask.fillColor = nil
    mask.strokeColor = NSColor.black.cgColor
    let gradient = CAGradientLayer()
    gradient.type = .conic
    gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
    gradient.endPoint = CGPoint(x: 0.5, y: 0)
    // a smooth gradient as large as the window's diagonal: computed at a quarter of the
    // resolution (a few MB instead of tens); only the 2 px stroke of it shows, kept
    // sharp by the full-resolution mask
    gradient.contentsScale = 0.25
    view.layer?.addSublayer(gradient)
    view.layer?.mask = mask
    panel.contentView = view
    borderWindow = panel
    borderGradient = gradient
    borderMask = mask
    return panel
}

/// Frame (top-left origin, global) and level of a window, from the window server.
private func windowServerFrame(_ windowId: UInt32) -> (CGRect, Int)? {
    guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(windowId)) as? [[String: Any]])?.first,
          let bounds = info[kCGWindowBounds as String] as? NSDictionary,
          let frame = CGRect(dictionaryRepresentation: bounds), frame.width > 1, frame.height > 1
    else { return nil }
    return (frame, info[kCGWindowLayer as String] as? Int ?? 0)
}

/// accent -> highlight -> accent of the current theme (skylandThemeColors caches it).
@MainActor private func themeBorderColors() -> [CGColor] {
    let theme = skylandThemeColors()
    let accent = theme["accent"] ?? .controlAccentColor
    let highlight = theme["highlight"] ?? accent
    return [accent.cgColor, highlight.cgColor, accent.cgColor]
}
