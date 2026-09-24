// 生成应用图标：macOS AppIcon.appiconset 各尺寸 PNG + Windows app_icon.ico。
// 用法（在 flutter_ui/ 目录）：swift tool/render_icon.swift
// 主体占 1024 画布里的 856（和 CGit 一样，量的是程序坞里邻居的实际大小），外圈必须保持透明，否则会比邻居大一圈。
import AppKit

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGColor {
  NSColor(red: red, green: green, blue: blue, alpha: 1).cgColor
}

func render(size: Int) -> Data {
  let canvas = CGFloat(size)
  let image = NSImage(size: NSSize(width: canvas, height: canvas))
  image.lockFocus()
  let context = NSGraphicsContext.current!.cgContext
  context.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))

  let scale = canvas / 1024
  let inset = 84 * scale
  let body = CGRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
  let radius = 192 * scale
  let plate = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

  // 底板：深色竖向渐变 + 投影（和 CTerminal 同一套底板）
  context.saveGState()
  context.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 24 * scale, color: NSColor(white: 0, alpha: 0.35).cgColor)
  context.addPath(plate)
  context.setFillColor(color(0.07, 0.07, 0.08))
  context.fillPath()
  context.restoreGState()

  context.saveGState()
  context.addPath(plate)
  context.clip()
  let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    color(0.16, 0.17, 0.19),
    color(0.07, 0.07, 0.08),
  ] as CFArray, locations: [0, 1])!
  context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
  context.restoreGState()

  // 青色 C 字，开口朝右
  let center = CGPoint(x: 512 * scale, y: 512 * scale)
  context.setStrokeColor(color(0.36, 0.84, 0.86))
  context.setLineWidth(96 * scale)
  context.setLineCap(.round)
  context.addArc(center: center, radius: 240 * scale, startAngle: .pi * 0.28, endAngle: -.pi * 0.28, clockwise: false)
  context.strokePath()

  // 开口里伸出的三行数据，中间一行最长
  context.setFillColor(NSColor(white: 0.85, alpha: 1).cgColor)
  for (index, width) in [150.0, 210.0, 150.0].enumerated() {
    let row = CGRect(x: center.x, y: (580 - CGFloat(index) * 102) * scale, width: CGFloat(width) * scale, height: 44 * scale)
    context.addPath(CGPath(roundedRect: row, cornerWidth: 22 * scale, cornerHeight: 22 * scale, transform: nil))
    context.fillPath()
  }

  image.unlockFocus()
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}

let macDir = "macos/Runner/Assets.xcassets/AppIcon.appiconset"
for size in [16, 32, 64, 128, 256, 512, 1024] {
  try! render(size: size).write(to: URL(fileURLWithPath: "\(macDir)/app_icon_\(size).png"))
}

// ICO：目录项 + 内嵌 PNG（Vista 起支持）
let icoSizes = [16, 24, 32, 48, 64, 128, 256]
let images = icoSizes.map { render(size: $0) }
var ico = Data([0, 0, 1, 0, UInt8(icoSizes.count), 0])
var offset = 6 + 16 * icoSizes.count
for (index, size) in icoSizes.enumerated() {
  let data = images[index]
  let side = UInt8(size == 256 ? 0 : size)
  ico.append(contentsOf: [side, side, 0, 0, 1, 0, 32, 0])
  withUnsafeBytes(of: UInt32(data.count).littleEndian) { ico.append(contentsOf: $0) }
  withUnsafeBytes(of: UInt32(offset).littleEndian) { ico.append(contentsOf: $0) }
  offset += data.count
}
for data in images { ico.append(data) }
try! ico.write(to: URL(fileURLWithPath: "windows/runner/resources/app_icon.ico"))
print("icons written")
