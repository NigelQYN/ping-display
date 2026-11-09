import AppKit

let size = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)!
let tile = NSBezierPath(roundedRect: NSRect(x: 90, y: 90, width: 844, height: 844), xRadius: 200, yRadius: 200)
NSGradient(starting: NSColor(srgbRed: 0.19, green: 0.48, blue: 0.94, alpha: 1),
           ending: NSColor(srgbRed: 0.08, green: 0.23, blue: 0.59, alpha: 1))!.draw(in: tile, angle: 270)
NSColor.white.setStroke()
let screen = NSBezierPath(roundedRect: NSRect(x: 262, y: 370, width: 500, height: 322), xRadius: 45, yRadius: 45)
screen.lineWidth = 36
screen.stroke()
let stand = NSBezierPath()
stand.lineCapStyle = .round
stand.lineWidth = 36
stand.move(to: NSPoint(x: 512, y: 370))
stand.line(to: NSPoint(x: 512, y: 296))
stand.move(to: NSPoint(x: 423, y: 296))
stand.line(to: NSPoint(x: 601, y: 296))
stand.stroke()
let light = NSBezierPath(ovalIn: NSRect(x: 459, y: 478, width: 106, height: 106))
NSColor(srgbRed: 0.98, green: 0.81, blue: 0.39, alpha: 1).setFill()
light.fill()
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
