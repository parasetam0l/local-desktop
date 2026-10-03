#!/usr/bin/env swift
//
// Draws the installer DMG's window background:
// Packaging/dmg/background.png and background@2x.png.
//
// Usage: swift Scripts/dmg-background.swift
//
// The icon positions must match icon_locations in Packaging/dmg/settings.py.
// Finder shows the top 400 points under the title bar; the image is taller so
// that no edge shows below it. Text stays above y = 350: Finder's path and
// status bars, when the user has turned them on, cover the bottom.
// Finder draws the icon labels in black in light mode and in white in dark
// mode, so the area behind them stays a mid-tone that both can be read on.
//
// The motif follows the app icon: a glowing trail carries the screen from one
// device to the other, here from the app to the Applications folder, over a
// faint pixel grid.

import AppKit

let canvasSize = CGSize(width: 660, height: 420)
let appCenter = CGPoint(x: 170, y: 200)
let applicationsCenter = CGPoint(x: 490, y: 200)

let outputDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("../Packaging/dmg")
    .standardizedFileURL
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [red, green, blue, alpha])!
}

let navy = (0.04, 0.09, 0.22)
let cyan = (0.42, 0.90, 1.0)

func linearGradient(_ context: CGContext, _ colors: [CGColor], from start: CGPoint, to end: CGPoint) {
    let gradient = CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: start, end: end,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func radialGlow(_ context: CGContext, at center: CGPoint, radius: CGFloat, color: CGColor) {
    let gradient = CGGradient(colorsSpace: sRGB, colors: [color, color.copy(alpha: 0)!] as CFArray, locations: nil)!
    context.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: radius, options: [])
}

func drawText(_ text: String, font: NSFont, alpha: CGFloat, top: CGFloat) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(srgbRed: 0.02, green: 0.06, blue: 0.16, alpha: 0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -1)
    shadow.shadowBlurRadius = 3
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha),
        .paragraphStyle: paragraph,
        .shadow: shadow,
    ]
    NSAttributedString(string: text, attributes: attributes)
        .draw(in: CGRect(x: 0, y: top, width: canvasSize.width, height: font.pointSize * 1.6))
}

/// Point on a cubic Bézier curve.
func bezier(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
    let u = 1 - t
    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
    return CGPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x,
                   y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
}

/// A four-pointed glint, like the sparkles along the icon's trail.
func glint(_ context: CGContext, at center: CGPoint, size: CGFloat, alpha: CGFloat) {
    radialGlow(context, at: center, radius: size * 2.2, color: rgb(cyan.0, cyan.1, cyan.2, 0.35 * alpha))
    context.saveGState()
    context.translateBy(x: center.x, y: center.y)
    context.beginPath()
    context.move(to: CGPoint(x: 0, y: -size))
    context.addQuadCurve(to: CGPoint(x: size, y: 0), control: .zero)
    context.addQuadCurve(to: CGPoint(x: 0, y: size), control: .zero)
    context.addQuadCurve(to: CGPoint(x: -size, y: 0), control: .zero)
    context.addQuadCurve(to: CGPoint(x: 0, y: -size), control: .zero)
    context.setFillColor(rgb(1, 1, 1, alpha))
    context.fillPath()
    context.restoreGState()
}

func draw(_ context: CGContext) {
    let width = canvasSize.width
    let height = canvasSize.height

    // Base: a bright, even blue, a little lighter to the lower right.
    linearGradient(context, [rgb(0.13, 0.40, 0.80), rgb(0.18, 0.55, 0.93)],
                   from: CGPoint(x: 0, y: 0), to: CGPoint(x: width, y: height))
    // Navy behind the title, as on the icon, and a soft vignette at the bottom.
    linearGradient(context, [rgb(navy.0, navy.1, navy.2, 0.85), rgb(navy.0, navy.1, navy.2, 0)],
                   from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: 140))
    linearGradient(context, [rgb(navy.0, navy.1, navy.2, 0), rgb(navy.0, navy.1, navy.2, 0.35)],
                   from: CGPoint(x: 0, y: 320), to: CGPoint(x: 0, y: height))

    // A faint pixel grid, strongest in the middle and fading to the edges.
    context.saveGState()
    let spacing: CGFloat = 14
    for y in stride(from: spacing / 2, to: height, by: spacing) {
        for x in stride(from: spacing / 2, to: width, by: spacing) {
            let dx = (x - width / 2) / (width / 2)
            let dy = (y - 230) / 220
            let fade = max(0, 1 - (dx * dx + dy * dy))
            guard fade > 0.02 else { continue }
            context.setFillColor(rgb(1, 1, 1, 0.07 * fade))
            context.fillEllipse(in: CGRect(x: x - 0.9, y: y - 0.9, width: 1.8, height: 1.8))
        }
    }
    context.restoreGState()

    // Soft light behind both icons.
    radialGlow(context, at: appCenter, radius: 120, color: rgb(cyan.0, cyan.1, cyan.2, 0.22))
    radialGlow(context, at: applicationsCenter, radius: 120, color: rgb(0.55, 0.80, 1.0, 0.20))

    // The trail: an arc from the app over to the Applications folder.
    let start = CGPoint(x: appCenter.x + 82, y: appCenter.y + 6)
    let end = CGPoint(x: applicationsCenter.x - 86, y: applicationsCenter.y + 2)
    let control1 = CGPoint(x: start.x + 40, y: appCenter.y - 78)
    let control2 = CGPoint(x: end.x - 48, y: applicationsCenter.y - 78)
    let trail = CGMutablePath()
    trail.move(to: start)
    trail.addCurve(to: end, control1: control1, control2: control2)

    context.saveGState()
    context.setLineCap(.round)
    context.addPath(trail)
    context.setStrokeColor(rgb(cyan.0, cyan.1, cyan.2, 0.18))
    context.setLineWidth(16)
    context.setShadow(offset: .zero, blur: 18, color: rgb(cyan.0, cyan.1, cyan.2, 0.6))
    context.strokePath()
    context.addPath(trail)
    context.setStrokeColor(rgb(cyan.0, cyan.1, cyan.2, 0.55))
    context.setLineWidth(5)
    context.setShadow(offset: .zero, blur: 6, color: rgb(cyan.0, cyan.1, cyan.2, 0.9))
    context.strokePath()
    context.addPath(trail)
    context.setStrokeColor(rgb(1, 1, 1, 0.95))
    context.setLineWidth(2)
    context.setShadow(offset: .zero, blur: 0, color: nil)
    context.strokePath()
    context.restoreGState()

    // Arrowhead along the curve's direction at its end.
    let tangent = CGPoint(x: end.x - control2.x, y: end.y - control2.y)
    let length = hypot(tangent.x, tangent.y)
    let direction = CGPoint(x: tangent.x / length, y: tangent.y / length)
    let normal = CGPoint(x: -direction.y, y: direction.x)
    let tip = CGPoint(x: end.x + direction.x * 6, y: end.y + direction.y * 6)
    let back: CGFloat = 15, spread: CGFloat = 10
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: 1), blur: 8, color: rgb(cyan.0, cyan.1, cyan.2, 0.9))
    context.setStrokeColor(rgb(1, 1, 1, 0.97))
    context.setLineWidth(4)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.beginPath()
    context.move(to: CGPoint(x: tip.x - direction.x * back + normal.x * spread,
                             y: tip.y - direction.y * back + normal.y * spread))
    context.addLine(to: tip)
    context.addLine(to: CGPoint(x: tip.x - direction.x * back - normal.x * spread,
                                y: tip.y - direction.y * back - normal.y * spread))
    context.strokePath()
    context.restoreGState()

    // Glints riding the trail, brighter towards the destination.
    for (t, size) in [(0.22, 3.0), (0.5, 4.5), (0.74, 3.5)] as [(CGFloat, CGFloat)] {
        glint(context, at: bezier(start, control1, control2, end, t), size: size, alpha: 0.55 + 0.4 * t)
    }

    drawText("Drag LocalDesktop to Applications", font: .systemFont(ofSize: 22, weight: .semibold), alpha: 1, top: 38)
    drawText("Then open it from Applications: the Setup Assistant walks you through the rest.",
             font: .systemFont(ofSize: 12.5), alpha: 0.82, top: 74)
    drawText("Requires macOS 14 or later",
             font: .systemFont(ofSize: 11), alpha: 0.7, top: 330)
}

func render(scale: CGFloat) -> Data {
    let context = CGContext(
        data: nil,
        width: Int(canvasSize.width * scale), height: Int(canvasSize.height * scale),
        bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // Top-left origin, as Finder's icon positions.
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: 0, y: canvasSize.height)
    context.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    draw(context)
    NSGraphicsContext.current = nil

    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
    bitmap.size = canvasSize // 72 dpi, 144 dpi at 2x
    return bitmap.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
for (scale, name) in [(CGFloat(1), "background.png"), (2, "background@2x.png")] {
    let url = outputDirectory.appendingPathComponent(name)
    try render(scale: scale).write(to: url)
    print("Wrote \(url.path)")
}
