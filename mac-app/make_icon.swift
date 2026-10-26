// Draws the Watt Bank app icon (1024x1024 PNG): orange rounded square, white lightning bolt.
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let bg = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(red: 1.0, green: 0.80, blue: 0.20, alpha: 1),
           ending: NSColor(red: 0.96, green: 0.45, blue: 0.05, alpha: 1))!.draw(in: bg, angle: -90)
// bolt
let b = NSBezierPath()
let pts: [(CGFloat, CGFloat)] = [(560, 860), (300, 470), (480, 470), (430, 165), (720, 590), (530, 590), (600, 860)]
b.move(to: NSPoint(x: pts[0].0, y: pts[0].1))
for p in pts.dropFirst() { b.line(to: NSPoint(x: p.0, y: p.1)) }
b.close()
b.lineJoinStyle = .round
NSGraphicsContext.current?.saveGraphicsState()
let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.25); sh.shadowBlurRadius = 24; sh.shadowOffset = NSSize(width: 0, height: -10)
sh.set()
NSColor.white.setFill(); b.fill()
NSGraphicsContext.current?.restoreGraphicsState()
NSColor(white: 0.1, alpha: 1).setStroke(); b.lineWidth = 22; b.stroke()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
