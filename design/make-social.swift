// Regenerates the GitHub social preview image.
//
//   swift design/make-social.swift          # writes design/social-preview.png
//
// The card GitHub serves as `og:image` when a link to the repository is pasted
// into Slack, X, Telegram or iMessage. It is not built into the app and not
// referenced by any code: the PNG is uploaded by hand in
// Settings ▸ General ▸ Social preview (GitHub exposes no API for it), so the
// tracked file is the source of truth for the next upload.
//
// The icon is not redrawn here — it is read from the tracked
// `EditMD/EditMD/Resources/AppIcon.icns`, so the card cannot drift from the
// app icon. Regenerate the icon first (`make-appicon.swift`) if it changed.
//
// Run from the repository root (paths are resolved relative to this file).

import AppKit
import Foundation

// MARK: - Style (the one place to retune the look)

enum Style {
    /// GitHub's recommended size. The bottom band is left empty because some
    /// clients crop the card's lower edge.
    static let size = (w: 1280, h: 640)
    static let bottomSafe: CGFloat = 40

    static let backgroundTop = 0xFFFFFF
    static let backgroundBottom = 0xE9E9EE
    static let title = 0x1A1A1A
    static let subtitle = 0x3C3C46
    static let caption = 0x76767F
    /// Hairline frame, the same idea as the icon's edge: the card must not
    /// dissolve into a white chat background.
    static let edge = (0x000000, 0.08)

    static let iconSide: CGFloat = 300
    static let leftMargin: CGFloat = 88
    static let gap: CGFloat = 56            // icon → text column

    static let titleSize: CGFloat = 108
    static let subtitleSize: CGFloat = 42
    static let captionSize: CGFloat = 30

    static let titleText = "EditMD"
    static let subtitleText = "Native macOS Markdown editor"
    static let captionText = "Source · Visual · Preview — one markdown source of truth"
    static let footerText = "dotmd.tools/editmd"
}

// MARK: - Paths (relative to this script)

let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repoRoot = scriptDir.deletingLastPathComponent()
let icnsURL = repoRoot.appendingPathComponent("EditMD/EditMD/Resources/AppIcon.icns")
let outURL = scriptDir.appendingPathComponent("social-preview.png")

guard let icon = NSImage(contentsOf: icnsURL) else { fatalError("cannot load \(icnsURL.path)") }

func rgb(_ hex: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func nsColor(_ hex: Int, _ a: CGFloat = 1) -> NSColor { NSColor(cgColor: rgb(hex, a))! }

// MARK: - Card

let W = CGFloat(Style.size.w), H = CGFloat(Style.size.h)
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: Style.size.w, height: Style.size.h, bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high

let gradient = CGGradient(colorsSpace: cs,
                          colors: [rgb(Style.backgroundTop), rgb(Style.backgroundBottom)] as CFArray,
                          locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])

ctx.setStrokeColor(rgb(Style.edge.0, Style.edge.1))
ctx.setLineWidth(2)
ctx.stroke(CGRect(x: 1, y: 1, width: W - 2, height: H - 2))

// Everything is laid out inside the safe area, then the whole block is centred
// in it — so retuning a font size cannot push the text off balance.
let safeCentreY = Style.bottomSafe + (H - Style.bottomSafe) / 2

let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.current = graphics

let iconRect = NSRect(x: Style.leftMargin, y: safeCentreY - Style.iconSide / 2,
                      width: Style.iconSide, height: Style.iconSide)
icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)

func line(_ text: String, size: CGFloat, weight: NSFont.Weight, color: Int) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: nsColor(color),
    ])
}

let title = line(Style.titleText, size: Style.titleSize, weight: .bold, color: Style.title)
let subtitle = line(Style.subtitleText, size: Style.subtitleSize, weight: .medium,
                    color: Style.subtitle)
let caption = line(Style.captionText, size: Style.captionSize, weight: .regular,
                   color: Style.caption)

// The homepage is the last line of the same block rather than a footer pinned
// to the bottom edge: pinned, it read as a stray caption across an empty band,
// and it is the first thing a cropping client would eat.
let footer = line(Style.footerText, size: Style.captionSize, weight: .regular, color: Style.caption)

let textX = iconRect.maxX + Style.gap
let titleH = title.size().height, subtitleH = subtitle.size().height
let captionH = caption.size().height, footerH = footer.size().height
let leading: CGFloat = 18
let footerLeading: CGFloat = 40
let blockH = titleH + leading + subtitleH + leading + captionH + footerLeading + footerH
var y = safeCentreY + blockH / 2 - titleH

title.draw(at: NSPoint(x: textX, y: y))
y -= leading + subtitleH
subtitle.draw(at: NSPoint(x: textX, y: y))
y -= leading + captionH
caption.draw(at: NSPoint(x: textX, y: y))
y -= footerLeading + footerH
footer.draw(at: NSPoint(x: textX, y: y))

NSGraphicsContext.current = nil

// MARK: - Emit

let image = ctx.makeImage()!
let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
try png.write(to: outURL)
print("wrote \(outURL.path) — \(Style.size.w)×\(Style.size.h), \(png.count / 1024) KB")
