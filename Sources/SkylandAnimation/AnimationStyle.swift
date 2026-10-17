/// The style of an animation (the 5th field of Hyprland's `animation = ...` line):
/// Hyprland's window and workspace styles, plus skyland's own `cyberspace`.
/// Every style works for every window event here (Hyprland keeps `popin` and `gnomed`
/// to windows and `slidevert`, `slidefade` to workspaces).
public enum AnimationStyle: Equatable, Hashable, Sendable, CustomStringConvertible {
    /// `slide [top|bottom|left|right]`: a window comes in by a screen edge, the closest
    /// one without a neighbouring screen when none is given, and leaves by it; a workspace
    /// slides horizontally, the next one coming from the right
    case slide(SlideEdge?)
    /// `slidevert`: a workspace slides vertically, the next one coming from below
    case slideVert
    /// `popin [N%]`: from N% of the size around the center, and back to it (default 80%)
    case popin(percent: Double)
    /// `gnomed`: from a line across the middle of the window, GNOME-like, and back to it
    case gnomed
    /// `fade`: the opacity only
    case fade
    /// `slidefade [N%]` / `slidefadevert [N%]`: a slide of N% of the screen with a fade
    /// (default 20%)
    case slideFade(percent: Double, vertical: Bool)
    /// skyland `cyberspace`: the window ignites as a white-hot scan line, unfolds through
    /// glitches and settles; it leaves the other way (derez): glitch, collapse to a line,
    /// shrink to a dot
    case cyberspace
    /// `borderangle` only: the border gradient turns once at each focus change, or loops
    case once, loop

    /// A style as written in hyprland.conf: "slide left", "popin 87%", "slidefade 20%"...
    public static func parse(_ text: String) -> AnimationStyle? {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let name = words.first else { return nil }
        let rest = Array(words.dropFirst())
        switch name {
            case "slide":
                if rest.isEmpty { return .slide(nil) }
                guard rest.count == 1, let edge = SlideEdge(rawValue: rest[0]) else { return nil }
                return .slide(edge)
            case "popin": return percent(rest, default: 80).map { .popin(percent: $0) }
            case "slidefade": return percent(rest, default: 20).map { .slideFade(percent: $0, vertical: false) }
            case "slidefadevert": return percent(rest, default: 20).map { .slideFade(percent: $0, vertical: true) }
            case "slidevert": return rest.isEmpty ? .slideVert : nil
            case "gnomed": return rest.isEmpty ? .gnomed : nil
            case "fade": return rest.isEmpty ? .fade : nil
            case "cyberspace": return rest.isEmpty ? .cyberspace : nil
            case "once": return rest.isEmpty ? .once : nil
            case "loop": return rest.isEmpty ? .loop : nil
            default: return nil
        }
    }

    /// "N%" with N in 0...100, or the default when there is no word
    private static func percent(_ words: [String], default value: Double) -> Double? {
        if words.isEmpty { return value }
        guard words.count == 1, words[0].hasSuffix("%"), let number = Double(words[0].dropLast()),
              (0 ... 100).contains(number) else { return nil }
        return number
    }

    public var description: String {
        switch self {
            case .slide(let edge): edge.map { "slide \($0.rawValue)" } ?? "slide"
            case .slideVert: "slidevert"
            case .popin(let percent): "popin \(Self.format(percent))%"
            case .gnomed: "gnomed"
            case .fade: "fade"
            case .slideFade(let percent, let vertical): "\(vertical ? "slidefadevert" : "slidefade") \(Self.format(percent))%"
            case .cyberspace: "cyberspace"
            case .once: "once"
            case .loop: "loop"
        }
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    /// The style fades the window itself (on top of fadeIn / fadeOut for windows).
    var fades: Bool {
        switch self {
            case .fade, .slideFade: true
            default: false
        }
    }
}
