// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Dmytro Udovychenko

// Draws the app icon from code, so the repository carries no binary blob.
// Run by build.sh; writes an .iconset directory that iconutil turns into .icns.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let sizes = [16, 32, 64, 128, 256, 512, 1024]

func makeIcon(size: Int) -> CGImage? {
    let side = CGFloat(size)
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return nil
    }

    // macOS icons sit inside a rounded square with a margin around it.
    let margin = side * 0.08
    let plate = CGRect(x: margin, y: margin, width: side - margin * 2, height: side - margin * 2)
    let radius = plate.width * 0.22

    let platePath = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius,
                           transform: nil)
    context.addPath(platePath)
    context.clip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(colorSpace: colorSpace, components: [0.33, 0.44, 1.00, 1.0])!,
            CGColor(colorSpace: colorSpace, components: [0.16, 0.20, 0.62, 1.0])!,
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: plate.minX, y: plate.maxY),
        end: CGPoint(x: plate.maxX, y: plate.minY),
        options: []
    )
    context.resetClip()

    // A closed laptop, seen head-on: a wide slab with a thin lid seam.
    let bodyWidth = plate.width * 0.62
    let bodyHeight = plate.height * 0.20
    let body = CGRect(
        x: plate.midX - bodyWidth / 2,
        y: plate.midY - plate.height * 0.26,
        width: bodyWidth,
        height: bodyHeight
    )
    context.setFillColor(CGColor(colorSpace: colorSpace, components: [1, 1, 1, 1])!)
    context.addPath(CGPath(roundedRect: body, cornerWidth: bodyHeight * 0.32,
                           cornerHeight: bodyHeight * 0.32, transform: nil))
    context.fillPath()

    // Seam, only where it stays visible.
    if side >= 64 {
        let seam = CGRect(x: body.minX + body.width * 0.12,
                          y: body.midY - side * 0.006,
                          width: body.width * 0.76,
                          height: max(1, side * 0.012))
        context.setFillColor(CGColor(colorSpace: colorSpace, components: [0.16, 0.20, 0.62, 1])!)
        context.fill(seam)
    }

    // Signal arcs rising above the closed lid: still reachable.
    context.setStrokeColor(CGColor(colorSpace: colorSpace, components: [1, 1, 1, 1])!)
    context.setLineCap(.round)
    let center = CGPoint(x: plate.midX, y: body.maxY + plate.height * 0.02)
    for (index, factor) in [0.16, 0.28, 0.40].enumerated() {
        context.setLineWidth(max(1, side * 0.035))
        context.setAlpha(1.0 - Double(index) * 0.22)
        context.addArc(
            center: center,
            radius: plate.width * factor,
            startAngle: .pi / 5,
            endAngle: .pi * 4 / 5,
            clockwise: false
        )
        context.strokePath()
    }
    context.setAlpha(1)

    return context.makeImage()
}

func write(_ image: CGImage, to url: URL) -> Bool {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        return false
    }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
}

// iconset naming: each logical size needs a 1x and the 2x of the size below it.
let names: [Int: [String]] = [
    16: ["icon_16x16.png"],
    32: ["icon_16x16@2x.png", "icon_32x32.png"],
    64: ["icon_32x32@2x.png"],
    128: ["icon_128x128.png"],
    256: ["icon_128x128@2x.png", "icon_256x256.png"],
    512: ["icon_256x256@2x.png", "icon_512x512.png"],
    1024: ["icon_512x512@2x.png"],
]

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
let outputURL = URL(fileURLWithPath: outputPath)
try? FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

for size in sizes {
    guard let image = makeIcon(size: size) else {
        FileHandle.standardError.write("failed to render \(size)px\n".data(using: .utf8)!)
        exit(1)
    }
    for name in names[size] ?? [] {
        if !write(image, to: outputURL.appendingPathComponent(name)) {
            FileHandle.standardError.write("failed to write \(name)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}

print("wrote \(outputPath)")
