// 產生 HAUS Type 的 app icon（1024×1024 PNG）。用法：swift icon/make-icon.swift 輸出.png [blue|ink|white] [條數]，正式版用 blue 5
// 設計：HAUS 標誌的桶形外框（上下弧線往中間收、兩側直線）用一排平頭直線排出來，同時也是聲波。
// 弧線沿用 HAUS 品牌規範：每條弧線的下垂量固定為寬度的 0.0706（取自 HAUS_Element_Lens-Solid 的貝茲曲線）。
// 最外側兩條直線用 HAUS Teal（呼應標誌左右兩條青色直線），其餘用白或藍；直線一律平頭，不用圓角。

import AppKit

let size: CGFloat = 1024
let args = CommandLine.arguments
let out = args.count > 1 ? args[1] : "icon.png"
let variant = args.count > 2 ? args[2] : "blue"
// 直線條數：少一點，小尺寸（16～32 px）才看得出來
let count = args.count > 3 ? Int(args[3])! : 5

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
  NSColor(deviceRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
let hausBlue = rgb(0x004EA2), hausTeal = rgb(0x4CBBB4), hausInk = rgb(0x040000)

// 1. 底：Apple icon 格線，824×824 圓角方形置中
let body = NSRect(x: 100, y: 110, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor(white: 0, alpha: 0.3)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
(variant == "white" ? NSColor.white : variant == "ink" ? hausInk : hausBlue).setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState()
shape.addClip()
switch variant {
case "blue":
  NSGradient(colors: [rgb(0x0a63c2), hausBlue, rgb(0x00326b)], atLocations: [0, 0.5, 1], colorSpace: .deviceRGB)!.draw(in: body, angle: -60)
case "ink":
  NSGradient(colors: [rgb(0x1a1a1a), hausInk], atLocations: [0, 1], colorSpace: .deviceRGB)!.draw(in: body, angle: -90)
default:
  NSGradient(colors: [NSColor.white, rgb(0xeef2f7)], atLocations: [0, 1], colorSpace: .deviceRGB)!.draw(in: body, angle: -90)
}
NSGraphicsContext.restoreGraphicsState()

// 2. HAUS 桶形的上弧線：左半段是貝茲曲線 (0,0)(28.05,8.11)(57.2,12.23)(86.65,12.23)，寬 173.29，右半段鏡射
let lensW = 173.29
func sagAt(_ x: Double) -> Double {  // 回傳該 x 的下垂量（0～12.23），單位同原始 SVG
  let xx = x <= lensW / 2 ? x : lensW - x
  func bx(_ t: Double) -> Double { 3 * pow(1 - t, 2) * t * 28.05 + 3 * (1 - t) * t * t * 57.2 + t * t * t * 86.65 }
  func by(_ t: Double) -> Double { 3 * pow(1 - t, 2) * t * 8.11 + 3 * (1 - t) * t * t * 12.23 + t * t * t * 12.23 }
  var lo = 0.0, hi = 1.0
  for _ in 0..<40 { let mid = (lo + hi) / 2; if bx(mid) < xx { lo = mid } else { hi = mid } }
  return by((lo + hi) / 2)
}

// 3. 直線（預設 5 條），頭尾貼齊桶形左右邊；高度＝桶形在該位置的高度
let drawW: CGFloat = 580          // 桶形寬度（畫面上）
let edgeH: CGFloat = 520          // 兩側最高的直線長度
let scale = Double(drawW) / lensW // 弧線下垂量依寬度等比例縮放，維持 0.0706 的比例
// 條數越少越粗：直線與間距約 1:1.3
let barW: CGFloat = (drawW / (CGFloat(count) * 2.3 - 1.3)).rounded()
let left = body.midX - drawW / 2
for i in 0..<count {
  // 直線中心等距排列：頭尾直線的外緣剛好貼齊桶形左右邊
  let cx = left + barW / 2 + (drawW - barW) * CGFloat(i) / CGFloat(count - 1)
  let sag = CGFloat(sagAt(Double((cx - left) / drawW) * lensW) * scale)
  let h = edgeH - 2 * sag
  let x = cx - barW / 2
  let edge = i == 0 || i == count - 1
  let color: NSColor = edge ? hausTeal : (variant == "white" ? hausBlue : NSColor(white: 1, alpha: 0.97))
  color.setFill()
  NSBezierPath(rect: NSRect(x: x, y: body.midY - h / 2, width: barW, height: h)).fill()
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("已輸出 \(out)")
