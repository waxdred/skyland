import Foundation

/// skyland: from skylandbar (SkylandBarCore/LensMotion.swift).
/// How a selection lens moves, as Apple's tab bars: when it
/// goes to another item it flows there like a drop. Its two ends are springs of their own:
/// the leading one leaves first and fast, the trailing one follows later and catches up, so
/// the drop stretches on its way and settles with a little jelly; stretched, it gets
/// thinner, as a drop keeps its volume; and it is lifted while it moves (`lift`, 0...1: the
/// glass magnifies more, its rim and shade grow).
///
/// It also leaves a drop behind: where it was stays a tail (`tails`) that shrinks away, and the
/// renderer melts head and tail together (a smooth union), so a neck of liquid joins them,
/// thins as the head is pulled to its new item, and snaps.
///
/// `glass_lens_response` (seconds) is the spring of the whole, `glass_lens_bounce` its
/// overshoot (0...1), `glass_lens_stretch` how unlike the ends are (0: it slides in one
/// piece). A spring keeps its speed when the target changes on the way; a lens that appears
/// grows out of 70 %. Rects in points.
public final class LensMotion {
    public var response = 0.35
    public var bounce = 0.3
    public var stretch = 1.0

    private struct Spring {
        var value: Double
        var velocity = 0.0
    }

    /// left, right, center y, height; and how lifted it is
    private struct Lens {
        var left: Spring
        var right: Spring
        var middle: Spring
        var height: Spring
        var lift = 0.0
        /// the center x it goes to: a new one leaves a tail where it was
        var goal: Double?
        var tail: Box?
        var tailLife = 0.0
    }

    private var lenses: [Lens] = []
    private var last: Double?

    public init() {}

    /// The rects to draw for these targets at `now` (seconds), how lifted each is, and
    /// whether they still move.
    public func step(_ targets: [Box], now: Double, reduceMotion: Bool = false) -> (rects: [Box], lifts: [Double], tails: [Box?], moving: Bool) {
        defer { last = now }
        if reduceMotion || response <= 0 {
            lenses = targets.map { Lens(left: Spring(value: $0.x), right: Spring(value: $0.x + $0.width),
                                        middle: Spring(value: $0.y + $0.height / 2), height: Spring(value: $0.height)) }
            return (targets, targets.map { _ in 0 }, targets.map { _ in nil }, false)
        }
        // the lenses there were keep going; a new one grows from 70 % of its size
        lenses = targets.indices.map { index in
            if index < lenses.count { return lenses[index] }
            let t = targets[index], center = t.x + t.width / 2
            return Lens(left: Spring(value: center - t.width * 0.35), right: Spring(value: center + t.width * 0.35),
                        middle: Spring(value: t.y + t.height / 2), height: Spring(value: t.height * 0.7))
        }
        let dt = min(max(now - (last ?? now), 0), 1.0 / 20)
        let steps = max(1, Int((dt * 240).rounded(.up))) // small steps: the same at any frame rate
        let h = dt / Double(steps)
        let lead = response / (1 + 0.3 * stretch), trail = response * (1 + 0.15 * stretch)
        var moving = false
        var rects: [Box] = []
        var lifts: [Double] = []
        var tails: [Box?] = []
        for index in lenses.indices {
            let t = targets[index]
            var lens = lenses[index]
            // a new item: a drop of it stays where it is, and shrinks away while the rest goes
            let goal = t.x + t.width / 2
            if let old = lens.goal, abs(old - goal) > 0.5 {
                let height = lens.height.value
                lens.tail = Box(x: lens.left.value, y: lens.middle.value - height / 2, width: lens.right.value - lens.left.value, height: height)
                lens.tailLife = 1
            }
            lens.goal = goal
            let goingRight = t.x + t.width / 2 > (lens.left.value + lens.right.value) / 2
            let settled = [
                advance(&lens.left, to: t.x, response: goingRight ? trail : lead, steps: steps, h: h),
                advance(&lens.right, to: t.x + t.width, response: goingRight ? lead : trail, steps: steps, h: h),
                advance(&lens.middle, to: t.y + t.height / 2, response: response, steps: steps, h: h),
                advance(&lens.height, to: t.height, response: response, steps: steps, h: h),
            ].allSatisfy { $0 }
            // lifted while it moves fast, settling as it slows
            let speed = abs(lens.left.velocity + lens.right.velocity) / 2
            lens.lift += (min(1, speed / 500) - lens.lift) * min(1, dt * 18)
            if settled && lens.lift < 0.01 { lens.lift = 0 }
            if !settled || lens.lift > 0 { moving = true }
            // the tail: smaller and smaller, gone after about the time the head takes
            var tail: Box?
            if let left = lens.tail, lens.tailLife > 0 {
                lens.tailLife -= dt / max(response * 1.4, 0.05)
                if lens.tailLife > 0 {
                    let s = pow(lens.tailLife, 0.8)
                    let w = max(1, left.width * (0.35 + 0.65 * s) * s.squareRoot()), hh = max(1, left.height * (0.45 + 0.55 * s))
                    tail = Box(x: left.x + left.width / 2 - w / 2, y: left.y + left.height / 2 - hh / 2, width: w, height: hh)
                    moving = true
                } else {
                    lens.tail = nil
                }
            }
            tails.append(tail)
            lenses[index] = lens

            // drawn: at most 1.8 times as long, from its leading end; thinner as it stretches
            var left = lens.left.value, right = lens.right.value
            let longest = t.width * 1.8
            if right - left > longest {
                if goingRight { left = right - longest } else { right = left + longest }
            }
            let width = max(1, right - left)
            let height = lens.height.value * min(1.06, max(0.8, (t.width / width).squareRoot()))
            rects.append(Box(x: left, y: lens.middle.value - height / 2, width: width, height: height))
            lifts.append(lens.lift)
        }
        return (rects, lifts, tails, moving)
    }

    /// One spring toward `goal`; true once it is there at rest (then snapped onto it).
    private func advance(_ spring: inout Spring, to goal: Double, response: Double, steps: Int, h: Double) -> Bool {
        let stiffness = pow(2 * Double.pi / response, 2)
        let damping = 2 * max(0.05, 1 - bounce) * stiffness.squareRoot()
        for _ in 0 ..< steps {
            spring.velocity += (-stiffness * (spring.value - goal) - damping * spring.velocity) * h
            spring.value += spring.velocity * h
        }
        if abs(spring.value - goal) < 0.2 && abs(spring.velocity) < 2 {
            spring = Spring(value: goal)
            return true
        }
        return false
    }
}

/// A rect in points (LensMotion's unit), top-left origin.
public struct Box: Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}
