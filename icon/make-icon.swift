// 產生 YuVoice 的 app icon（1024×1024 PNG）。用法：swift icon/make-icon.swift 輸出.png
// 設計：浩室藍漸層的 macOS 圓角方形底，中間一排白色平頭聲波，中央一條用浩室青。
// 聲波用平頭直線，不用圓角條，避免圓角框包圓角框。

import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
  NSColor(deviceRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

// 1. 底：Apple icon 格線，824×824 圓角方形置中，下方留陰影空間
let body = NSRect(x: 100, y: 110, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
rgb(0x003a7a).setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

// 漸層：左上浩室藍 #004EA2 → 右下深藍
NSGraphicsContext.saveGraphicsState()
shape.addClip()
NSGradient(colors: [rgb(0x0a63c2), rgb(0x004ea2), rgb(0x00285a)], atLocations: [0, 0.45, 1], colorSpace: .deviceRGB)!
  .draw(in: body, angle: -55)
// 上緣一點點亮光，讓底不死平
NSGradient(colors: [NSColor(white: 1, alpha: 0.10), NSColor(white: 1, alpha: 0)])!
  .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// 2. 聲波：13 條，高度呈中間高、兩側低的起伏
let heights: [CGFloat] = [0.16, 0.30, 0.22, 0.46, 0.34, 0.62, 0.86, 0.62, 0.34, 0.46, 0.22, 0.30, 0.16]
let barW: CGFloat = 30
let gap: CGFloat = 18
let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
let maxH: CGFloat = 520
var x = body.midX - total / 2
for (i, h) in heights.enumerated() {
  let bh = maxH * h
  let r = NSRect(x: x, y: body.midY - bh / 2, width: barW, height: bh)
  (i == heights.count / 2 ? rgb(0x45bdb4) : NSColor(white: 1, alpha: 0.96)).setFill()
  NSBezierPath(rect: r).fill()
  x += barW + gap
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("已輸出 \(out)")
