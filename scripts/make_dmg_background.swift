import AppKit
import Foundation

// Renders the installer-window background for Blofeld's DMG, matching the app's
// dark "island" aesthetic (charcoal gradient, white title, amber accent arrow).
//
//   swift make_dmg_background.swift <out.png> <scale>                 # background only
//   swift make_dmg_background.swift <out.png> <scale> --preview <app> # faithful window mock
//
// The --preview mode overlays the real app icon, the Applications folder icon,
// their labels and a faux title bar, so the result looks like the mounted DMG
// without having to build/mount one. Layout constants below are mirrored in
// scripts/dmg_settings.py -- keep the two in sync.

// ---- Layout (must match scripts/dmg_settings.py) ----
let W: CGFloat = 620          // window content width  (points)
let H: CGFloat = 420          // window content height (points)
let iconSize: CGFloat = 128
let leftCenter  = CGPoint(x: 168, y: 270)   // app icon centre   (top-left origin, y down)
let rightCenter = CGPoint(x: 452, y: 270)   // Applications centre
let titleBarH: CGFloat = 28                 // only drawn in --preview

// ---- args ----
let args = CommandLine.arguments
guard args.count >= 3, let scaleD = Double(args[2]) else {
    FileHandle.standardError.write(Data("usage: make_dmg_background.swift <out.png> <scale> [--preview <app>]\n".utf8))
    exit(2)
}
let outPath = args[1]
let scale = CGFloat(scaleD)
var previewApp: String? = nil
if let i = args.firstIndex(of: "--preview"), i + 1 < args.count { previewApp = args[i + 1] }

func col(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}
let amber = col(1.00, 0.60, 0.20)

// top-left rect -> bottom-left NSRect within a `h`-tall canvas
func tl(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ hh: CGFloat, in h: CGFloat) -> NSRect {
    NSRect(x: x, y: h - y - hh, width: w, height: hh)
}
func P(_ x: CGFloat, _ y: CGFloat, in h: CGFloat) -> NSPoint { NSPoint(x: x, y: h - y) }

func attr(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor,
          italic: Bool = false, align: NSTextAlignment = .center) -> NSAttributedString {
    var font = NSFont.systemFont(ofSize: size, weight: weight)
    if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
    let para = NSMutableParagraphStyle(); para.alignment = align
    return NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para])
}

// Run `draw` in a logical width x height bitmap (bottom-left origin) at `scale`x, returns an NSImage.
func render(_ width: CGFloat, _ height: CGFloat, _ draw: (CGFloat) -> Void) -> NSImage {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width * scale, height: height * scale)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.cgContext.scaleBy(x: scale, y: scale)
    draw(height)
    ctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    let img = NSImage(size: NSSize(width: width, height: height))
    img.addRepresentation(rep)
    return img
}

// Background art (gradient + glow + tiles + title + arrow) filling a `h`-tall canvas.
func drawContent(_ h: CGFloat) {
    let g = NSGradient(colors: [col(0.15, 0.15, 0.18), col(0.08, 0.08, 0.10)])!
    g.draw(in: tl(0, 0, W, H, in: h), angle: -90)

    let glow = NSGradient(colors: [amber.withAlphaComponent(0.10), amber.withAlphaComponent(0)])!
    glow.draw(in: NSBezierPath(ovalIn: tl(W/2 - 260, -200, 520, 360, in: h)), relativeCenterPosition: .zero)

    // No backing tiles behind the icons: Finder draws the icon labels itself in a
    // colour that follows the system appearance, and a mid-tone tile destroys their
    // contrast. A plain dark backdrop keeps the (light, in Dark Mode) labels crisp.

    let line1 = NSMutableAttributedString()
    line1.append(attr("To install, ", size: 27, weight: .medium, color: col(1, 1, 1, 0.92)))
    line1.append(attr("drag ", size: 27, weight: .medium, color: col(1, 1, 1, 0.92), italic: true))
    line1.append(attr("Blofeld Supporter", size: 27, weight: .semibold, color: amber))
    let p1 = NSMutableParagraphStyle(); p1.alignment = .center
    line1.addAttribute(.paragraphStyle, value: p1, range: NSRange(location: 0, length: line1.length))
    line1.draw(in: tl(20, 66, W - 40, 40, in: h))
    attr("to Applications", size: 27, weight: .medium, color: col(1, 1, 1, 0.92))
        .draw(in: tl(20, 108, W - 40, 40, in: h))

    let y = leftCenter.y
    let path = NSBezierPath()
    path.lineWidth = 6; path.lineCapStyle = .round; path.lineJoinStyle = .round
    path.move(to: P(258, y + 6, in: h))
    path.curve(to: P(360, y - 4, in: h), controlPoint1: P(292, y + 26, in: h), controlPoint2: P(316, y - 26, in: h))
    amber.setStroke(); path.stroke()
    let tip = P(360, y - 4, in: h)
    let head = NSBezierPath()
    head.lineWidth = 6; head.lineCapStyle = .round; head.lineJoinStyle = .round
    head.move(to: NSPoint(x: tip.x - 16, y: tip.y + 13)); head.line(to: tip); head.line(to: NSPoint(x: tip.x - 18, y: tip.y - 9))
    amber.setStroke(); head.stroke()
}

func writePNG(_ img: NSImage, to path: String) {
    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("failed to encode PNG\n".utf8)); exit(1)
    }
    try? data.write(to: URL(fileURLWithPath: path))
}

let content = render(W, H) { h in drawContent(h) }

if let app = previewApp {
    let h = H + titleBarH
    let mock = render(W, h) { hh in
        // title bar
        col(0.12, 0.12, 0.14).setFill(); NSBezierPath(rect: tl(0, 0, W, titleBarH, in: hh)).fill()
        let lights: [NSColor] = [col(1.00, 0.38, 0.35), col(1.00, 0.74, 0.20), col(0.30, 0.79, 0.30)]
        for (i, c) in lights.enumerated() {
            c.setFill(); NSBezierPath(ovalIn: tl(16 + CGFloat(i) * 20, 9, 12, 12, in: hh)).fill()
        }
        attr("Blofeld Supporter", size: 13, weight: .semibold, color: col(1, 1, 1, 0.55)).draw(in: tl(0, 6, W, 18, in: hh))
        // content below the title bar
        content.draw(in: tl(0, titleBarH, W, H, in: hh), from: .zero, operation: .sourceOver, fraction: 1)
        // real icons + labels
        func drawIcon(_ file: String, at c: CGPoint, label: String) {
            NSWorkspace.shared.icon(forFile: file)
                .draw(in: tl(c.x - iconSize/2, c.y + titleBarH - iconSize/2, iconSize, iconSize, in: hh),
                      from: .zero, operation: .sourceOver, fraction: 1)
            attr(label, size: 13, weight: .regular, color: col(1, 1, 1, 0.92))
                .draw(in: tl(c.x - 90, c.y + titleBarH + 70, 180, 18, in: hh))
        }
        // Finder labels icons by filename; Blofeld.app -> "Blofeld".
        let appLabel = (app as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        drawIcon(app, at: leftCenter, label: appLabel)
        drawIcon("/Applications", at: rightCenter, label: "Applications")
    }
    writePNG(mock, to: outPath)
} else {
    writePNG(content, to: outPath)
}
