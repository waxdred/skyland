import Foundation

// skyland's `cyberspace` style, after the floating island over a cyberspace grid of the app
// icon. Coming in, the window "rezzes": it ignites as a white-hot scan line across its
// middle, unfolds to its full height through glitches (one-frame horizontal tears, opacity
// dips, flashes) and settles while the glow cools down. Leaving, it "derezzes": a burst of
// glitches heating up, a collapse to a glowing line, the line shrinking to a dot that
// fades. On a workspace switch the windows streak a little along the switch, and the new
// ones wait for the old ones to derez.
// Everything is the payload's: frame, opacity and brightness (-1 black .. 1 white). The
// neon frame in the theme accent around it is CyberspaceOverlay's (skyland's own window).
// The glitches are random but the same for a window and an event (seeded by both).

extension WindowAnimator {
    func cyberspaceTrack(_ event: WindowEvent, _ context: WindowContext, _ motion: AnimationSpec) -> WindowTrack {
        let duration = max(1, motion.durationMs)
        let count = Self.sampleCount(duration, max(samplesPerSecond, 90))
        var random = SplitMix64(seed: UInt64(context.windowId) &* 0x9E37_79B9_7F4A_7C15 ^ Self.salt(event))
        let samples = event.isLeaving
            ? derez(event, context, motion.curve, count: count, &random)
            : rez(event, context, motion.curve, count: count, &random)
        return WindowTrack(windowId: context.windowId, durationMs: duration, mode: Self.mode(event),
                           channels: [.frame, .alpha, .brightness], samples: samples)
    }

    /// Coming in: ignite (20%), unfold (45%), settle (35%), after a wait on a workspace switch.
    private func rez(_ event: WindowEvent, _ c: WindowContext, _ curve: CubicBezier, count: Int,
                     _ random: inout SplitMix64) -> [TrackSample]
    {
        let target = c.rect, width = target.width, height = target.height
        let line = Self.cyberLine(target)
        let wait = event == .workspaceIn ? 0.15 : 0 // the old workspace derezzes first
        let streak = event.isSwitch ? towardSign(event, c) * 0.06 * c.monitor.width : 0
        let last = count - 1
        func at(_ v: Double) -> Double { wait + v * (1 - wait) } // track time of a moment of the rez
        var glitches = Self.glitches(3, in: at(0.22) ... at(0.62), strength: 0.05, last: last, &random)
        glitches.merge(Self.glitches(2, in: at(0.68) ... 0.95, strength: 0.015, last: last, &random)) { a, _ in a }
        var samples: [TrackSample] = []
        samples.reserveCapacity(count)
        for index in 0 ... last {
            let u = Double(index) / Double(last)
            let v = clamp((u - wait) / (1 - wait), 0, 1)
            let w: Double, h: Double
            var alpha: Double, brightness: Double
            if u < wait {
                (w, h) = (0.08 * width, line)
                alpha = 0
                brightness = 0.9
            } else if v < 0.2 {
                let a = Self.easeOut(v / 0.2)
                (w, h) = (mix(0.08, 1, a) * width, line)
                alpha = c.opacity * min(1, a * 1.6)
                brightness = mix(c.brightness, 0.9, min(1, a * 2))
            } else if v < 0.65 {
                let k = (v - 0.2) / 0.45
                (w, h) = (width, mix(line, height, curve.ease(k)))
                alpha = c.opacity
                brightness = mix(0.9, 0.25, k)
            } else {
                (w, h) = (width, height)
                alpha = c.opacity
                brightness = mix(0.25, c.brightness, Self.easeOut((v - 0.65) / 0.35))
            }
            var dx = streak * (1 - v) * (1 - v)
            if let glitch = glitches[index] {
                dx += glitch.dx * width
                alpha *= glitch.alpha
                brightness += glitch.flash
            }
            let rect = AnimRect(x: target.midX - w / 2 + dx, y: target.midY - h / 2, width: w, height: h).atLeast(1)
            samples.append(TrackSample(rect: rect, alpha: clamp(alpha, 0, 1), brightness: clamp(brightness, -1, 1)))
        }
        samples[last] = TrackSample(rect: target, alpha: c.opacity, brightness: c.brightness)
        return samples
    }

    /// Leaving: glitch burst (25%), collapse to a line (40%), shrink to a dot and fade (35%).
    private func derez(_ event: WindowEvent, _ c: WindowContext, _ curve: CubicBezier, count: Int,
                       _ random: inout SplitMix64) -> [TrackSample]
    {
        let start = c.rect, width = start.width, height = start.height
        let line = Self.cyberLine(start)
        let drift = event.isSwitch ? towardSign(event, c) * 0.06 * c.monitor.width : 0
        let last = count - 1
        let glitches = Self.glitches(3, in: 0.03 ... 0.25, strength: 0.06, last: last, &random)
        var samples: [TrackSample] = []
        samples.reserveCapacity(count)
        for index in 0 ... last {
            let u = Double(index) / Double(last)
            let w: Double, h: Double
            var alpha: Double, brightness: Double
            if u < 0.25 {
                (w, h) = (width, height)
                alpha = c.opacity
                brightness = mix(c.brightness, 0.5, u / 0.25)
            } else if u < 0.65 {
                let k = (u - 0.25) / 0.4
                (w, h) = (width, mix(height, line, curve.ease(k)))
                alpha = c.opacity
                brightness = mix(0.5, 0.9, k)
            } else {
                let k = (u - 0.65) / 0.35
                (w, h) = (mix(width, 2, k * k), line)
                alpha = c.opacity * pow(1 - k, 1.5)
                brightness = 0.9
            }
            var dx = drift * u * u
            if let glitch = glitches[index] {
                dx += glitch.dx * width
                alpha *= glitch.alpha
                brightness += glitch.flash
            }
            let rect = AnimRect(x: start.midX - w / 2 + dx, y: start.midY - h / 2, width: w, height: h).atLeast(1)
            samples.append(TrackSample(rect: rect, alpha: clamp(alpha, 0, 1), brightness: clamp(brightness, -1, 1)))
        }
        // gone: invisible, and back to its brightness for when it shows again
        samples[last] = TrackSample(rect: AnimRect(x: start.midX - 1 + drift, y: start.midY - line / 2, width: 2, height: line),
                                    alpha: 0, brightness: c.brightness)
        return samples
    }

    struct Glitch: Equatable {
        /// horizontal tear, in window widths
        var dx: Double
        /// opacity factor
        var alpha: Double
        /// added brightness
        var flash: Double
    }

    /// `count` one-sample glitches at random samples of the `moments` part of the track.
    static func glitches(_ count: Int, in moments: ClosedRange<Double>, strength: Double, last: Int,
                         _ random: inout SplitMix64) -> [Int: Glitch]
    {
        let low = max(1, Int((moments.lowerBound * Double(last)).rounded(.up)))
        let high = min(last - 1, Int(moments.upperBound * Double(last)))
        var result: [Int: Glitch] = [:]
        guard low <= high else { return result }
        for _ in 0 ..< count {
            let index = low + Int(random.next() % UInt64(high - low + 1))
            result[index] = Glitch(dx: random.sign() * random.range(0.4, 1) * strength,
                                   alpha: random.range(0.45, 0.7), flash: random.range(0.15, 0.35))
        }
        return result
    }

    /// The scan line's height: thin, a bit thicker on tall windows
    static func cyberLine(_ rect: AnimRect) -> Double { max(2, min(6, rect.height * 0.012)) }

    static func easeOut(_ x: Double) -> Double { 1 - pow(1 - clamp(x, 0, 1), 3) }

    static func salt(_ event: WindowEvent) -> UInt64 {
        switch event {
            case .open: 1
            case .close: 2
            case .move: 3
            case .workspaceIn: 4
            case .workspaceOut: 5
            case .specialIn: 6
            case .specialOut: 7
        }
    }
}

/// SplitMix64: small, fast, and the same numbers everywhere for a seed.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// in [0, 1)
    mutating func unit() -> Double { Double(next() >> 11) / 9_007_199_254_740_992 }

    mutating func range(_ low: Double, _ high: Double) -> Double { low + (high - low) * unit() }

    mutating func sign() -> Double { next() & 1 == 0 ? -1 : 1 }
}
