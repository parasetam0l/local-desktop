#!/usr/bin/env swift
//
// Builds the Mac app icon set (Host/Assets.xcassets/AppIcon.appiconset) from
// the 1024×1024 artwork in Packaging/icon/artwork-1024.png.
//
// The artwork is an opaque square: a rounded tile on a dark surround. Mac
// icons need transparent corners, and macOS 26 and later put icons that don't
// fill the standard rounded square on a plate of their own. So the tile is
// cut out, scaled to Apple's icon grid (an 824-point tile on the 1024 canvas)
// and given the usual soft shadow; everything outside it is transparent.
//
// Usage: swift Scripts/mac-app-icon.swift

import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("..").standardizedFileURL
let source = root.appendingPathComponent("Packaging/icon/artwork-1024.png")
let iconSet = root.appendingPathComponent("Host/Assets.xcassets/AppIcon.appiconset")

/// The tile's outer edge in the artwork, in pixels (its light rim is at 131).
let artworkTile = CGRect(x: 128, y: 128, width: 768, height: 768)
/// Apple's macOS icon grid.
let grid = CGRect(x: 100, y: 100, width: 824, height: 824)
let cornerRadius: CGFloat = 185

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func makeContext(_ size: Int) -> CGContext {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    return context
}

func renderMaster(artwork: CGImage) -> CGImage {
    let context = makeContext(1024)
    let tile = CGPath(roundedRect: grid, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    // Shadow under the tile (CoreGraphics' y axis points up).
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24,
                      color: CGColor(colorSpace: sRGB, components: [0, 0, 0, 0.35])!)
    context.addPath(tile)
    context.setFillColor(CGColor(colorSpace: sRGB, components: [0, 0, 0, 1])!)
    context.fillPath()
    context.restoreGState()

    // The artwork's tile, scaled onto the grid and clipped to it.
    let scale = grid.width / artworkTile.width
    let artworkSize = CGFloat(artwork.width)
    context.saveGState()
    context.addPath(tile)
    context.clip()
    context.draw(artwork, in: CGRect(x: grid.minX - artworkTile.minX * scale,
                                     y: grid.minY - (artworkSize - artworkTile.maxY) * scale,
                                     width: artworkSize * scale, height: artworkSize * scale))
    context.restoreGState()
    return context.makeImage()!
}

func resized(_ image: CGImage, to size: Int) -> CGImage {
    let context = makeContext(size)
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return context.makeImage()!
}

guard let data = try? Data(contentsOf: source),
      let artwork = NSBitmapImageRep(data: data)?.cgImage else {
    fatalError("Can't read \(source.path)")
}
let master = renderMaster(artwork: artwork)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)@\(scale)x.png"
        let png = NSBitmapImageRep(cgImage: resized(master, to: points * scale)).representation(using: .png, properties: [:])!
        try png.write(to: iconSet.appendingPathComponent(name))
        print("Wrote \(name)")
    }
}
