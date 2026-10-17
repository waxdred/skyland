import Foundation

/// What happens to a window, and so which animation of the tree plays.
public enum WindowEvent: Equatable, Sendable {
    /// a new window: Hyprland windowsIn, with fadeIn for its opacity
    case open
    /// skyland closes it (close command): windowsOut, with fadeOut
    case close
    /// its tile moved or resized, it was at `from`: windowsMove
    case move(from: AnimRect)
    /// its workspace is shown: workspacesIn
    case workspaceIn
    /// its workspace is switched away: workspacesOut
    case workspaceOut
    /// its scratchpad is shown: specialWorkspaceIn
    case specialIn
    /// its scratchpad is hidden: specialWorkspaceOut
    case specialOut

    public var node: AnimationNode {
        switch self {
            case .open: .windowsIn
            case .close: .windowsOut
            case .move: .windowsMove
            case .workspaceIn: .workspacesIn
            case .workspaceOut: .workspacesOut
            case .specialIn: .specialWorkspaceIn
            case .specialOut: .specialWorkspaceOut
        }
    }

    /// The window goes away: the animation starts where it is and ends out of sight.
    public var isLeaving: Bool {
        switch self {
            case .close, .workspaceOut, .specialOut: true
            case .open, .move, .workspaceIn, .specialIn: false
        }
    }

    /// A workspace or scratchpad switch, not a single window event.
    var isSwitch: Bool {
        switch self {
            case .workspaceIn, .workspaceOut, .specialIn, .specialOut: true
            case .open, .close, .move: false
        }
    }
}

/// The window and its screen, for one event.
public struct WindowContext: Equatable, Sendable {
    public var windowId: UInt32
    /// Coming in: the rect it ends at (its tile). Leaving: the rect it is at.
    public var rect: AnimRect
    /// Its monitor's rect
    public var monitor: AnimRect
    /// Workspace switches: +1 towards a higher workspace (the next one comes from the right,
    /// or from below), -1 towards a lower one
    public var direction: Double
    /// Its opacity at rest, 0...1 (active or inactive opacity)
    public var opacity: Double
    /// Its brightness at rest, -1...1 (dim-inactive is negative)
    public var brightness: Double
    /// Edges of its monitor shared with another monitor: a slide through one would draw the
    /// window on the other screen, so it fades instead (see `AnimRect.neighbourEdges`)
    public var neighbourEdges: Set<SlideEdge>

    public init(windowId: UInt32, rect: AnimRect, monitor: AnimRect, direction: Double = 1, opacity: Double = 1,
                brightness: Double = 0, neighbourEdges: Set<SlideEdge> = [])
    {
        self.windowId = windowId
        self.rect = rect
        self.monitor = monitor
        self.direction = direction < 0 ? -1 : 1
        self.opacity = opacity
        self.brightness = brightness
        self.neighbourEdges = neighbourEdges
    }
}

/// The window's state at one moment of a track.
public struct TrackSample: Equatable, Sendable {
    public var rect: AnimRect
    public var alpha: Double
    public var brightness: Double

    public init(rect: AnimRect, alpha: Double, brightness: Double) {
        self.rect = rect
        self.alpha = alpha
        self.brightness = brightness
    }
}

/// A window animation sampled over its duration, played by the Dock payload (osax/payload.m
/// `track`): every style, Hyprland's or skyland's, comes down to samples, so a new style
/// never needs a new payload.
public struct WindowTrack: Equatable, Sendable {
    public enum Mode: Int, Sendable {
        /// rects mapped onto the window's real frame through the last one, back to it at the end
        case enter = 0
        /// screen rects, back to the real frame at the end (the window was moved away)
        case leave = 1
        /// screen rects, stays at the last one (a window being closed)
        case hold = 2
    }

    /// What the track drives; the payload leaves the rest alone.
    public struct Channels: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let frame = Channels(rawValue: 1)
        public static let alpha = Channels(rawValue: 2)
        public static let brightness = Channels(rawValue: 4)
    }

    /// The payload's limit on samples per track
    public static let maxSamples = 240

    public var windowId: UInt32
    public var durationMs: Double
    public var mode: Mode
    public var channels: Channels
    /// Evenly spaced over the duration: the first at 0, the last at `durationMs`
    public var samples: [TrackSample]

    public init(windowId: UInt32, durationMs: Double, mode: Mode, channels: Channels, samples: [TrackSample]) {
        self.windowId = windowId
        self.durationMs = durationMs
        self.mode = mode
        self.channels = channels
        self.samples = samples
    }

    /// The state `ms` after the start, linear between samples like the payload.
    public func state(atMs ms: Double) -> TrackSample {
        guard samples.count > 1, durationMs > 0 else {
            return samples.first ?? TrackSample(rect: AnimRect(x: 0, y: 0, width: 0, height: 0), alpha: 0, brightness: 0)
        }
        let last = samples.count - 1
        let position = clamp(ms / durationMs, 0, 1) * Double(last)
        let index = min(last - 1, Int(position))
        let f = position - Double(index)
        let a = samples[index], b = samples[index + 1]
        return TrackSample(rect: AnimRect.lerp(a.rect, b.rect, f), alpha: mix(a.alpha, b.alpha, f),
                           brightness: mix(a.brightness, b.brightness, f))
    }

    /// The command for the payload: `track <wid> <ms> <mode> <channels> <n> <x y w h alpha brightness>...`
    public var payloadCommand: String {
        var parts = ["track", String(windowId), Self.number(durationMs, 1), String(mode.rawValue),
                     String(channels.rawValue), String(samples.count)]
        parts.reserveCapacity(parts.count + samples.count * 6)
        for sample in samples {
            parts.append(Self.number(sample.rect.x, 1))
            parts.append(Self.number(sample.rect.y, 1))
            parts.append(Self.number(sample.rect.width, 1))
            parts.append(Self.number(sample.rect.height, 1))
            parts.append(Self.number(clamp(sample.alpha, 0, 1), 3))
            parts.append(Self.number(clamp(sample.brightness, -1, 1), 3))
        }
        return parts.joined(separator: " ")
    }

    private static func number(_ value: Double, _ decimals: Int) -> String {
        let text = String(format: "%.\(decimals)f", value.isFinite ? value : 0)
        return text.hasPrefix("-") && Double(text) == 0 ? String(text.dropFirst()) : text // no "-0.0"
    }
}
