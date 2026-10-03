#!/usr/bin/env swift
//
// Draws the installer DMG's window background:
// Packaging/dmg/background.png and background@2x.png.
//
// Usage: swift Scripts/dmg-background.swift
//
// The icon positions must match icon_locations in Packaging/dmg/settings.py.
// Finder shows the top 400 points under the title bar (32 points on macOS
// 26, 28 before); the image is taller so that no edge shows below it. Text
// stays above y = 350: Finder's path and status bars, when the user has
// turned them on, cover the bottom.
// Finder draws the icon labels in black in light mode and in white in dark
// mode, so the area behind them stays a mid-tone that both can be read on.

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

let navy = (0.03, 0.05, 0.14)
let cyan = rgb(0.12, 0.82, 1.0, 0.30)
let violet = rgb(0.30, 0.62, 1.0, 0.28)

func linearGradient(_ context: CGContext, _ colors: [CGColor], from start: CGPoint, to end: CGPoint) {
    let gradient = CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: start, end: end,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func glow(_ context: CGContext, at center: CGPoint, radius: CGFloat, color: CGColor) {
    let gradient = CGGradient(colorsSpace: sRGB, colors: [color, color.copy(alpha: 0)!] as CFArray, locations: nil)!
    context.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: radius, options: [])
}

func drawText(_ text: String, font: NSFont, alpha: CGFloat, top: CGFloat) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha),
        .paragraphStyle: paragraph,
    ]
    NSAttributedString(string: text, attributes: attributes)
        .draw(in: CGRect(x: 0, y: top, width: canvasSize.width, height: font.pointSize * 1.6))
}

func draw(_ context: CGContext) {
    let width = canvasSize.width

    // Deep navy to blue, like the app icon, dark navy behind the title.
    linearGradient(context, [rgb(0.07, 0.20, 0.42), rgb(0.10, 0.36, 0.70)],
                   from: CGPoint(x: 0, y: 0), to: CGPoint(x: width, y: 0))
    linearGradient(context, [rgb(navy.0, navy.1, navy.2, 0.92), rgb(navy.0, navy.1, navy.2, 0)],
                   from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: 150))
    linearGradient(context, [rgb(navy.0, navy.1, navy.2, 0), rgb(navy.0, navy.1, navy.2, 0.45)],
                   from: CGPoint(x: 0, y: 330), to: CGPoint(x: 0, y: 400))
    glow(context, at: appCenter, radius: 125, color: cyan)
    glow(context, at: applicationsCenter, radius: 125, color: violet)

    // Light trails, like the one between the Mac and the iPhone on the icon,
    // kept above the labels.
    let waves: [(amplitude: CGFloat, period: CGFloat, phase: CGFloat, alpha: CGFloat)] = [
        (22, 330, 0.0, 0.13), (30, 470, 1.9, 0.08), (14, 250, 3.6, 0.06),
    ]
    context.setLineWidth(1.5)
    for wave in waves {
        context.beginPath()
        for x in stride(from: CGFloat(0), through: width, by: 2) {
            let point = CGPoint(x: x, y: appCenter.y + wave.amplitude * sin(2 * .pi * x / wave.period + wave.phase))
            if x == 0 { context.move(to: point) } else { context.addLine(to: point) }
        }
        context.setStrokeColor(rgb(1, 1, 1, wave.alpha))
        context.strokePath()
    }
    let first = waves[0]
    for x in [40.0, 95.0, 565.0, 620.0] as [CGFloat] {
        let y = appCenter.y + first.amplitude * sin(2 * .pi * x / first.period + first.phase)
        glow(context, at: CGPoint(x: x, y: y), radius: 9, color: rgb(1, 1, 1, 0.35))
        context.setFillColor(rgb(1, 1, 1, 0.75))
        context.fillEllipse(in: CGRect(x: x - 2.5, y: y - 2.5, width: 5, height: 5))
    }

    // Arrow: dots growing brighter towards a chevron.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: 2), blur: 8, color: rgb(0, 0, 0, 0.30))
    let y = appCenter.y
    let dots = stride(from: CGFloat(270), through: 366, by: 16).map { $0 }
    for (index, x) in dots.enumerated() {
        let alpha = 0.35 + 0.6 * CGFloat(index) / CGFloat(dots.count - 1)
        context.setFillColor(rgb(1, 1, 1, alpha))
        context.fillEllipse(in: CGRect(x: x - 3.5, y: y - 3.5, width: 7, height: 7))
    }
    context.setStrokeColor(rgb(1, 1, 1, 0.97))
    context.setLineWidth(6)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.beginPath()
    context.move(to: CGPoint(x: 382, y: y - 15))
    context.addLine(to: CGPoint(x: 397, y: y))
    context.addLine(to: CGPoint(x: 382, y: y + 15))
    context.strokePath()
    context.restoreGState()

    drawText("Drag Local Desktop Host to Applications", font: .systemFont(ofSize: 22, weight: .semibold), alpha: 1, top: 38)
    drawText("Then open it from Applications: the Setup Assistant walks you through the rest.",
             font: .systemFont(ofSize: 12.5), alpha: 0.75, top: 74)
    drawText("Requires macOS 14 or later",
             font: .systemFont(ofSize: 11), alpha: 0.6, top: 330)
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
