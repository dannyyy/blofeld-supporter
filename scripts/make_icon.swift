#!/usr/bin/env swift
// Renders an .iconset from the black-on-transparent Blofeld emblem:
// a dark rounded-rect backdrop with the emblem tinted near-white, so the icon
// is visible in Finder/Dock while matching the app's dark "island" aesthetic.
//
// Usage: swift make_icon.swift <source.png> <output.iconset-dir>

import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: make_icon.swift <source.png> <iconset-dir>\n".utf8))
    exit(1)
}
let sourcePath = args[1]
let outDir = args[2]

guard let emblem = NSImage(contentsOfFile: sourcePath) else {
    FileHandle.standardError.write(Data("cannot load \(sourcePath)\n".utf8))
    exit(1)
}

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func renderIcon(pixels: Int) -> NSBitmapImageRep {
    let size = NSSize(width: pixels, height: pixels)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let inset = CGFloat(pixels) * 0.08
    let rect = NSRect(x: inset, y: inset,
                      width: CGFloat(pixels) - inset * 2,
                      height: CGFloat(pixels) - inset * 2)
    let radius = rect.width * 0.225

    // Dark gradient backdrop
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.17, green: 0.17, blue: 0.19, alpha: 1.0),
        NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.10, alpha: 1.0)
    ])!
    gradient.draw(in: path, angle: -90)

    // Subtle top highlight stroke
    NSColor(white: 1.0, alpha: 0.06).setStroke()
    path.lineWidth = max(1, CGFloat(pixels) * 0.004)
    path.stroke()

    // Emblem, tinted near-white, centered with padding
    let emblemSize = rect.width * 0.70
    let emblemRect = NSRect(
        x: rect.midX - emblemSize / 2,
        y: rect.midY - emblemSize / 2,
        width: emblemSize, height: emblemSize)

    let tinted = NSImage(size: emblemRect.size)
    tinted.lockFocus()
    NSColor(white: 0.96, alpha: 1.0).set()
    NSRect(origin: .zero, size: emblemRect.size).fill()
    emblem.draw(in: NSRect(origin: .zero, size: emblemRect.size),
                from: NSRect(origin: .zero, size: emblem.size),
                operation: .destinationIn, fraction: 1.0)
    tinted.unlockFocus()
    tinted.draw(in: emblemRect, from: NSRect(origin: .zero, size: emblemRect.size),
                operation: .sourceOver, fraction: 1.0)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, to name: String) {
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
}

// Standard macOS iconset sizes
let entries: [(point: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2),
    (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)
]
for e in entries {
    let pixels = e.point * e.scale
    let rep = renderIcon(pixels: pixels)
    let suffix = e.scale == 2 ? "@2x" : ""
    write(rep, to: "icon_\(e.point)x\(e.point)\(suffix).png")
}
print("iconset written to \(outDir)")
