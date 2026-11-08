// Draws Umbra's app icon (1024×1024 PNG). Usage: swift tools/make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGraphicsContext.current?.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.shadowBlurRadius = 26
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor.black.setFill(); path.fill()
NSGraphicsContext.current?.restoreGraphicsState()

// Deep indigo night → violet: "umbra" is the darkest part of a shadow.
NSGradient(colors: [NSColor(calibratedRed: 0.09, green: 0.07, blue: 0.24, alpha: 1),
                    NSColor(calibratedRed: 0.36, green: 0.27, blue: 0.90, alpha: 1)])!.draw(in: path, angle: 90)

NSGraphicsContext.current?.saveGraphicsState()
path.addClip()
// A soft eclipse glow behind the shield.
let glow = NSGradient(colors: [NSColor(calibratedRed: 0.70, green: 0.62, blue: 1, alpha: 0.55), NSColor(calibratedRed: 0.5, green: 0.4, blue: 1, alpha: 0)])!
glow.draw(in: NSBezierPath(ovalIn: NSRect(x: 182, y: 200, width: 660, height: 660)), relativeCenterPosition: .zero)
NSGraphicsContext.current?.restoreGraphicsState()

let cfg = NSImage.SymbolConfiguration(pointSize: 470, weight: .semibold).applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let shield = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let s = shield.size
    shield.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2 - 6, width: s.width, height: s.height))
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
