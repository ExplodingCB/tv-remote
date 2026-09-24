// Renders the app icon: usage `swift scripts/make-icon.swift out.icns [preview.png]`
// A white Siri Remote silhouette on a dark tile, drawn by hand (SF Symbols
// can't be used in app icons).
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.icns"
let preview = CommandLine.arguments.dropFirst(2).first
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("TVRemote.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// The remote in 1024-point icon space, top-left origin (y down). Buttons are
/// holes cut out of the body so the tile shows through.
func remotePath() -> NSBezierPath {
    let path = NSBezierPath()
    path.windingRule = .evenOdd

    let width: CGFloat = 208, height: CGFloat = 560
    let left = (1024 - width) / 2, top = (1024 - height) / 2
    path.append(NSBezierPath(roundedRect: NSRect(x: left, y: top, width: width, height: height),
                             xRadius: 44, yRadius: 44))

    func hole(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) {
        path.append(NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)))
    }

    let center: CGFloat = 512
    let columnOffset: CGFloat = 40, button: CGFloat = 27
    let leftColumn = center - columnOffset, rightColumn = center + columnOffset

    hole(center, top + 128, 76)             // clickpad
    hole(leftColumn, top + 250, button)     // back
    hole(rightColumn, top + 250, button)    // TV
    hole(leftColumn, top + 326, button)     // play/pause
    hole(leftColumn, top + 402, button)     // mute
    // Volume rocker, spanning the play/pause and mute rows.
    path.append(NSBezierPath(roundedRect: NSRect(x: rightColumn - button, y: top + 326 - button,
                                                 width: button * 2, height: 76 + button * 2),
                             xRadius: button, yRadius: button))
    return path
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
    NSGradient(colors: [NSColor(white: 0.24, alpha: 1), NSColor(white: 0.07, alpha: 1)])!.draw(in: tile, angle: -90)
    NSColor(white: 1, alpha: 0.12).setStroke()
    tile.lineWidth = 3 * s
    tile.stroke()

    // Flip to top-left coordinates at icon scale, then fill the silhouette.
    let transform = NSAffineTransform()
    transform.translateX(by: 0, yBy: CGFloat(px))
    transform.scaleX(by: s, yBy: -s)
    transform.concat()
    NSColor(white: 0.93, alpha: 1).setFill()
    remotePath().fill()

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
