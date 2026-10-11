// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
let svg = root.appendingPathComponent("tools/icon/AppIcon.svg")
let out = root.appendingPathComponent("Bonsai/Resources/Assets.xcassets/AppIcon.appiconset")
guard let image = NSImage(contentsOf: svg) else { fatalError("cannot load svg") }

var entries: [String] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
        entries.append(
            "    { \"idiom\" : \"mac\", \"size\" : \"\(base)x\(base)\", \"scale\" : \"\(scale)x\", \"filename\" : \"\(name)\" }"
        )
    }
}
let json =
    "{\n  \"images\" : [\n" + entries.joined(separator: ",\n")
    + "\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
try! json.write(to: out.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
