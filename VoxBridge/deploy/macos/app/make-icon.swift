import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

func drawIcon(size: Int, name: String) throws {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()
    let shape = NSBezierPath(roundedRect: NSRect(x: 55, y: 55, width: 914, height: 914), xRadius: 204, yRadius: 204)
    let gradient = NSGradient(starting: NSColor(calibratedRed: 0.11, green: 0.40, blue: 0.36, alpha: 1),
                              ending: NSColor(calibratedRed: 0.23, green: 0.60, blue: 0.49, alpha: 1))!
    gradient.draw(in: shape, angle: 50)
    NSColor.white.setFill()
    for (index, height) in [170.0, 300, 460, 340, 200].enumerated() {
        NSBezierPath(roundedRect: NSRect(x: 240 + Double(index) * 105, y: 512 - height / 2,
                                        width: 60, height: height), xRadius: 30, yRadius: 30).fill()
    }
    NSColor(calibratedWhite: 1, alpha: 0.8).setStroke()
    let arc = NSBezierPath()
    arc.lineWidth = 25
    arc.lineCapStyle = .round
    arc.move(to: NSPoint(x: 240, y: 205))
    arc.curve(to: NSPoint(x: 775, y: 265), controlPoint1: NSPoint(x: 430, y: 135), controlPoint2: NSPoint(x: 670, y: 175))
    arc.stroke()
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name))
}

for size in [16, 32, 128, 256, 512] {
    try drawIcon(size: size, name: "icon_\(size)x\(size).png")
    try drawIcon(size: size * 2, name: "icon_\(size)x\(size)@2x.png")
}
