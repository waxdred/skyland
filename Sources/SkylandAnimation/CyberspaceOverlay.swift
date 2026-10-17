#if canImport(AppKit)
    import AppKit
    import QuartzCore

    /// The neon of the `cyberspace` style, drawn by skyland itself (the payload can only
    /// whiten or darken a window): a click-through panel around the window, right above it,
    /// with a frame in the theme accent tracing itself, a scan line sweeping the window and
    /// a faint cyberspace grid. Core Animation runs it; skyland does no work per frame.
    /// Coming in, the frame draws itself around where the window ends and the scan line goes
    /// down; leaving, the frame unwinds and the scan line goes up. Removed at the end.
    @MainActor
    public enum CyberspaceOverlay {
        /// - rect: the window's rect where it ends (coming in) or where it is (leaving),
        ///   top-left origin, global (AeroSpace / SkyLight coordinates)
        /// - level: the window's level, the overlay goes right above `windowId` in it
        public static func play(around rect: AnimRect, durationMs: Double, leaving: Bool, color: CGColor,
                                level: Int = 0, above windowId: UInt32? = nil)
        {
            guard rect.width >= 8, rect.height >= 8, durationMs > 0 else { return }
            let margin: CGFloat = 6
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let frame = NSRect(x: CGFloat(rect.x) - margin, y: primaryHeight - CGFloat(rect.maxY) - margin,
                               width: CGFloat(rect.width) + 2 * margin, height: CGFloat(rect.height) + 2 * margin)
            let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces]
            panel.level = NSWindow.Level(rawValue: level)
            // layer-hosting view: AppKit leaves its sublayers alone
            let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
            let root = CALayer()
            view.layer = root
            view.wantsLayer = true
            panel.contentView = view

            let bounds = CGRect(origin: .zero, size: frame.size)
            let window = bounds.insetBy(dx: margin, dy: margin)
            let duration = durationMs / 1000
            root.addSublayer(grid(in: window, color: color, duration: duration))
            root.addSublayer(outline(around: window, color: color, duration: duration, leaving: leaving))
            root.addSublayer(scanLine(across: window, color: color, duration: duration, leaving: leaving))
            // the whole overlay: in quickly, held, out over the last 30%
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1, 0]
            fade.keyTimes = [0, 0.1, 0.7, 1]
            fade.duration = duration
            root.opacity = 0 // where it ends, once the animation is removed
            root.add(fade, forKey: "fade")

            if let windowId {
                panel.order(.above, relativeTo: Int(windowId))
            } else {
                panel.orderFrontRegardless()
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(Int(durationMs) + 60))
                panel.orderOut(nil)
            }
        }

        /// The frame tracing itself (strokeEnd 0 -> 1 over the first 35%), or unwinding.
        private static func outline(around window: CGRect, color: CGColor, duration: Double, leaving: Bool) -> CAShapeLayer {
            let layer = CAShapeLayer()
            let radius = min(10, window.width / 2, window.height / 2)
            layer.path = CGPath(roundedRect: window.insetBy(dx: -1, dy: -1), cornerWidth: radius, cornerHeight: radius, transform: nil)
            layer.fillColor = nil
            layer.strokeColor = color
            layer.lineWidth = 2.5
            layer.shadowColor = color
            layer.shadowOpacity = 1
            layer.shadowRadius = 7
            layer.shadowOffset = .zero
            let trace = CABasicAnimation(keyPath: "strokeEnd")
            trace.fromValue = leaving ? 1 : 0
            trace.toValue = leaving ? 0 : 1
            trace.duration = leaving ? duration : duration * 0.35
            trace.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.strokeEnd = leaving ? 0 : 1
            layer.add(trace, forKey: "trace")
            return layer
        }

        /// A bright bar across the window, down from the top (or up from the bottom when leaving).
        private static func scanLine(across window: CGRect, color: CGColor, duration: Double, leaving: Bool) -> CAGradientLayer {
            let layer = CAGradientLayer()
            let clear = color.copy(alpha: 0) ?? color
            layer.colors = [clear, color, clear]
            layer.startPoint = CGPoint(x: 0.5, y: 0)
            layer.endPoint = CGPoint(x: 0.5, y: 1)
            layer.bounds = CGRect(x: 0, y: 0, width: window.width, height: 28)
            layer.opacity = 0.65
            // layer coordinates: y up, the top of the window is maxY
            let top = CGPoint(x: window.midX, y: window.maxY), bottom = CGPoint(x: window.midX, y: window.minY)
            layer.position = leaving ? top : bottom
            let sweep = CABasicAnimation(keyPath: "position")
            sweep.fromValue = NSValue(point: leaving ? bottom : top)
            sweep.toValue = NSValue(point: leaving ? top : bottom)
            sweep.beginTime = CACurrentMediaTime() + (leaving ? 0 : duration * 0.15)
            sweep.duration = duration * 0.6
            sweep.fillMode = .backwards
            sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(sweep, forKey: "sweep")
            return layer
        }

        /// A faint grid over the window, fading out.
        private static func grid(in window: CGRect, color: CGColor, duration: Double) -> CAShapeLayer {
            let layer = CAShapeLayer()
            let path = CGMutablePath()
            var x = window.minX + 48
            while x < window.maxX {
                path.move(to: CGPoint(x: x, y: window.minY))
                path.addLine(to: CGPoint(x: x, y: window.maxY))
                x += 48
            }
            var y = window.minY + 48
            while y < window.maxY {
                path.move(to: CGPoint(x: window.minX, y: y))
                path.addLine(to: CGPoint(x: window.maxX, y: y))
                y += 48
            }
            layer.path = path
            layer.fillColor = nil
            layer.strokeColor = color
            layer.lineWidth = 1
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.2
            fade.toValue = 0
            fade.duration = duration
            layer.opacity = 0
            layer.add(fade, forKey: "fade")
            return layer
        }
    }
#endif
