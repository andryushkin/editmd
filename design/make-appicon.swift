// Regenerates the app icon from design/AppIcon.svg.
//
//   swift design/make-appicon.swift          # writes design/build/ + the .icns
//
// Composes the ".md" glyph (design/AppIcon.svg, a black wordmark on a
// transparent square) onto the standard macOS Big Sur icon plate — a
// continuous rounded square with a contact shadow — and slices a full
// .iconset, which iconutil packs into EditMD/EditMD/Resources/AppIcon.icns.
// No external dependencies: NSImage rasterizes the SVG, CoreGraphics draws
// the plate. The plate is intentionally light; edit `Style` below to retune.
//
// Run from the repository root (paths are resolved relative to this file).

import AppKit
import Foundation

// MARK: - Style (the one place to retune the look)

enum Style {
    static let plateTop = 0xFFFFFF          // gradient top
    static let plateBottom = 0xE9E9EE       // gradient bottom
    static let edge = (0x000000, 0.06)      // hairline so a white plate reads on a white dock
    static let glyph = 0x1A1A1A             // glyph fill
    static let glyphWidthFraction: CGFloat = 0.83   // of the plate body
    static let shadow = (0x000000, 0.24)
}

// MARK: - Paths (relative to this script)

let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repoRoot = scriptDir.deletingLastPathComponent()
let svgURL = scriptDir.appendingPathComponent("AppIcon.svg")
let buildDir = scriptDir.appendingPathComponent("build")
let icnsURL = repoRoot.appendingPathComponent("EditMD/EditMD/Resources/AppIcon.icns")

guard let glyphNS = NSImage(contentsOf: svgURL) else { fatalError("cannot load \(svgURL.path)") }

func rgb(_ hex: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

// MARK: - Glyph (tight-cropped once, then tinted per draw)

func tightGlyph() -> CGImage {
    let S = 2048, cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.current = ns
    glyphNS.draw(in: NSRect(x: 0, y: 0, width: S, height: S), from: .zero,
                 operation: .sourceOver, fraction: 1)
    NSGraphicsContext.current = nil
    let full = ctx.makeImage()!
    let px = ctx.data!.bindMemory(to: UInt8.self, capacity: S * S * 4)
    var minX = S, minY = S, maxX = -1, maxY = -1
    for y in 0..<S { for x in 0..<S where px[(y * S + x) * 4 + 3] > 10 {
        if x < minX { minX = x }; if x > maxX { maxX = x }
        if y < minY { minY = y }; if y > maxY { maxY = y }
    } }
    // The bitmap's first memory row is the image's top row, so the scan's
    // (minX, minY) is already the top-left of the tight box — crop directly.
    // (A Y-flip here silently miscrops any glyph that is not vertically
    // centered: it clipped this wordmark's "d" ascender into an "a".)
    return full.cropping(to: CGRect(x: minX, y: minY,
                                    width: maxX - minX + 1, height: maxY - minY + 1))!
}
let glyph = tightGlyph()
let glyphAspect = CGFloat(glyph.width) / CGFloat(glyph.height)

func coloredGlyph(w: Int, h: Int, color: CGColor) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: max(1, w), height: max(1, h), bitsPerComponent: 8,
        bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setFillColor(color); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setBlendMode(.destinationIn)
    ctx.draw(glyph, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}

// MARK: - Icon composition

/// Big Sur macOS grid on a `C`×`C` canvas: body 824/1024 centered, continuous
/// corner ~185, contact shadow below, glyph centered at a fraction of the body.
func renderIcon(_ C: Int) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: C, height: C, bitsPerComponent: 8, bytesPerRow: 0,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let k = CGFloat(C) / 1024.0
    let body: CGFloat = 824 * k, margin = (CGFloat(C) - body) / 2, radius = 185.4 * k
    let plate = CGRect(x: margin, y: margin, width: body, height: body)
    let path = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 22 * k,
                  color: rgb(Style.shadow.0, Style.shadow.1))
    ctx.addPath(path); ctx.setFillColor(rgb(Style.plateBottom)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    let grad = CGGradient(colorsSpace: cs,
                          colors: [rgb(Style.plateTop), rgb(Style.plateBottom)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: plate.maxY),
                           end: CGPoint(x: 0, y: plate.minY), options: [])
    ctx.restoreGState()

    ctx.addPath(path)
    ctx.setStrokeColor(rgb(Style.edge.0, Style.edge.1))
    ctx.setLineWidth(max(1, 1.5 * k)); ctx.strokePath()

    let gw = body * Style.glyphWidthFraction, gh = gw / glyphAspect
    let gimg = coloredGlyph(w: Int(gw.rounded()), h: Int(gh.rounded()), color: rgb(Style.glyph))
    ctx.draw(gimg, in: CGRect(x: (CGFloat(C) - gw) / 2, y: (CGFloat(C) - gh) / 2,
                              width: gw, height: gh))
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, _ url: URL) {
    try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: url)
}

// MARK: - Emit iconset + icns

let fm = FileManager.default
try? fm.removeItem(at: buildDir)
let iconset = buildDir.appendingPathComponent("AppIcon.iconset")
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let specs: [(Int, String)] = [
    (16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
    (128, "128x128"), (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"),
    (512, "512x512"), (1024, "512x512@2x"),
]
for (px, name) in specs {
    writePNG(renderIcon(px), iconset.appendingPathComponent("icon_\(name).png"))
}

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconset.path, "-o", icnsURL.path]
try! proc.run(); proc.waitUntilExit()
guard proc.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote \(icnsURL.path)")
print("iconset kept at \(iconset.path)")
