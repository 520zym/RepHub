#!/usr/bin/swift
import AppKit

struct IconSize {
    let points: Int
    let name: String
}

let iconSizes = [
    IconSize(points: 16, name: "icon_16x16.png"),
    IconSize(points: 32, name: "icon_16x16@2x.png"),
    IconSize(points: 32, name: "icon_32x32.png"),
    IconSize(points: 64, name: "icon_32x32@2x.png"),
    IconSize(points: 128, name: "icon_128x128.png"),
    IconSize(points: 256, name: "icon_128x128@2x.png"),
    IconSize(points: 256, name: "icon_256x256.png"),
    IconSize(points: 512, name: "icon_256x256@2x.png"),
    IconSize(points: 512, name: "icon_512x512.png"),
    IconSize(points: 1024, name: "icon_512x512@2x.png")
]

guard CommandLine.arguments.count == 3 else {
    fputs("用法：render-app-icon.swift <源 PNG> <iconset 目录>\n", stderr)
    exit(2)
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let iconsetURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
guard let image = NSImage(contentsOf: sourceURL) else {
    fputs("无法读取图标源文件：\(sourceURL.path)\n", stderr)
    exit(1)
}
guard let sourceCGImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fputs("无法读取图标源位图：\(sourceURL.path)\n", stderr)
    exit(1)
}

for iconSize in iconSizes {
    let pixels = iconSize.points
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: .alphaNonpremultiplied,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fputs("无法创建 \(pixels)px 图标位图\n", stderr)
        exit(1)
    }

    guard let context = CGContext(
        data: bitmap.bitmapData,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: bitmap.bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fputs("无法创建 \(pixels)px 图标绘制上下文\n", stderr)
        exit(1)
    }
    context.interpolationQuality = .high
    context.draw(sourceCGImage, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        fputs("无法编码 \(pixels)px 图标位图\n", stderr)
        exit(1)
    }
    try data.write(to: iconsetURL.appendingPathComponent(iconSize.name))
}
