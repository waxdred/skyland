// Renders SkylandLockView to a PNG: preview <out.png> [width height]
// (bin/skyland-lock preview builds it with ../SkylandLock.swift)
import AppKit

let args = CommandLine.arguments
let size = NSSize(width: args.count > 3 ? Double(args[2])! : 1728, height: args.count > 3 ? Double(args[3])! : 1117)
guard let view = SkylandLockView(frame: NSRect(origin: .zero, size: size), isPreview: false) else { exit(1) }
let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
view.cacheDisplay(in: view.bounds, to: rep)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[1]))
