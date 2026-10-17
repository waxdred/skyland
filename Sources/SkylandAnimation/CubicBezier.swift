/// Cubic bezier easing with P0 = (0, 0) and P3 = (1, 1): the same definition as Hyprland's
/// `bezier = NAME, X0, Y0, X1, Y1`, CSS cubic-bezier() and osax/bezier.h (the payload's).
public struct CubicBezier: Equatable, Hashable, Sendable {
    public let x1: Double
    public let y1: Double
    public let x2: Double
    public let y2: Double

    public init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
    }

    public static let linear = CubicBezier(0, 0, 1, 1)
    /// Hyprland's built-in `default` curve
    public static let hyprlandDefault = CubicBezier(0, 0.75, 0.15, 1)

    /// The eased progress at linear progress `x`, 0 before the start and 1 after the end.
    /// Can go above 1 (overshoot) or below 0 when a control point does.
    public func ease(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        // solve axis(t, x1, x2) == x: Newton first, bisection if it misbehaves
        var t = x
        for _ in 0 ..< 8 {
            let error = Self.axis(t, x1, x2) - x
            let slope = Self.slope(t, x1, x2)
            if abs(error) < 1e-7 || abs(slope) < 1e-7 { break }
            t -= error / slope
        }
        if t < 0 || t > 1 || abs(Self.axis(t, x1, x2) - x) > 1e-5 {
            var low = 0.0, high = 1.0
            t = x
            for _ in 0 ..< 40 {
                if Self.axis(t, x1, x2) < x { low = t } else { high = t }
                t = (low + high) / 2
            }
        }
        return Self.axis(t, y1, y2)
    }

    private static func axis(_ t: Double, _ a: Double, _ b: Double) -> Double {
        ((1 - 3 * b + 3 * a) * t + (3 * b - 6 * a)) * t * t + 3 * a * t
    }

    private static func slope(_ t: Double, _ a: Double, _ b: Double) -> Double {
        3 * (1 - 3 * b + 3 * a) * t * t + 2 * (3 * b - 6 * a) * t + 3 * a
    }
}
