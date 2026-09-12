#!/usr/bin/env swift
//
//  Rasterises the app icon from recordito-logo.svg into the AppIcon asset catalog.
//
//  Run from the repository root after changing the logo:
//
//      swift Scripts/make-appicon.swift
//
//  Every slot is rendered straight from the vector at its exact pixel size rather than
//  downsampled from one large bitmap, so the 16 pt icon stays crisp instead of mushy.
//  NSImage decodes SVG natively (as `_NSSVGImageRep`), so this needs no dependencies.
//
import AppKit

let root = FileManager.default.currentDirectoryPath
let source = URL(fileURLWithPath: root).appendingPathComponent("recordito-logo.svg")
let iconSet = URL(fileURLWithPath: root)
    .appendingPathComponent("Recordito/Resources/Assets.xcassets/AppIcon.appiconset")

/// The macOS slots an `AppIcon.appiconset` declares: point size, scale, and the pixels that implies.
let slots: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

guard let image = NSImage(contentsOf: source) else {
    FileHandle.standardError.write(Data("cannot read \(source.path)\n".utf8))
    exit(1)
}

func render(_ image: NSImage, pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [.alphaFirst],
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    NSColor.clear.set()
    NSRect(x: 0, y: 0, width: pixels, height: pixels).fill()
    image.draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
    )
    context.flushGraphics()
    return rep.representation(using: .png, properties: [:])
}

var entries: [String] = []
for slot in slots {
    let pixels = slot.points * slot.scale
    let name = slot.scale == 1
        ? "icon_\(slot.points)x\(slot.points).png"
        : "icon_\(slot.points)x\(slot.points)@\(slot.scale)x.png"
    guard let png = render(image, pixels: pixels) else {
        FileHandle.standardError.write(Data("failed to render \(name)\n".utf8))
        exit(1)
    }
    try png.write(to: iconSet.appendingPathComponent(name))
    print("wrote \(name) (\(pixels)×\(pixels), \(png.count) bytes)")
    entries.append("""
        {
          "filename" : "\(name)",
          "idiom" : "mac",
          "scale" : "\(slot.scale)x",
          "size" : "\(slot.points)x\(slot.points)"
        }
    """)
}

let contents = """
{
  "images" : [
\(entries.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try contents.write(to: iconSet.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote Contents.json")
