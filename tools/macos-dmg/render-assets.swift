import AppKit

// Finder uses a 760 x 500 point canvas. Preserve 2x pixels in its TIFF.
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
func canvas(_ size: NSSize, pixels: Int, draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels,
        pixelsHigh: Int(CGFloat(pixels) * size.height / size.width), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}
func text(_ string: String, x: CGFloat, top: CGFloat, width: CGFloat, size: CGFloat,
          weight: NSFont.Weight = .regular, tint: UInt32 = 0x183746, center: Bool = false) {
    let style = NSMutableParagraphStyle(); style.alignment = center ? .center : .left
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color(tint), .paragraphStyle: style]
    (string as NSString).draw(in: NSRect(x: x, y: 500 - top - size * 1.6, width: width, height: size * 1.7), withAttributes: attrs)
}
func line(_ points: [NSPoint], tint: UInt32, width: CGFloat) {
    let path = NSBezierPath(); path.move(to: points[0]); points.dropFirst().forEach { path.line(to: $0) }
    path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round
    color(tint).setStroke(); path.stroke()
}
let background = canvas(NSSize(width: 760, height: 500), pixels: 1520) {
    color(0xF3F7FA).setFill(); NSRect(x: 0, y: 0, width: 760, height: 500).fill()
    // A broad continuous path echoes a window crossing from one screen to another.
    let route = NSBezierPath(); route.move(to: NSPoint(x: -80, y: 178))
    route.curve(to: NSPoint(x: 840, y: 350), controlPoint1: NSPoint(x: 180, y: 405), controlPoint2: NSPoint(x: 540, y: 126))
    route.lineWidth = 100; color(0xD4EAF2, 0.4).setStroke(); route.stroke()
    text("Viewflow", x: 48, top: 36, width: 660, size: 34, weight: .semibold)
    text("让窗口与操作，在电脑间自然流动。", x: 50, top: 91, width: 660, size: 17, tint: 0x647F8E)
    // Reserved icon centers: (225, 260), (535, 260) in Finder's top-origin coordinates.
    line([NSPoint(x: 345, y: 238), NSPoint(x: 407, y: 238)], tint: 0x4D91AF, width: 2.5)
    line([NSPoint(x: 398, y: 246), NSPoint(x: 407, y: 238), NSPoint(x: 398, y: 230)], tint: 0x4D91AF, width: 2.5)
    text("拖动 Viewflow 到「应用程序」", x: 50, top: 359, width: 660, size: 20, weight: .medium, center: true)
    text("安装后打开应用，完成权限设置与配对。", x: 50, top: 395, width: 660, size: 14, tint: 0x647F8E, center: true)
    text("适用于 Apple 芯片 Mac", x: 48, top: 463, width: 350, size: 11, tint: 0x8196A2)
    text("macOS 13 或更新版本", x: 504, top: 463, width: 208, size: 11, tint: 0x8196A2)
}
try background.tiffRepresentation!.write(to: output.appendingPathComponent("background.tiff"))
try background.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("background-preview.png"))
let iconset = output.appendingPathComponent("Viewflow.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
func icon(_ pixels: Int) -> NSBitmapImageRep {
    canvas(NSSize(width: 1024, height: 1024), pixels: pixels) {
        let base = NSBezierPath(roundedRect: NSRect(x: 62, y: 62, width: 900, height: 900), xRadius: 205, yRadius: 205)
        NSGradient(starting: color(0x27647D), ending: color(0x123749))!.draw(in: base, angle: 65)
        let rear = NSBezierPath(roundedRect: NSRect(x: 209, y: 384, width: 430, height: 355), xRadius: 43, yRadius: 43)
        color(0xB8DCE8, 0.9).setFill(); rear.fill()
        color(0xEFFAFF, 0.8).setStroke(); rear.lineWidth = 7; rear.stroke()
        let front = NSBezierPath(roundedRect: NSRect(x: 385, y: 264, width: 430, height: 355), xRadius: 43, yRadius: 43)
        color(0xF6FCFE).setFill(); front.fill()
        color(0x87C6D9).setFill(); NSBezierPath(roundedRect: NSRect(x: 422, y: 507, width: 355, height: 72), xRadius: 16, yRadius: 16).fill()
        // The shared horizontal stroke joins the two window planes.
        line([NSPoint(x: 273, y: 462), NSPoint(x: 647, y: 462)], tint: 0x2F829F, width: 24)
        line([NSPoint(x: 608, y: 501), NSPoint(x: 647, y: 462), NSPoint(x: 608, y: 423)], tint: 0x2F829F, width: 24)
    }
}
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try icon(size * scale).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
