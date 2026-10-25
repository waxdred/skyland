// skyland wallpaper picker (built with Sources/SkylandGlass for ui-style = 'glass'), like 43PR's quickshell hyprquickpaper.
//   skyland-wallpaper-picker <dir>     pick an image: prints its path, exit 1 if cancelled
//   skyland-wallpaper-picker --resident <dir>   stays running, shown and hidden by SIGUSR1 (alt-w): a
//       picked image is set with $SKYLAND_WALLPAPER_SET set <file>; opens at once, no app to start
//   skyland-wallpaper-picker --themes <file.css...>   pick a theme from color previews: prints its path
//   skyland-wallpaper-picker --set <file>   set it as wallpaper on every screen
//   skyland-wallpaper-picker --blur <in> <out.jpg> <radius>   blurred copy (lock screen)
//   skyland-wallpaper-picker --saturation <file>   mean chroma 0..1 (0 = grayscale)
//   skyland-wallpaper-picker --luminance <file>   mean relative luminance 0..1 (0 = black)
// Built by bin/skyland-build; driven by bin/skyland-wallpaper and bin/skyland-lock.
import AppKit
import CoreImage
import ImageIO

let args = CommandLine.arguments
if args.count == 3, args[1] == "--saturation" || args[1] == "--luminance" {
    // Mean chroma (max - min of r, g, b) of a 64x64 downscale, 0 = grayscale image
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceThumbnailMaxPixelSize: 64,
          ] as CFDictionary),
          let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
    context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
    let pixels = context.data!.bindMemory(to: UInt8.self, capacity: 64 * 64 * 4)
    var total = 0.0
    for i in 0 ..< 64 * 64 {
        let r = pixels[i * 4], g = pixels[i * 4 + 1], b = pixels[i * 4 + 2]
        total += args[1] == "--luminance"
            ? (0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)) / 255 // Rec. 709 on the sRGB values
            : Double(max(r, g, b) - min(r, g, b)) / 255
    }
    print(String(format: "%.3f", total / Double(64 * 64)))
    exit(0)
}
if args.count == 5, args[1] == "--blur" {
    // Downscale first: a 1920 px wide image is plenty once blurred, and fast
    guard let input = CIImage(contentsOf: URL(fileURLWithPath: args[2])), let radius = Double(args[4]) else { exit(1) }
    let scale = min(1, 1920 / input.extent.width)
    let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let blurred = small.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: small.extent)
    let context = CIContext()
    do {
        try context.writeJPEGRepresentation(of: blurred, to: URL(fileURLWithPath: args[3]),
                                            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.85])
    } catch {
        exit(1)
    }
    exit(0)
}
if args.count >= 3, args[1] == "--notify" {
    // Post distributed notifications (bin/skyland-appearance): apps reload the
    // accent / highlight colors on AppleColorPreferencesChangedNotification
    for name in args.dropFirst(2) {
        DistributedNotificationCenter.default().postNotificationName(.init(name), object: nil, userInfo: nil, deliverImmediately: true)
    }
    exit(0)
}
if args.count == 3, args[1] == "--set" {
    let url = URL(fileURLWithPath: args[2])
    do {
        for screen in NSScreen.screens {
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
        }
    } catch {
        FileHandle.standardError.write("cannot set wallpaper: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
    exit(0)
}
let pickingThemes = args.count > 2 && args[1] == "--themes"
let resident = args.count == 3 && args[1] == "--resident"
guard args.count == 2 || pickingThemes || resident else {
    FileHandle.standardError.write("usage: skyland-wallpaper-picker <dir> | --resident <dir> | --themes <file.css...> | --set <file>\n".data(using: .utf8)!)
    exit(2)
}
let cache = NSHomeDirectory() + "/.cache/skyland"
if resident {
    // first thing: a SIGUSR1 sent while it starts must not end it (its default action), and the
    // pid must be there for the next key (a cold start took seconds: a second picker started)
    signal(SIGUSR1, SIG_IGN)
    try? FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
    try? String(getpid()).write(toFile: cache + "/picker.pid", atomically: true, encoding: .utf8)
}

let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "heic", "gif", "bmp", "tiff"]
func images(in dir: URL) -> [URL] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        .filter { imageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
        .sorted()
        .map { dir.appendingPathComponent($0) }
}

// --themes: one group of CSS themes, shown as color previews in the wallpaper strip
// Else themes: one per sub-folder of <dir> (skyland-wallpaper fetch user/), plus <dir> itself for loose images.
// Resident: read again at each opening (new wallpapers, another dir in the config).
var themes: [(name: String, files: [URL])] = []
func loadThemes() {
    if pickingThemes {
        themes = [("themes", args.dropFirst(2).map { URL(fileURLWithPath: $0) })]
        return
    }
    // resident: the dir bin/skyland-wallpaper last asked for
    let asked = resident ? (try? String(contentsOfFile: cache + "/picker-dir", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    let root = URL(fileURLWithPath: asked.flatMap { $0.isEmpty ? nil : $0 } ?? args[args.count - 1])
    let subdirs = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    themes = (subdirs + [root]).map { ($0.lastPathComponent, images(in: $0)) }.filter { !$0.1.isEmpty }
}
loadThemes()
if themes.isEmpty && !resident {
    FileHandle.standardError.write("no images in \(args[1])\n".data(using: .utf8)!)
    exit(1)
}

// So "cyber" finds 43PR's small-caps labels like "ꜱᴄɪ-ꜰɪ∕ᴄʏʙᴇʀᴘᴜɴᴋ"
let smallCaps = Dictionary(uniqueKeysWithValues: zip("ᴀʙᴄᴅᴇꜰɢʜɪᴊᴋʟᴍɴᴏᴘǫʀꜱᴛᴜᴠᴡʏᴢ", "abcdefghijklmnopqrstuvwyz"))
func fold(_ text: String) -> String {
    String(text.map { smallCaps[$0] ?? $0 }).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
}
func thumbnail(_ url: URL, maxPixels: Int) -> NSImage? {
    if url.pathExtension == "css" { return themePreview(url) }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceCreateThumbnailWithTransform: true,
              kCGImageSourceThumbnailMaxPixelSize: maxPixels,
          ] as CFDictionary) else { return nil }
    return NSImage(cgImage: image, size: .zero)
}

/// `@define-color key #rrggbb;` of a theme file.
func themeColors(_ url: URL) -> [String: NSColor]? {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    var colors: [String: NSColor] = [:]
    let regex = try! NSRegularExpression(pattern: "@define-color\\s+(\\w+)\\s+#([0-9A-Fa-f]{6})")
    for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        let key = String(text[Range(match.range(at: 1), in: text)!]), hex = Int(text[Range(match.range(at: 2), in: text)!], radix: 16)!
        colors[key] = NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
    return colors
}

/// The current skyland theme (skyland-theme), for the picker itself; system colors without one.
/// Resident: read again at each opening (a new wallpaper brings new colors).
var skylandTheme: [String: NSColor] = [:]
var themeFg = NSColor.labelColor, themeDim = NSColor.secondaryLabelColor, themeAccent = NSColor.white
func loadColors() {
    skylandTheme = themeColors(URL(fileURLWithPath: cache + "/theme.css")) ?? [:]
    themeFg = skylandTheme["fg"] ?? .labelColor
    themeDim = skylandTheme["fg_muted"] ?? .secondaryLabelColor
    themeAccent = skylandTheme["accent"] ?? .white
}
loadColors()

/// Color preview of a theme file (`@define-color key #rrggbb;`): a small window
/// in the theme on its background, the terminal palette, and the theme name.
func themePreview(_ url: URL) -> NSImage? {
    guard let colors = themeColors(url) else { return nil }
    func color(_ key: String) -> NSColor { colors[key] ?? .gray }
    let name = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "43pr-", with: "").replacingOccurrences(of: "-", with: " ")
    return NSImage(size: NSSize(width: 300, height: 190), flipped: true) { rect in
        color("bg").setFill()
        rect.fill()
        let window = NSRect(x: 24, y: 22, width: 252, height: 104)
        color("bg_card").setFill()
        NSBezierPath(roundedRect: window, xRadius: 8, yRadius: 8).fill()
        color("border_strong").setStroke()
        let border = NSBezierPath(roundedRect: window.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        border.lineWidth = 2
        border.stroke()
        (name as NSString).draw(at: NSPoint(x: 40, y: 36), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: color("fg")])
        ("~ skyland" as NSString).draw(at: NSPoint(x: 40, y: 66), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: color("fg_dim")])
        color("accent").setFill()
        NSBezierPath(roundedRect: NSRect(x: 40, y: 96, width: 90, height: 12), xRadius: 6, yRadius: 6).fill()
        for i in 0 ..< 8 {
            color("term\(i + 8)").setFill()
            NSBezierPath(ovalIn: NSRect(x: 24 + CGFloat(i) * 33, y: 146, width: 24, height: 24)).fill()
        }
        return true
    }
}

/// ui-style = 'glyph': skyland's Nothing like panels (Sources/AppBundle/skyland/uiStyle.swift)
let glyph = (try? String(contentsOfFile: uiStyleFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == "glyph"
if glyph { // Space Mono, Doto: resources/fonts next to .build, as for Skyland.app
    let fonts = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent().appending(path: "../resources/fonts").standardized
    for file in (try? FileManager.default.contentsOfDirectory(at: fonts, includingPropertiesForKeys: nil)) ?? []
    where ["ttf", "otf"].contains(file.pathExtension) {
        CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
    }
}
func glyphFont(_ name: String, _ size: CGFloat) -> NSFont { NSFont(name: name, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular) }

/// The glyph panel: opaque bg_panel, a faint dot grid, a thin line around.
final class GlyphPanel: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 24, yRadius: 24)
        (skylandTheme["bg_panel"] ?? .black).setFill()
        shape.fill()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        (skylandTheme["fg"] ?? .white).withAlphaComponent(0.16).setFill()
        let pitch: CGFloat = 12, dot: CGFloat = 1.6
        for y in stride(from: pitch / 2, to: bounds.maxY, by: pitch) {
            for x in stride(from: pitch / 2, to: bounds.maxX, by: pitch) {
                NSBezierPath(ovalIn: NSRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        (skylandTheme["border"] ?? .darkGray).setStroke()
        shape.stroke()
    }
}

/// glyph: the one red dot, on the selection
func glyphDot(in view: NSView, at point: NSPoint) {
    view.subviews.filter { $0.identifier?.rawValue == "glyph-dot" }.forEach { $0.removeFromSuperview() }
    let dot = NSView(frame: NSRect(x: point.x, y: point.y, width: 6, height: 6))
    dot.identifier = NSUserInterfaceItemIdentifier("glyph-dot")
    dot.wantsLayer = true
    dot.layer?.cornerRadius = 3
    dot.layer?.backgroundColor = (skylandTheme["highlight"] ?? .systemRed).cgColor
    view.addSubview(dot)
}

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class Picker: NSObject, NSApplicationDelegate, NSSearchFieldDelegate {
    let thumbSize = NSSize(width: 300, height: 190)
    let spacing: CGFloat = 14
    let rowHeight: CGFloat = 30
    let maxRows = 14 // ponytail: no scrolling in the theme list, past this rows are hidden until searched
    var panel: KeyPanel!
    var blur: NSView! // NSVisualEffectView, or a glass shape (ui-style = 'glass')
    /// glass: skylandbar's look, a lightly tinted panel and a lens on the selection
    var surface: GlassSurface?
    var content: NSView! // theme tint over the blur, holds the views
    var showingThemes = true

    // theme list
    var search: NSSearchField!
    var rows: [NSView] = []
    var shown: [Int] = [] // indices into themes, after search
    var row = 0

    // wallpapers of one theme
    var files: [URL] = []
    var cells: [NSImageView] = []
    var scroll: NSScrollView!
    var selected = 0

    /// resident: SIGUSR1 shows or hides it
    var toggle: DispatchSourceSignal?
    var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if resident {
            let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                if self.panel?.isVisible == true { self.close() } else { self.open() }
            }
            source.resume()
            toggle = source
        }
        open() // started by the key: shown at once
    }

    /// Built again at each opening: the style (metal / glass) and the theme may have changed.
    func open() {
        if resident {
            loadThemes()
            loadColors()
            guard !themes.isEmpty else { return }
        }
        panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .modalPanel // above floating windows raised by skyland
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let glass = uiStyleIsGlass()
        if glyph {
            blur = GlyphPanel()
        } else if glass {
            panel.hasShadow = false // the glass draws its own
            blur = NSView()
            let surface = GlassSurface()
            blur.addSubview(surface)
            self.surface = surface
        } else {
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 24
            effect.layer?.masksToBounds = true
            effect.maskImage = roundedMask(radius: 24)
            blur = effect
        }
        panel.contentView = blur
        content = NSView()
        content.autoresizingMask = [.width, .height]
        content.wantsLayer = true
        content.layer?.cornerRadius = 24
        // metal: the blur stays a hint, gray otherwise; glass: tinted already
        content.layer?.backgroundColor = glass || glyph ? nil : skylandTheme["bg"]?.withAlphaComponent(0.85).cgColor
        content.layer?.borderWidth = skylandTheme.isEmpty || glass || glyph ? 0 : 1 // glass: its own rim
        content.layer?.borderColor = themeAccent.withAlphaComponent(0.35).cgColor
        blur.addSubview(content)
        if let bg = skylandTheme["bg"]?.usingColorSpace(.sRGB) { // the search field and its text follow a light or dark theme
            panel.appearance = NSAppearance(named: bg.brightnessComponent < 0.5 ? .darkAqua : .aqua)
        }

        if keyMonitor == nil { // once: a resident picker opens many times
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.key(event) == true ? nil : event
            }
        }
        if themes.count == 1 { showWallpapers(0) } else { showThemes() }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if showingThemes { panel.makeFirstResponder(search) }
    }

    func resize(_ size: NSSize) {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        panel.setFrame(NSRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
        content.frame = blur.bounds
        if let surface {
            surface.frame = blur.bounds
            surface.panels = [GlassSurface.Shape(rect: blur.bounds, radius: 24, tint: themeAccent.withAlphaComponent(0.08))]
        }
    }

    // MARK: theme list

    func showThemes() {
        showingThemes = true
        content.subviews.forEach { $0.removeFromSuperview() }
        cells = []
        search = NSSearchField()
        search.placeholderString = "theme"
        search.delegate = self
        search.focusRingType = .none
        if glyph { search.font = glyphFont("SpaceMono-Regular", 13); search.placeholderString = "THEME" }
        content.addSubview(search)
        let list = NSView()
        list.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clickedTheme(_:))))
        content.addSubview(list)
        filterThemes()
        panel.makeFirstResponder(search)
    }

    func controlTextDidChange(_ notification: Notification) { filterThemes() }

    func filterThemes() {
        let query = fold(search.stringValue.trimmingCharacters(in: .whitespaces))
        shown = themes.indices.filter { query.isEmpty || fold(themes[$0].name).contains(query) }
        shown = Array(shown.prefix(maxRows))
        let width: CGFloat = 460
        let listHeight = CGFloat(max(shown.count, 1)) * rowHeight
        let height = spacing + 28 + spacing / 2 + listHeight + spacing
        resize(NSSize(width: width, height: height))
        search.frame = NSRect(x: spacing, y: height - spacing - 28, width: width - 2 * spacing, height: 28)
        let list = content.subviews[1]
        list.frame = NSRect(x: spacing, y: spacing, width: width - 2 * spacing, height: listHeight)
        list.subviews.forEach { $0.removeFromSuperview() }
        rows = shown.enumerated().map { position, index in
            let rowView = NSView(frame: NSRect(x: 0, y: listHeight - CGFloat(position + 1) * rowHeight, width: list.frame.width, height: rowHeight))
            rowView.wantsLayer = true
            rowView.layer?.cornerRadius = 14
            let name = NSTextField(labelWithString: themes[index].name)
            name.font = glyph ? glyphFont("SpaceMono-Regular", 14) : .systemFont(ofSize: 15)
            name.textColor = themeFg
            name.frame = NSRect(x: 10, y: 5, width: rowView.frame.width - 80, height: 20)
            let count = NSTextField(labelWithString: "\(themes[index].files.count)")
            count.textColor = themeDim
            count.alignment = .right
            if glyph { count.font = glyphFont("Doto-Black", 17) }
            count.frame = NSRect(x: rowView.frame.width - (glyph ? 84 : 70), y: 5, width: 60, height: 20)
            rowView.addSubview(name)
            rowView.addSubview(count)
            list.addSubview(rowView)
            return rowView
        }
        selectRow(0)
    }

    func selectRow(_ index: Int) {
        row = max(0, min(rows.count - 1, index))
        if let surface, rows.indices.contains(row) { // a lens flows to the row
            blur.layoutSubtreeIfNeeded()
            surface.fluid = true // small rows: the lens flows like a drop
            surface.selection = GlassSurface.Shape(rect: surface.convert(rows[row].bounds, from: rows[row]), radius: 14,
                                                   tint: themeAccent.withAlphaComponent(0.30))
            return
        }
        for (i, rowView) in rows.enumerated() {
            if glyph { // a card, outlined, and the red dot
                rowView.layer?.backgroundColor = i == row ? (skylandTheme["bg_card"] ?? .darkGray).cgColor : nil
                rowView.layer?.borderWidth = i == row ? 1.5 : 0
                rowView.layer?.borderColor = themeFg.withAlphaComponent(0.85).cgColor
                if i == row { glyphDot(in: rowView, at: NSPoint(x: rowView.bounds.width - 6 - 6, y: rowView.bounds.midY - 3)) }
                continue
            }
            rowView.layer?.backgroundColor = i == row ? themeAccent.withAlphaComponent(0.22).cgColor : nil
        }
    }

    @objc func clickedTheme(_ gesture: NSClickGestureRecognizer) {
        let point = gesture.location(in: gesture.view)
        if let index = rows.firstIndex(where: { $0.frame.contains(point) }) { showWallpapers(shown[index]) }
    }

    // MARK: wallpapers

    func showWallpapers(_ theme: Int) {
        showingThemes = false
        files = themes[theme].files
        content.subviews.forEach { $0.removeFromSuperview() }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        // glass: room around the thumbnails for the rim and the lens; as many whole ones as fit,
        // scrolling one by one keeps them whole (none cut at the edge)
        let pad = surface == nil ? spacing : 24, step = thumbSize.width + spacing
        let fit = max(1, ((screen.visibleFrame.width * 0.85 - 2 * pad + spacing) / step).rounded(.down))
        let width = min(fit, CGFloat(files.count)) * step - spacing + 2 * pad
        let height = thumbSize.height + 2 * pad
        resize(NSSize(width: width, height: height))
        panel.makeFirstResponder(nil)

        let strip = NSView(frame: NSRect(x: 0, y: 0, width: CGFloat(files.count) * step - spacing, height: height))
        cells = files.enumerated().map { index, file in
            let cell = NSImageView(frame: NSRect(x: CGFloat(index) * step, y: pad, width: thumbSize.width, height: thumbSize.height))
            cell.imageScaling = .scaleProportionallyUpOrDown
            cell.wantsLayer = true
            cell.layer?.cornerRadius = 16
            cell.layer?.masksToBounds = true
            cell.layer?.backgroundColor = (skylandTheme["bg_card"] ?? .black).withAlphaComponent(0.6).cgColor
            cell.toolTip = file.lastPathComponent
            strip.addSubview(cell)
            DispatchQueue.global(qos: .userInitiated).async {
                let image = thumbnail(file, maxPixels: 600)
                DispatchQueue.main.async { cell.image = image }
            }
            return cell
        }
        scroll = NSScrollView(frame: NSRect(x: pad, y: 0, width: width - 2 * pad, height: height)) // within the pad: the next one never peeks in
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.documentView = strip
        content.addSubview(scroll)
        strip.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked(_:))))
        select(files.firstIndex { $0.path == ProcessInfo.processInfo.environment["SKYLAND_PICKER_SELECTED"] } ?? 0) // current one
    }

    func select(_ index: Int) {
        selected = max(0, min(files.count - 1, index))
        scroll.contentView.scrollToVisible(cells[selected].frame)
        if let surface { // a lens flows under the thumbnail, a glowing frame around it
            let cell = cells[selected]
            surface.fluid = false // big thumbnails: it slides in one piece
            surface.selection = GlassSurface.Shape(rect: surface.convert(cell.bounds, from: cell).insetBy(dx: -6, dy: -6), radius: 22,
                                                   tint: themeAccent.withAlphaComponent(0.30))
            return
        }
        for (i, cell) in cells.enumerated() {
            cell.layer?.borderWidth = i == selected ? (glyph ? 2 : 3) : 0
            cell.layer?.borderColor = (glyph ? themeFg : themeAccent).cgColor
        }
        if glyph { glyphDot(in: cells[selected], at: NSPoint(x: cells[selected].bounds.width - 16, y: cells[selected].bounds.height - 16)) }
    }

    func choose() {
        guard resident else {
            print(files[selected].path)
            exit(0)
        }
        // bin/skyland-wallpaper set: the wallpaper, its colors, the theme (seconds of matugen: not here)
        let set = Process()
        set.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SKYLAND_WALLPAPER_SET"] ?? "/usr/bin/false")
        set.arguments = ["set", files[selected].path]
        try? set.run()
        close()
    }

    /// Cancelled or picked: resident, hidden until the next SIGUSR1; else the process ends.
    func close() {
        guard resident else { exit(1) }
        panel?.orderOut(nil)
        panel = nil
        surface = nil
        cells = []
        rows = []
    }

    @objc func clicked(_ gesture: NSClickGestureRecognizer) {
        let point = gesture.location(in: gesture.view)
        if let index = cells.firstIndex(where: { $0.frame.contains(point) }) {
            selected = index
            choose()
        }
    }

    /// true when handled; unhandled keys go on to the search field
    func key(_ event: NSEvent) -> Bool {
        if showingThemes {
            switch event.keyCode {
                case 53: close() // esc
                case 36, 76: if !shown.isEmpty { showWallpapers(shown[row]) } // return, keypad enter
                case 126: selectRow(row - 1) // up
                case 125: selectRow(row + 1) // down
                default: return false
            }
            return true
        }
        switch event.keyCode {
            case 53: if themes.count > 1 { showThemes() } else { close() } // esc: back to themes
            case 36, 76: choose() // return, keypad enter
            case 123: select(selected - 1) // left
            case 124: select(selected + 1) // right
            default:
                switch event.charactersIgnoringModifiers {
                    case "h": select(selected - 1)
                    case "l": select(selected + 1)
                    case "q": close()
                    default: break
                }
        }
        return true
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Picker()
app.delegate = delegate
app.run()

/// Resizable rounded rect mask for NSVisualEffectView.maskImage: it also shapes the
/// window outline and shadow (layer.cornerRadius alone leaves a square edge around).
func roundedMask(radius: CGFloat) -> NSImage {
    let edge = radius * 2 + 1
    let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
}
