import Common

// Theme files for the hypr profile, applied by bin/skyland-theme (sketchybar,
// Ghostty). Like 43PR, a theme is a GTK colors.css: `@define-color bg #000000;`.
// alt-l toggles between the dark and light files.
//
// [theme]
// dark = '~/.config/skyland/themes/43pr-default.css'
// light = '~/.config/skyland/themes/43pr-white.css'
struct ThemeConfig: ConvenienceMutable, Equatable, Sendable {
    var dark: String = ""
    var light: String = ""
}

private let themeParser: [String: any ParserProtocol<ThemeConfig>] = [
    "dark": Parser(\.dark, parseString),
    "light": Parser(\.light, parseString),
]

/// Read by bin/skyland-wallpaper and bin/skyland-theme; parsed here so the config validates.
// [wallpaper]
// dir = '~/Pictures/Wallpapers'
// dynamic-colors = true
// prefer = 'saturation'
struct WallpaperConfig: ConvenienceMutable, Equatable, Sendable {
    var dir: String = ""
    var dynamicColors: Bool = false
    var prefer: String = ""
}

private let wallpaperParser: [String: any ParserProtocol<WallpaperConfig>] = [
    "dir": Parser(\.dir, parseString),
    "dynamic-colors": Parser(\.dynamicColors, parseBool),
    "prefer": Parser(\.prefer, parseString),
]

func parseWallpaper(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> WallpaperConfig {
    parseTable(raw, WallpaperConfig(), wallpaperParser, backtrace, &c)
}

func parseTheme(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> ThemeConfig {
    parseTable(raw, ThemeConfig(), themeParser, backtrace, &c)
}
