import AppKit
import Common
import SwiftUI

// skyland settings window (`settings` command, alt-i toggles it), themed with the
// current skyland theme over a blurred translucent background: the visual settings of
// the config as sliders, switches and pickers. Changes wait until Save (cmd-s): then
// they are checked with the config parser, each written to its own line of the
// config file (comments kept, see tomlLines.swift), the config reloaded once and
// each owning skyland script run once (theme, media widget, lock, appearance).
// Moving a slider live rewrote the file and reloaded everything at each step.

struct SettingsCommand: Command {
    let args: SettingsCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        showSettingsWindow()
        return .succ
    }
}

/// <repo> of the running app (<repo>/.build/Skyland.app), where bin/ scripts live.
var skylandRepo: URL { Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent() }

@MainActor
func runSkylandScript(_ arguments: [String]) {
    let process = Process()
    process.executableURL = skylandRepo.appending(path: "bin/\(arguments[0])")
    process.arguments = Array(arguments.dropFirst())
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
}

struct SettingField: Identifiable {
    enum Kind {
        case int(ClosedRange<Int>, step: Int, unit: String)
        case bool
        case choice([String])
        case text
    }
    let section: String
    let key: String
    let label: String
    let kind: Kind
    var after: [String]? = nil // skyland script run after a change, e.g. ["skyland-theme", "apply"]
    var id: String { "\(section).\(key)" }
}

private let settingGroups: [(title: String, fields: [SettingField])] = [
    ("Gaps", [
        SettingField(section: "", key: "gaps.inner.horizontal", label: "Inner horizontal", kind: .int(0 ... 40, step: 1, unit: "px")),
        SettingField(section: "", key: "gaps.inner.vertical", label: "Inner vertical", kind: .int(0 ... 40, step: 1, unit: "px")),
        SettingField(section: "", key: "gaps.outer.top", label: "Outer top", kind: .int(0 ... 60, step: 1, unit: "px")),
        SettingField(section: "", key: "gaps.outer.right", label: "Outer right", kind: .int(0 ... 60, step: 1, unit: "px")),
        SettingField(section: "", key: "gaps.outer.bottom", label: "Outer bottom", kind: .int(0 ... 60, step: 1, unit: "px")),
        SettingField(section: "", key: "gaps.outer.left", label: "Outer left", kind: .int(0 ... 60, step: 1, unit: "px")),
    ]),
    ("Layout", [
        SettingField(section: "", key: "dwindle", label: "Dwindle", kind: .bool),
        SettingField(section: "", key: "dwindle-smart-split", label: "Smart split (follows the cursor)", kind: .bool),
        SettingField(section: "", key: "floating-center-percent", label: "Floating size", kind: .int(30 ... 100, step: 5, unit: "%")),
        SettingField(section: "", key: "focus-follows-mouse.enabled", label: "Focus follows mouse", kind: .bool),
        SettingField(section: "", key: "mouse-modifier", label: "Mouse move / resize key", kind: .choice(["alt", "cmd", "ctrl", "ctrl-alt", ""])),
    ]),
    ("Decoration", [
        SettingField(section: "decoration", key: "rounding", label: "Rounding", kind: .int(0 ... 24, step: 1, unit: "px")),
        SettingField(section: "decoration", key: "active-opacity", label: "Active opacity", kind: .int(30 ... 100, step: 1, unit: "%")),
        SettingField(section: "decoration", key: "inactive-opacity", label: "Inactive opacity", kind: .int(30 ... 100, step: 1, unit: "%")),
        SettingField(section: "decoration", key: "dim-inactive", label: "Dim inactive", kind: .int(0 ... 80, step: 1, unit: "%")),
        SettingField(section: "decoration", key: "border-width", label: "Border width", kind: .int(0 ... 8, step: 1, unit: "px"), after: ["skyland-theme", "apply"]),
        SettingField(section: "decoration", key: "blur", label: "Ghostty blur", kind: .int(0 ... 20, step: 1, unit: ""), after: ["skyland-theme", "apply"]),
    ]),
    ("Animations", [
        SettingField(section: "animations", key: "enabled", label: "Enabled", kind: .bool),
        SettingField(section: "animations", key: "windows-ms", label: "Windows", kind: .int(0 ... 1500, step: 50, unit: "ms")),
        SettingField(section: "animations", key: "workspaces-ms", label: "Workspaces", kind: .int(0 ... 1500, step: 50, unit: "ms")),
        SettingField(section: "animations", key: "fade-ms", label: "Fades", kind: .int(0 ... 1500, step: 50, unit: "ms")),
        SettingField(section: "animations", key: "windows-bezier", label: "Windows curve", kind: .text),
        SettingField(section: "animations", key: "workspaces-bezier", label: "Workspaces curve", kind: .text),
    ]),
    ("Trackpad", [
        SettingField(section: "gestures", key: "workspace-swipe", label: "Swipe between workspaces", kind: .bool),
        SettingField(section: "gestures", key: "workspace-swipe-fingers", label: "Fingers", kind: .int(3 ... 4, step: 1, unit: "")),
        SettingField(section: "gestures", key: "workspace-swipe-direction", label: "Direction", kind: .choice(["horizontal", "vertical"])),
        SettingField(section: "gestures", key: "workspace-swipe-distance", label: "Distance", kind: .int(50 ... 500, step: 10, unit: "pt")),
        SettingField(section: "gestures", key: "workspace-swipe-cancel-ratio", label: "Switches past", kind: .int(10 ... 100, step: 5, unit: "%")),
        SettingField(section: "gestures", key: "workspace-swipe-invert", label: "Invert", kind: .bool),
    ]),
    ("Wallpaper", [
        SettingField(section: "wallpaper", key: "dynamic-colors", label: "Colors from the wallpaper", kind: .bool, after: ["skyland-theme", "apply"]),
        SettingField(section: "wallpaper", key: "auto-mode", label: "Light / dark from the wallpaper", kind: .bool),
        SettingField(section: "wallpaper", key: "scheme", label: "Color scheme", kind: .choice(["auto", "scheme-content", "scheme-tonal-spot", "scheme-vibrant", "scheme-expressive", "scheme-fidelity", "scheme-monochrome", "scheme-neutral", "scheme-rainbow", "scheme-fruit-salad"])),
        SettingField(section: "wallpaper", key: "dir", label: "Folder", kind: .text),
    ]),
    ("macOS appearance", [
        SettingField(section: "appearance", key: "sync-dark-mode", label: "Dark / light follows skyland", kind: .bool, after: ["skyland-appearance"]),
        SettingField(section: "appearance", key: "accent", label: "Accent color", kind: .choice(["theme", "off", "blue", "purple", "pink", "red", "orange", "yellow", "green", "graphite", "multicolor"]), after: ["skyland-appearance"]),
        SettingField(section: "appearance", key: "highlight", label: "Highlight color", kind: .choice(["theme", "off", "blue", "purple", "pink", "red", "orange", "yellow", "green", "graphite"]), after: ["skyland-appearance"]),
    ]),
    ("Terminal", [
        SettingField(section: "terminal", key: "app", label: "Terminal app (alt-t)", kind: .choice(["Ghostty", "iTerm", "WezTerm", "kitty", "Terminal", "Alacritty"])),
    ]),
    ("Media widget and lock screen", [
        SettingField(section: "media", key: "opacity", label: "Media widget opacity", kind: .int(10 ... 100, step: 1, unit: "%"), after: ["skyland-media", "restart"]),
        SettingField(section: "media", key: "style", label: "Media widget style", kind: .choice(["classic", "audioware"]), after: ["skyland-media", "restart"]),
        SettingField(section: "lock", key: "blur", label: "Lock wallpaper blur", kind: .int(0 ... 20, step: 1, unit: ""), after: ["skyland-lock", "refresh"]),
        SettingField(section: "lock", key: "name", label: "Lock name", kind: .text, after: ["skyland-lock", "refresh"]),
    ]),
]

/// Colors of the settings window: the current skyland theme (theme.css, mode).
struct SettingsColors {
    var accent = Color.accentColor, background = Color.black, text = Color.primary, dim = Color.secondary, dark = true

    @MainActor static func current() -> SettingsColors {
        let colors = skylandThemeColors()
        let mode = (try? String(contentsOf: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cache/skyland/theme-mode"), encoding: .utf8)) ?? "dark"
        var result = SettingsColors()
        if let accent = colors["accent"] { result.accent = Color(nsColor: accent) }
        if let background = colors["bg"] { result.background = Color(nsColor: background) }
        if let text = colors["fg"] { result.text = Color(nsColor: text) }
        if let dim = colors["fg_dim"] { result.dim = Color(nsColor: dim) }
        result.dark = !mode.hasPrefix("light")
        return result
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    /// Raw TOML values by field id (`'alt'`, `85`, `true`), as shown (saved or not)
    @Published var values: [String: String] = [:]
    /// Changes not written yet: Save writes them all at once (one write, one reload)
    @Published var pending: [String: String] = [:]
    @Published var error: String? = nil
    @Published var saved = false
    @Published var colors = SettingsColors()

    init() { load() }

    var configUrl: URL { readConfig(forceConfigUrl: nil).configUrl }

    /// Values from the file; drops unsaved changes (Revert).
    func load() {
        let text = (try? String(contentsOf: configUrl, encoding: .utf8)) ?? ""
        for group in settingGroups {
            for field in group.fields { values[field.id] = tomlValue(text, section: field.section, key: field.key) }
        }
        pending = [:]
        error = nil
        colors = .current()
    }

    func set(_ field: SettingField, _ raw: String) {
        values[field.id] = raw
        pending[field.id] = raw
        saved = false
    }

    func save() async {
        guard !pending.isEmpty else { return }
        let url = configUrl
        guard var text = try? String(contentsOf: url, encoding: .utf8) else { error = "cannot read \(url.path)"; return }
        let fields = settingGroups.flatMap(\.fields).filter { pending[$0.id] != nil }
        for field in fields { text = tomlSet(text, section: field.section, key: field.key, value: pending[field.id]!) }
        let errors = parseConfig(text).errors
        guard errors.isEmpty else {
            error = errors.map { $0.description(.error) }.joined(separator: "\n")
            return
        }
        do {
            try text.write(to: url.resolvingSymlinksInPath(), atomically: true, encoding: .utf8)
        } catch {
            self.error = "cannot write \(url.path): \(error.localizedDescription)"
            return
        }
        error = nil
        pending = [:]
        _ = await reloadConfig_nonCancellable()
        // each owning script once (theme, media widget, lock, appearance)
        var scripts: [[String]] = []
        for field in fields { if let after = field.after, !scripts.contains(after) { scripts.append(after) } }
        scripts.forEach(runSkylandScript)
        colors = .current()
        saved = true
    }
}

private struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var keys: KeysModel
    @ObservedObject var rules: RulesModel
    @AppStorage("skyland.settings.tab") private var tab = "general" // reopens on the last tab

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
                Text("skyland").font(.system(.title2, design: .monospaced).weight(.bold)).foregroundStyle(model.colors.accent)
            }
            .padding(.top, 26) // under the transparent title bar
            TabView(selection: $tab) {
                GeneralView(model: model).tabItem { Text("General") }.tag("general")
                KeysView(model: keys).tabItem { Text("Keys") }.tag("keys")
                RulesView(model: rules).tabItem { Text("Rules") }.tag("rules")
            }
            .padding(.top, 8)
        }
        .frame(minWidth: 620, minHeight: 560)
        .tint(model.colors.accent)
        .background(model.colors.background.opacity(0.8)) // the theme over the window blur, a bit see-through
        .preferredColorScheme(model.colors.dark ? .dark : .light)
    }
}

/// `// GAPS` section header in the theme accent.
private struct SectionHeader: View {
    let title: String
    let colors: SettingsColors
    var body: some View {
        Text("// " + title.uppercased())
            .font(.system(.caption, design: .monospaced).weight(.bold))
            .foregroundStyle(colors.accent)
            .kerning(1.2)
    }
}

private struct GeneralView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            if let error = model.error {
                Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled)
            }
            Section {
                HStack {
                    Button("Theme…") { runSkylandScript(["skyland-theme", "pick"]) }
                    Button("Wallpaper…") { runSkylandScript(["skyland-wallpaper", "pick"]) }
                    Button("Light / dark") { runSkylandScript(["skyland-theme", "toggle"]) }
                    Spacer()
                    Button("Open config file") { NSWorkspace.shared.open(model.configUrl) }
                }
            } header: { SectionHeader(title: "Look", colors: model.colors) }
            ForEach(settingGroups, id: \.title) { group in
                Section {
                    ForEach(group.fields) { field in row(field) }
                } header: { SectionHeader(title: group.title, colors: model.colors) }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(minWidth: 480, minHeight: 520)
        .safeAreaInset(edge: .bottom) { saveBar }
    }

    /// Unsaved changes, Revert, Save (cmd-s)
    private var saveBar: some View {
        HStack(spacing: 12) {
            let count = model.pending.count
            Text(count > 0 ? "\(count) unsaved change\(count > 1 ? "s" : "")" : model.saved ? "saved" : "")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(count > 0 ? model.colors.accent : model.colors.dim)
            Spacer()
            Button("Revert") { model.load() }
                .disabled(count == 0)
            Button("Save") { Task { await model.save() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(count == 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func row(_ field: SettingField) -> some View {
        let raw = model.values[field.id]
        let changed = model.pending[field.id] != nil
        let label = Text(field.label).foregroundStyle(changed ? model.colors.accent : model.colors.text)
        switch field.kind {
            case .int(let range, let step, let unit):
                let value = Int(raw ?? "") ?? range.lowerBound
                HStack {
                    label
                    Slider(
                        // no `step:`, it draws a tick per step; rounded to the step instead
                        value: Binding(get: { Double(value) }, set: {
                            let rounded = Int(($0 / Double(step)).rounded()) * step
                            if rounded != value { model.set(field, String(rounded)) }
                        }),
                        in: Double(range.lowerBound) ... Double(range.upperBound),
                    )
                    Text("\(value)\(unit)").font(.system(.body, design: .monospaced)).monospacedDigit()
                        .foregroundStyle(model.colors.dim).frame(width: 70, alignment: .trailing)
                }
            case .bool:
                Toggle(isOn: Binding(get: { raw == "true" }, set: { model.set(field, $0 ? "true" : "false") })) { label }
            case .choice(let options):
                Picker(selection: Binding(get: { unquote(raw) }, set: { model.set(field, "'\($0)'") })) {
                    ForEach(options, id: \.self) { Text($0.isEmpty ? "off" : $0).tag($0) }
                } label: { label }
            case .text:
                TextField(text: Binding(get: { unquote(raw) }, set: { model.set(field, "'\($0)'") })) { label }
        }
    }

    private func unquote(_ raw: String?) -> String {
        guard let raw, raw.count >= 2, raw.first == "'" || raw.first == "\"" else { return raw ?? "" }
        return String(raw.dropFirst().dropLast())
    }
}

@MainActor private var settingsWindow: NSWindow? = nil
@MainActor private let settingsModel = SettingsModel()
@MainActor private let settingsKeys = KeysModel()
@MainActor private let settingsRules = RulesModel()

@MainActor
func showSettingsWindow() {
    if let window = settingsWindow, window.isVisible, window.isKeyWindow { // alt-i again: close it
        window.close()
        return
    }
    if settingsWindow == nil {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 760),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "skyland settings"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        // blurred translucent background, the theme color is laid over it by SettingsView
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        let host = NSHostingView(rootView: SettingsView(model: settingsModel, keys: settingsKeys, rules: settingsRules))
        host.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: blur.leadingAnchor), host.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            host.topAnchor.constraint(equalTo: blur.topAnchor), host.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        window.contentView = blur
        settingsWindow = window
    } else {
        settingsModel.load() // the file (or the theme) may have changed meanwhile
        settingsKeys.load()
        settingsRules.load()
    }
    guard let window = settingsWindow else { return }
    // on the screen under the mouse; orderFrontRegardless: a background app's activate can be ignored
    if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
        window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - window.frame.width / 2, y: screen.visibleFrame.midY - window.frame.height / 2))
    }
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
}
