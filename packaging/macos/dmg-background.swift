// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

// The dmg window's background (dmg-background.tiff, 1x + 2x), drawn once:
//   swift packaging/macos/dmg-background.swift /tmp/bg &&
//   tiffutil -cathidpicheck /tmp/bg/bg.png /tmp/bg/bg@2x.png -out packaging/macos/dmg-background.tiff
// 600 x 400 pt; scripts/package.sh puts gtty at (150, 190) and
// Applications at (450, 190) (Finder: from the top-left).
import AppKit
func draw(scale: CGFloat, to path: String) {
    let w = 600 * scale, h = 400 * scale
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w), pixelsHigh: Int(h), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 600, height: 400)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(calibratedRed: 0.965, green: 0.965, blue: 0.97, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 600, height: 400).fill()
    // Arrow between the icons (Finder y is from the top: icon centers at y 190 → 210 from bottom).
    let arrow = NSColor(calibratedRed: 0.55, green: 0.58, blue: 0.63, alpha: 1)
    arrow.setStroke(); arrow.setFill()
    let line = NSBezierPath(); line.lineWidth = 6; line.lineCapStyle = .round
    line.move(to: NSPoint(x: 245, y: 210)); line.line(to: NSPoint(x: 340, y: 210)); line.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 362, y: 210)); head.line(to: NSPoint(x: 336, y: 226)); head.line(to: NSPoint(x: 336, y: 194)); head.close(); head.fill()
    let style = NSMutableParagraphStyle(); style.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor(calibratedWhite: 0.35, alpha: 1), .paragraphStyle: style]
    ("Drag gtty to Applications" as NSString).draw(in: NSRect(x: 0, y: 70, width: 600, height: 24), withAttributes: attrs)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
draw(scale: 1, to: CommandLine.arguments[1] + "/bg.png")
draw(scale: 2, to: CommandLine.arguments[1] + "/bg@2x.png")
