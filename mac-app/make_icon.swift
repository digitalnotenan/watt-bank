// Draws the Watt Bank app icon (1024x1024 PNG): the Watts card badge — a yellow rounded square with a white bolt.
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let radius = rect.width * 0.28
let bg = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
NSGradient(starting: NSColor(red: 1.0, green: 0.84, blue: 0.20, alpha: 1),
           ending: NSColor(red: 0.85, green: 0.55, blue: 0.02, alpha: 1))!.draw(in: bg, angle: -90)
NSColor.black.withAlphaComponent(0.35).setStroke(); bg.lineWidth = rect.width * 0.045; bg.stroke()
// white SF Symbols bolt, like the badge in the card's title bar
let cfg = NSImage.SymbolConfiguration(pointSize: rect.width * 0.52, weight: .bold)
if let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let tinted = NSImage(size: bolt.size)
    tinted.lockFocus()
    bolt.draw(in: NSRect(origin: .zero, size: bolt.size))
    NSColor.white.set(); NSRect(origin: .zero, size: bolt.size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    NSGraphicsContext.current?.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.35); sh.shadowBlurRadius = 8; sh.shadowOffset = NSSize(width: 0, height: -8)
    sh.set()
    tinted.draw(in: NSRect(x: rect.midX - bolt.size.width / 2, y: rect.midY - bolt.size.height / 2, width: bolt.size.width, height: bolt.size.height))
    NSGraphicsContext.current?.restoreGraphicsState()
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
