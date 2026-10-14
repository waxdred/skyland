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

func parseTheme(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> ThemeConfig {
    parseTable(raw, ThemeConfig(), themeParser, backtrace, &c)
}
