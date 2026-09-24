// Renders the app icon: usage `swift scripts/make-icon.swift out.icns [preview.png]`
// Draws a first-generation Siri Remote with the same proportions as the app.
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.icns"
let preview = CommandLine.arguments.dropFirst(2).first
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("TVRemote.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func gray(_ white: CGFloat) -> NSColor { NSColor(white: white, alpha: 1) }

func drawRemote() {
    // Same layout constants as Theme in RemoteView.swift, in points.
    let width: CGFloat = 240, height: CGFloat = 700, corner: CGFloat = 46
    let glass: CGFloat = 290, button: CGFloat = 70, row: CGFloat = 88
    let left = width * 0.3, right = width * 0.7, firstRow = glass + 62

    let body = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: height),
                            xRadius: corner, yRadius: corner)
    gray(0.07).setFill()
    body.fill()
    // Hairline edge so the black remote stands out from the dark tile.
    NSColor(white: 1, alpha: 0.16).setStroke()
    body.lineWidth = 2.5
    body.stroke()

    NSGraphicsContext.saveGraphicsState()
    body.addClip()
    gray(0.2).setFill()
    NSRect(x: 0, y: 0, width: width, height: glass).fill()
    NSColor.black.setFill()
    NSRect(x: 0, y: glass, width: width, height: 2).fill()
    NSGraphicsContext.restoreGraphicsState()

    func circle(_ x: CGFloat, _ y: CGFloat, _ d: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: x - d / 2, y: y - d / 2, width: d, height: d))
    }

    gray(0.19).setFill()
    circle(left, firstRow, button).fill()
    circle(right, firstRow, button).fill()
    circle(left, firstRow + row, button).fill()
    circle(left, firstRow + row * 2, button).fill()
    NSBezierPath(roundedRect: NSRect(x: right - button / 2, y: firstRow + row - button / 2,
                                     width: button, height: button + row),
                 xRadius: button / 2, yRadius: button / 2).fill()

    // The white ring around MENU.
    let ring = circle(left, firstRow, button + 9)
    ring.lineWidth = 6
    NSColor.white.setStroke()
    ring.stroke()

    // Microphone slot.
    NSColor.black.setFill()
    NSBezierPath(roundedRect: NSRect(x: width / 2 - 10, y: 16, width: 20, height: 5), xRadius: 2.5, yRadius: 2.5).fill()
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024

    // Standard macOS icon grid: 824pt body centered in 1024.
    let tile = NSBezierPath(roundedRect: NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s),
                            xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [gray(0.24), gray(0.07)])!.draw(in: tile, angle: -90)
    NSColor(white: 1, alpha: 0.12).setStroke()
    tile.lineWidth = 3 * s
    tile.stroke()

    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 36 * s
    shadow.shadowOffset = NSSize(width: 0, height: -14 * s)
    shadow.set()
    // One layer so the shadow falls from the remote as a whole, not each button.
    let cg = NSGraphicsContext.current!.cgContext
    cg.beginTransparencyLayer(auxiliaryInfo: nil)

    // Stand the remote up the middle of the tile; drawing happens in the
    // remote's own top-left, y-down coordinates.
    let scale = 0.9 * s
    let transform = NSAffineTransform()
    transform.translateX(by: 512 * s, yBy: 512 * s)
    transform.scaleX(by: scale, yBy: -scale)
    transform.translateX(by: -120, yBy: -350)
    transform.concat()
    drawRemote()
    cg.endTransparencyLayer()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
if let preview {
    try! render(1024).write(to: URL(fileURLWithPath: preview))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output]
try! task.run()
task.waitUntilExit()
exit(task.terminationStatus)
