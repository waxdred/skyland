import Foundation

/// Turns a window event into the track the payload plays, with the animations of `settings`.
///
///     let animator = WindowAnimator(settings: AnimationPreset.named("cyberspace")!.settings)
///     if let track = animator.track(for: .open, WindowContext(windowId: id, rect: tile, monitor: screen)) {
///         skylandSa(track.payloadCommand)
///     }
public struct WindowAnimator: Equatable, Sendable {
    public var settings: AnimationSettings
    /// Samples per second of animation; the payload interpolates between them at the
    /// display rate (cyberspace takes at least 90, for its glitches)
    public var samplesPerSecond: Double

    public init(settings: AnimationSettings = AnimationSettings(), samplesPerSecond: Double = 60) {
        self.settings = settings
        self.samplesPerSecond = samplesPerSecond
    }

    /// The track of `event`, nil when its animation is off or there is nothing to animate.
    ///
    /// - open / close: the windowsIn / windowsOut style moves the window, fadeIn / fadeOut
    ///   fade it, like Hyprland
    /// - move: from the previous rect, windowsMove (no style)
    /// - workspace and scratchpad switches: the workspacesIn / Out and specialWorkspaceIn /
    ///   Out style moves and fades the window
    public func track(for event: WindowEvent, _ context: WindowContext) -> WindowTrack? {
        guard settings.enabled, context.rect.width >= 1, context.rect.height >= 1 else { return nil }
        let motion = settings.resolve(event.node)
        if case .move(let from) = event {
            guard motion.enabled, from != context.rect else { return nil }
            return sampled(context.windowId, mode: .enter, channels: .frame, motion: Timing(motion), fade: nil) { progress, _ in
                TrackSample(rect: AnimRect.lerp(from, context.rect, progress).atLeast(1), alpha: context.opacity,
                            brightness: context.brightness)
            }
        }
        let style = effectiveStyle(event, motion.style, context)
        if motion.enabled && style == .cyberspace { return cyberspaceTrack(event, context, motion) }

        let (outside, slideFades) = outsideRect(style, event, context)
        let motionTiming = motion.enabled && outside != context.rect ? Timing(motion) : nil
        // the opacity: with the motion when the style fades (or the slide crosses into another
        // screen), else fadeIn / fadeOut for a window opening / closing
        let fadeNode: AnimationNode? = switch event {
            case .open: .fadeIn
            case .close: .fadeOut
            default: nil
        }
        let fadeTiming: Timing?
        if motion.enabled && (style.fades || slideFades) {
            fadeTiming = Timing(motion)
        } else if let fadeNode, settings.resolve(fadeNode).enabled {
            fadeTiming = Timing(settings.resolve(fadeNode))
        } else {
            fadeTiming = nil
        }
        var channels: WindowTrack.Channels = []
        if motionTiming != nil { channels.insert(.frame) }
        if fadeTiming != nil { channels.insert(.alpha) }
        guard !channels.isEmpty else { return nil }

        let leaving = event.isLeaving
        let (fromRect, toRect) = leaving ? (context.rect, outside) : (outside, context.rect)
        let (fromAlpha, toAlpha) = leaving ? (context.opacity, 0.0) : (0.0, context.opacity)
        return sampled(context.windowId, mode: Self.mode(event), channels: channels, motion: motionTiming, fade: fadeTiming) { progress, fade in
            TrackSample(rect: AnimRect.lerp(fromRect, toRect, progress).atLeast(1),
                        alpha: clamp(mix(fromAlpha, toAlpha, fade), 0, 1), brightness: context.brightness)
        }
    }

    /// The style `event` plays: its animation's, else Hyprland's defaults: slide for
    /// workspaces, slidevert for scratchpads, popin (80%, skyland's) for windows. A full slide
    /// of a switch through a screen edge shared with another screen becomes slidefade 20%:
    /// the windows would be drawn on the other screen.
    public func effectiveStyle(_ event: WindowEvent, _ style: AnimationStyle?, _ context: WindowContext) -> AnimationStyle {
        let chosen = style ?? Self.defaultStyle(event)
        guard event.isSwitch else { return chosen }
        let vertical: Bool
        let percent: Double
        switch chosen {
            case .slide(.none): (vertical, percent) = (false, 100)
            case .slideVert: (vertical, percent) = (true, 100)
            case .slideFade(let p, let v): (vertical, percent) = (v, p)
            default: return chosen
        }
        guard percent > 20, context.neighbourEdges.contains(crossedEdge(event, vertical: vertical, context)) else { return chosen }
        return .slideFade(percent: 20, vertical: vertical)
    }

    public static func defaultStyle(_ event: WindowEvent) -> AnimationStyle {
        switch event {
            case .open, .close, .move: .popin(percent: 80)
            case .workspaceIn, .workspaceOut: .slide(nil)
            case .specialIn, .specialOut: .slideVert
        }
    }

    // MARK: geometry

    /// The way a switch moves windows: +1 right / down, -1 left / up. A workspace comes
    /// from the `direction` side and the old one leaves to the other; a scratchpad comes
    /// from its side and goes back to it.
    func towardSign(_ event: WindowEvent, _ context: WindowContext) -> Double {
        switch event {
            case .workspaceOut, .close: -context.direction
            default: context.direction
        }
    }

    /// The monitor edge a switch slides windows through.
    func crossedEdge(_ event: WindowEvent, vertical: Bool, _ context: WindowContext) -> SlideEdge {
        let toward = towardSign(event, context)
        if vertical { return toward > 0 ? .bottom : .top }
        return toward > 0 ? .right : .left
    }

    /// Where `style` puts the window out of sight: where it comes from, or where it goes.
    /// The flag: the slide goes through an edge shared with another screen, the window fades
    /// on the way so that it is not seen there.
    func outsideRect(_ style: AnimationStyle, _ event: WindowEvent, _ context: WindowContext) -> (AnimRect, Bool) {
        let r = context.rect, m = context.monitor
        let toward = towardSign(event, context)
        switch style {
            case .popin(let percent):
                return (r.scaled(percent / 100, percent / 100).atLeast(1), false)
            case .gnomed:
                return (AnimRect(x: r.x, y: r.midY - 0.5, width: r.width, height: 1), false)
            case .fade, .cyberspace, .once, .loop:
                return (r, false)
            case .slideFade(let percent, let vertical):
                let distance = toward * percent / 100 * (vertical ? m.height : m.width)
                return (vertical ? r.offsetBy(dx: 0, dy: distance) : r.offsetBy(dx: distance, dy: 0), false)
            case .slideVert where event.isSwitch:
                return (r.offsetBy(dx: 0, dy: toward * m.height), false)
            case .slide(.none) where event.isSwitch:
                return (r.offsetBy(dx: toward * m.width, dy: 0), false)
            case .slide(let given):
                let edge = given ?? closestEdge(of: r, in: m, avoiding: context.neighbourEdges, among: SlideEdge.allCases)
                return (beyond(edge, r, m), context.neighbourEdges.contains(edge))
            case .slideVert:
                let edge = closestEdge(of: r, in: m, avoiding: context.neighbourEdges, among: [.top, .bottom])
                return (beyond(edge, r, m), context.neighbourEdges.contains(edge))
        }
    }

    /// The edge of `m` closest to the center of `r`, preferring edges without a neighbouring screen.
    func closestEdge(of r: AnimRect, in m: AnimRect, avoiding neighbours: Set<SlideEdge>, among edges: [SlideEdge]) -> SlideEdge {
        func distance(_ edge: SlideEdge) -> Double {
            switch edge {
                case .left: r.midX - m.x
                case .right: m.maxX - r.midX
                case .top: r.midY - m.y
                case .bottom: m.maxY - r.midY
            }
        }
        // stable on ties: the order of `edges`
        let sorted = edges.enumerated().sorted { a, b in
            distance(a.element) == distance(b.element) ? a.offset < b.offset : distance(a.element) < distance(b.element)
        }.map(\.element)
        return sorted.first { !neighbours.contains($0) } ?? sorted[0]
    }

    /// `r` moved just out of `m` through `edge`
    func beyond(_ edge: SlideEdge, _ r: AnimRect, _ m: AnimRect) -> AnimRect {
        switch edge {
            case .left: AnimRect(x: m.x - r.width, y: r.y, width: r.width, height: r.height)
            case .right: AnimRect(x: m.maxX, y: r.y, width: r.width, height: r.height)
            case .top: AnimRect(x: r.x, y: m.y - r.height, width: r.width, height: r.height)
            case .bottom: AnimRect(x: r.x, y: m.maxY, width: r.width, height: r.height)
        }
    }

    // MARK: sampling

    struct Timing {
        var ms: Double
        var curve: CubicBezier

        init(_ spec: AnimationSpec) {
            ms = max(1, spec.durationMs)
            curve = spec.curve
        }

        func progress(atMs t: Double) -> Double { curve.ease(t / ms) }
    }

    static func mode(_ event: WindowEvent) -> WindowTrack.Mode {
        switch event {
            case .close: .hold
            case .workspaceOut, .specialOut: .leave
            case .open, .move, .workspaceIn, .specialIn: .enter
        }
    }

    static func sampleCount(_ durationMs: Double, _ rate: Double) -> Int {
        min(WindowTrack.maxSamples, max(2, Int((durationMs / 1000 * rate).rounded(.up)) + 1))
    }

    /// The track over the longer of the two timings: `state(motion progress, fade progress)`
    /// at each sample, a progress being 1 once its timing is over (or when there is none).
    func sampled(_ windowId: UInt32, mode: WindowTrack.Mode, channels: WindowTrack.Channels, motion: Timing?, fade: Timing?,
                 _ state: (Double, Double) -> TrackSample) -> WindowTrack
    {
        let duration = max(motion?.ms ?? 0, fade?.ms ?? 0, 1)
        let count = Self.sampleCount(duration, samplesPerSecond)
        var samples: [TrackSample] = []
        samples.reserveCapacity(count)
        for index in 0 ..< count {
            let t = duration * Double(index) / Double(count - 1)
            samples.append(state(motion?.progress(atMs: t) ?? 1, fade?.progress(atMs: t) ?? 1))
        }
        return WindowTrack(windowId: windowId, durationMs: duration, mode: mode, channels: channels, samples: samples)
    }
}
