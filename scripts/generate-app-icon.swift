import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

// Run from the project root. Render at each target size in premultiplied sRGB,
// keeping the artwork and rounded outline intact on a larger transparent inset.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let input = root.appendingPathComponent("Resources/IconSource/Todo-original.png")
let source = CGImageSourceCreateWithURL(input as CFURL, nil)!
let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil)!
precondition(artwork.width == artwork.height)
let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
func canvas(_ size: Int) -> CGContext {
    CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
              bytesPerRow: size * 4, space: rgb,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
let size = artwork.width
let analysis = canvas(size)
analysis.draw(artwork, in: CGRect(x: 0, y: 0, width: size, height: size))
let bytes = analysis.data!.assumingMemoryBound(to: UInt8.self)
var minX = size, minY = size, maxX = 0, maxY = 0
for y in 0..<size {
    for x in 0..<size where bytes[y * analysis.bytesPerRow + x * 4 + 3] >= 26 {
        minX = min(minX, x); minY = min(minY, y)
        maxX = max(maxX, x); maxY = max(maxY, y)
    }
}
let inset = min(minX, minY, size - 1 - maxX, size - 1 - maxY) - 3
precondition(inset > 0)
// Ignore isolated almost-transparent pixels well outside the artwork. The
// extra pixels around the measured bounds preserve the original soft edge.
let trimmed = analysis.makeImage()!.cropping(to: CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset))!
for logical in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let side = logical * scale
        let surface = canvas(side)
        surface.interpolationQuality = .high
        let drawSide = CGFloat(side) * 0.90 * CGFloat(trimmed.width) / CGFloat(size)
        let offset = (CGFloat(side) - drawSide) / 2
        surface.draw(trimmed, in: CGRect(x: offset, y: offset, width: drawSide, height: drawSide))
        let catalogName = "icon_\(logical)x\(logical)_\(scale)x.png"
        let iconsetName = "icon_\(logical)x\(logical)\(scale == 2 ? "@2x" : "").png"
        let url = root.appendingPathComponent("Assets.xcassets/AppIcon.appiconset/" + catalogName)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, surface.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(dest))
        try Data(contentsOf: url).write(to: root.appendingPathComponent("Resources/AppIcon.iconset/" + iconsetName), options: .atomic)
    }
}
