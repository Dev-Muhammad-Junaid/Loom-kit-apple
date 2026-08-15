#!/usr/bin/env swift
//
//  make-app-icons.swift
//  Deck Hand
//
//  Regenerates both AppIcon asset catalogs from a single square master image.
//
//  Usage: swift Scripts/make-app-icons.swift <master.png>
//
//  iOS gets the master full-bleed, because the system applies its own mask.
//  macOS ships pre-masked PNGs, so the squircle and the surrounding margin
//  from Apple's icon grid (824 pt of content inside a 1024 pt canvas) have to
//  be baked in here.
//

import AppKit
import SwiftUI

let macContentRatio: CGFloat = 824.0 / 1024.0
let macCornerRatio: CGFloat = 185.4 / 824.0

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-app-icons.swift <master.png>\n".utf8))
    exit(2)
}

let masterURL = URL(fileURLWithPath: CommandLine.arguments[1])
let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()

guard let master = NSImage(contentsOf: masterURL),
      let masterCG = master.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("cannot read master image at \(masterURL.path)\n".utf8))
    exit(1)
}

func context(size: Int) -> CGContext {
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("cannot create \(size)pt context") }
    ctx.interpolationQuality = .high
    return ctx
}

/// Draws the master scaled to fill `rect`, clipped to a continuous-corner
/// rounded rectangle — the same curve SwiftUI draws for `.continuous`, which
/// is what Apple's icon template uses.
func renderMasked(size: Int) -> CGImage {
    let side = CGFloat(size)
    let content = (side * macContentRatio).rounded()
    let origin = ((side - content) / 2).rounded()
    let rect = CGRect(x: origin, y: origin, width: content, height: content)
    let radius = content * macCornerRatio

    let ctx = context(size: size)
    let path = Path(
        roundedRect: rect,
        cornerSize: CGSize(width: radius, height: radius),
        style: .continuous
    )
    ctx.addPath(path.cgPath)
    ctx.clip()
    ctx.draw(masterCG, in: rect)
    return ctx.makeImage()!
}

func renderFullBleed(size: Int) -> CGImage {
    let ctx = context(size: size)
    ctx.draw(masterCG, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("cannot encode \(url.lastPathComponent)")
    }
    try! data.write(to: url)
    print("wrote \(url.path) (\(image.width)px)")
}

func prepare(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
}

let catalogContents = """
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""

// MARK: macOS

let macSet = projectRoot
    .appendingPathComponent("DeckHandMac/Assets.xcassets/AppIcon.appiconset")
prepare(macSet)
try! catalogContents.write(
    to: macSet.deletingLastPathComponent().appendingPathComponent("Contents.json"),
    atomically: true,
    encoding: .utf8
)

let macPixelSizes = [16, 32, 64, 128, 256, 512, 1024]
for px in macPixelSizes {
    write(renderMasked(size: px), to: macSet.appendingPathComponent("icon_\(px).png"))
}

// Each point size is listed at 1x and 2x, so most PNGs are referenced twice.
let macEntries = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
    .map { pt, scale in
        """
            {
              "filename" : "icon_\(pt * scale).png",
              "idiom" : "mac",
              "scale" : "\(scale)x",
              "size" : "\(pt)x\(pt)"
            }
        """
    }
    .joined(separator: ",\n")

try! """
{
  "images" : [
\(macEntries)
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
""".write(to: macSet.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

// MARK: iOS

let iosSet = projectRoot
    .appendingPathComponent("DeckHandiOS/Assets.xcassets/AppIcon.appiconset")
prepare(iosSet)
try! catalogContents.write(
    to: iosSet.deletingLastPathComponent().appendingPathComponent("Contents.json"),
    atomically: true,
    encoding: .utf8
)
write(renderFullBleed(size: 1024), to: iosSet.appendingPathComponent("icon_1024.png"))

try! """
{
  "images" : [
    {
      "filename" : "icon_1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
""".write(to: iosSet.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
