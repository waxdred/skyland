/// Ready-made animation sets, as hyprland.conf lines: a whole look to pick (a settings
/// window choice, `skyland-anim --preset`), or a start to copy into `[animations]`.
public struct AnimationPreset: Sendable {
    public let name: String
    public let summary: String
    public let bezier: [String]
    public let animation: [String]

    public var settings: AnimationSettings { AnimationSettings.parse(bezier: bezier, animation: animation).settings }

    public static func named(_ name: String) -> AnimationPreset? { all.first { $0.name == name } }

    public static let all: [AnimationPreset] = [hyprland, slide, gnome, vertical, cyberspace]

    /// Hyprland's own default config (hyprland.conf since 0.45): windows pop in from 87%,
    /// workspaces cross-fade.
    public static let hyprland = AnimationPreset(
        name: "hyprland",
        summary: "Hyprland's default config: windows pop in from 87%, workspaces fade",
        bezier: [
            "easeOutQuint, 0.23, 1, 0.32, 1",
            "easeInOutCubic, 0.65, 0.05, 0.36, 1",
            "linear, 0, 0, 1, 1",
            "almostLinear, 0.5, 0.5, 0.75, 1.0",
            "quick, 0.15, 0, 0.1, 1",
        ],
        animation: [
            "global, 1, 10, default",
            "border, 1, 5.39, easeOutQuint",
            "windows, 1, 4.79, easeOutQuint",
            "windowsIn, 1, 4.1, easeOutQuint, popin 87%",
            "windowsOut, 1, 1.49, linear, popin 87%",
            "fadeIn, 1, 1.73, almostLinear",
            "fadeOut, 1, 1.46, almostLinear",
            "fade, 1, 3.03, quick",
            "layers, 1, 3.81, easeOutQuint",
            "layersIn, 1, 4, easeOutQuint, fade",
            "layersOut, 1, 1.5, linear, fade",
            "fadeLayersIn, 1, 1.79, almostLinear",
            "fadeLayersOut, 1, 1.39, almostLinear",
            "workspaces, 1, 1.94, almostLinear, fade",
            "workspacesIn, 1, 1.21, almostLinear, fade",
            "workspacesOut, 1, 1.94, almostLinear, fade",
        ],
    )

    /// Everything slides: windows by the closest screen edge with a little overshoot,
    /// workspaces sideways, the scratchpad from the top.
    public static let slide = AnimationPreset(
        name: "slide",
        summary: "windows slide in by the closest screen edge, workspaces slide sideways",
        bezier: ["overshot, 0.05, 0.9, 0.1, 1.05"],
        animation: [
            "windows, 1, 5, overshot, slide",
            "windowsMove, 1, 4, overshot",
            "fade, 1, 4, default",
            "workspaces, 1, 5, overshot, slide",
            "specialWorkspace, 1, 4, overshot, slidevert",
        ],
    )

    /// GNOME-like: windows unfold from a line across their middle, workspaces glide a fifth
    /// of the screen while they fade.
    public static let gnome = AnimationPreset(
        name: "gnome",
        summary: "windows unfold from a line (gnomed), workspaces glide and fade (slidefade 20%)",
        bezier: ["ease, 0.25, 0.1, 0.25, 1"],
        animation: [
            "windows, 1, 4, ease, gnomed",
            "windowsMove, 1, 4, ease",
            "fade, 1, 3, ease",
            "workspaces, 1, 4, ease, slidefade 20%",
            "specialWorkspace, 1, 4, ease, slidefadevert 20%",
        ],
    )

    /// skyland's look so far: popin 80%, whole workspaces sliding vertically while they fade.
    public static let vertical = AnimationPreset(
        name: "vertical",
        summary: "skyland's look so far: windows pop in from 80%, workspaces slide vertically",
        bezier: ["easeOut, 0.05, 0.9, 0.1, 1.0"],
        animation: [
            "windows, 1, 5, easeOut, popin 80%",
            "fade, 1, 4, default",
            "workspaces, 1, 6, default, slidefadevert 100%",
            "specialWorkspace, 1, 5, easeOut, slidevert",
        ],
    )

    /// skyland's cyberspace: windows rez in as a white-hot scan line and derez out.
    public static let cyberspace = AnimationPreset(
        name: "cyberspace",
        summary: "windows rez in from a white-hot scan line through glitches, and derez out",
        bezier: ["neon, 0.1, 0.9, 0.2, 1.08"],
        animation: [
            "windows, 1, 5.5, neon, cyberspace",
            "windowsOut, 1, 4.5, neon, cyberspace",
            "windowsMove, 1, 3.5, neon",
            "fade, 1, 3, default",
            "workspaces, 1, 6.5, neon, cyberspace",
            "specialWorkspace, 1, 5, neon, cyberspace",
            "borderangle, 1, 30, linear, loop",
        ],
    )
}
