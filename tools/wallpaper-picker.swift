// skyland wallpaper picker, like 43PR's quickshell hyprquickpaper.
//   skyland-wallpaper-picker <dir>     pick an image: prints its path, exit 1 if cancelled
//   skyland-wallpaper-picker --set <file>   set it as wallpaper on every screen
//   skyland-wallpaper-picker --blur <in> <out.jpg> <radius>   blurred copy (lock screen)
// Built by bin/skyland-build; driven by bin/skyland-wallpaper and bin/skyland-lock.
import AppKit
import CoreImage
import ImageIO

let args = CommandLine.arguments
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
guard args.count == 2 else {
    FileHandle.standardError.write("usage: skyland-wallpaper-picker <dir> | --set <file>\n".data(using: .utf8)!)
    exit(2)
}

let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "heic", "gif", "bmp", "tiff"]
let files = ((try? FileManager.default.contentsOfDirectory(atPath: args[1])) ?? [])
    .filter { imageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
    .sorted()
    .map { URL(fileURLWithPath: args[1]).appendingPathComponent($0) }
if files.isEmpty {
    FileHandle.standardError.write("no images in \(args[1])\n".data(using: .utf8)!)
    exit(1)
}

func thumbnail(_ url: URL, maxPixels: Int) -> NSImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceCreateThumbnailWithTransform: true,
              kCGImageSourceThumbnailMaxPixelSize: maxPixels,
          ] as CFDictionary) else { return nil }
    return NSImage(cgImage: image, size: .zero)
}

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class Picker: NSObject, NSApplicationDelegate {
    let thumbSize = NSSize(width: 300, height: 190)
    let spacing: CGFloat = 14
    var panel: KeyPanel!
    var cells: [NSImageView] = []
    var scroll: NSScrollView!
    var selected = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let width = min(screen.visibleFrame.width * 0.85, CGFloat(files.count) * (thumbSize.width + spacing) + spacing)
        let height = thumbSize.height + 2 * spacing
        let frame = NSRect(x: screen.visibleFrame.midX - width / 2, y: screen.visibleFrame.midY - height / 2, width: width, height: height)
        panel = KeyPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        blur.material = .hudWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 14
        blur.layer?.masksToBounds = true
        panel.contentView = blur

        let strip = NSView(frame: NSRect(x: 0, y: 0, width: CGFloat(files.count) * (thumbSize.width + spacing) + spacing, height: height))
        for (index, file) in files.enumerated() {
            let cell = NSImageView(frame: NSRect(x: spacing + CGFloat(index) * (thumbSize.width + spacing), y: spacing, width: thumbSize.width, height: thumbSize.height))
            cell.imageScaling = .scaleProportionallyUpOrDown
            cell.wantsLayer = true
            cell.layer?.cornerRadius = 10
            cell.layer?.masksToBounds = true
            cell.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
            cell.toolTip = file.lastPathComponent
            strip.addSubview(cell)
            cells.append(cell)
            DispatchQueue.global(qos: .userInitiated).async {
                let image = thumbnail(file, maxPixels: 600)
                DispatchQueue.main.async { cell.image = image }
            }
        }
        scroll = NSScrollView(frame: NSRect(origin: .zero, size: frame.size))
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.documentView = strip
        blur.addSubview(scroll)

        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked(_:)))
        strip.addGestureRecognizer(click)

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.key(event)
            return nil
        }
        select(0)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func select(_ index: Int) {
        selected = max(0, min(files.count - 1, index))
        for (i, cell) in cells.enumerated() {
            cell.layer?.borderWidth = i == selected ? 3 : 0
            cell.layer?.borderColor = NSColor.white.cgColor
        }
        scroll.contentView.scrollToVisible(cells[selected].frame.insetBy(dx: -spacing, dy: 0))
    }

    func choose() {
        print(files[selected].path)
        exit(0)
    }

    @objc func clicked(_ gesture: NSClickGestureRecognizer) {
        let point = gesture.location(in: gesture.view)
        if let index = cells.firstIndex(where: { $0.frame.contains(point) }) {
            selected = index
            choose()
        }
    }

    func key(_ event: NSEvent) {
        switch event.keyCode {
            case 53: exit(1) // esc
            case 36, 76: choose() // return, keypad enter
            case 123: select(selected - 1) // left
            case 124: select(selected + 1) // right
            default:
                switch event.charactersIgnoringModifiers {
                    case "h": select(selected - 1)
                    case "l": select(selected + 1)
                    case "q": exit(1)
                    default: break
                }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Picker()
app.delegate = delegate
app.run()
