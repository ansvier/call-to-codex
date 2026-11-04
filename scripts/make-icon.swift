import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(calibratedRed: r, green: g, blue: b, alpha: 1) }
func drawIcon(size: Int) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let outer = NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 205, yRadius: 205)
    let gradient = NSGradient(starting: color(0.40, 0.39, 0.51), ending: color(0.10, 0.10, 0.17))!
    gradient.draw(in: outer, angle: -90)
    color(0.64, 0.63, 0.73).setStroke(); outer.lineWidth = 7; outer.stroke()
    color(0.03, 0.055, 0.035).setFill()
    let display = NSBezierPath(roundedRect: NSRect(x: 138, y: 238, width: 748, height: 548), xRadius: 35, yRadius: 35)
    display.fill(); color(0.52, 0.52, 0.62).setStroke(); display.lineWidth = 7; display.stroke()
    for index in 0..<15 {
        color(0.20, 0.21, 0.29).setFill()
        NSRect(x: 155 + index * 48, y: 838, width: 32, height: 7).fill()
    }
    let heights: [CGFloat] = [62, 112, 190, 304, 392, 276, 160, 98, 220, 330, 240, 130, 76]
    for (index, height) in heights.enumerated() {
        let x = CGFloat(183 + index * 51)
        for y in stride(from: CGFloat(314), through: 314 + height, by: 25) {
            color(0.61, 0.94, 0.28).setFill()
            NSRect(x: x, y: y, width: 35, height: 16).fill()
        }
    }
    let metal = NSGradient(starting: color(0.82, 0.82, 0.87), ending: color(0.44, 0.43, 0.55))!
    for x in [CGFloat(160), CGFloat(405), CGFloat(650)] {
        metal.draw(in: NSBezierPath(rect: NSRect(x: x, y: 124, width: 210, height: 64)), angle: -90)
    }
    color(0.68, 0.05, 0.06).setFill()
    NSBezierPath(ovalIn: NSRect(x: 245, y: 139, width: 34, height: 34)).fill()
    color(0.18, 0.18, 0.26).setFill()
    NSRect(x: 494, y: 140, width: 32, height: 32).fill()
    let triangle = NSBezierPath()
    triangle.move(to: NSPoint(x: 743, y: 137)); triangle.line(to: NSPoint(x: 743, y: 175)); triangle.line(to: NSPoint(x: 777, y: 156)); triangle.close(); triangle.fill()
    NSGraphicsContext.restoreGraphicsState()
    let data = bitmap.representation(using: .png, properties: [:])!
    let names: [Int: [String]] = [16: ["icon_16x16.png"], 32: ["icon_16x16@2x.png", "icon_32x32.png"],
        64: ["icon_32x32@2x.png"], 128: ["icon_128x128.png"], 256: ["icon_128x128@2x.png", "icon_256x256.png"],
        512: ["icon_256x256@2x.png", "icon_512x512.png"], 1024: ["icon_512x512@2x.png"]]
    for name in names[size] ?? [] { try data.write(to: output.appendingPathComponent(name)) }
}
for size in [16, 32, 64, 128, 256, 512, 1024] { try drawIcon(size: size) }
