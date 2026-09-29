import AppKit

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                           bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill()

let card = NSBezierPath(roundedRect: NSRect(x: 143, y: 143, width: 738, height: 738),
                        xRadius: 170, yRadius: 170)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.23)
shadow.shadowBlurRadius = 35
shadow.shadowOffset = NSSize(width: 0, height: -18)
shadow.set()
NSColor.white.setFill()
card.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: .white, ending: NSColor(srgbRed: 0.93, green: 0.95, blue: 0.97, alpha: 1))!
    .draw(in: card, angle: 90)
NSColor.white.withAlphaComponent(0.82).setStroke()
card.lineWidth = 5
card.stroke()

let search = NSBezierPath(roundedRect: NSRect(x: 272, y: 619, width: 480, height: 111),
                          xRadius: 55, yRadius: 55)
NSGradient(starting: NSColor(srgbRed: 0.72, green: 0.74, blue: 0.76, alpha: 1),
           ending: NSColor(srgbRed: 0.85, green: 0.86, blue: 0.87, alpha: 1))!
    .draw(in: search, angle: 90)
NSColor.white.withAlphaComponent(0.34).setStroke()
search.lineWidth = 3
search.stroke()

let lens = NSBezierPath(ovalIn: NSRect(x: 318, y: 660, width: 27, height: 27))
NSColor.white.setStroke()
lens.lineWidth = 7
lens.stroke()
let handle = NSBezierPath()
handle.move(to: NSPoint(x: 341, y: 662))
handle.line(to: NSPoint(x: 356, y: 645))
handle.lineWidth = 7
handle.lineCapStyle = .round
handle.stroke()

let colors: [NSColor] = [
    NSColor(srgbRed: 0.07, green: 0.72, blue: 0.97, alpha: 1),
    NSColor(srgbRed: 0.18, green: 0.84, blue: 0.35, alpha: 1),
    NSColor(srgbRed: 1.00, green: 0.22, blue: 0.43, alpha: 1),
    NSColor(srgbRed: 1.00, green: 0.57, blue: 0.12, alpha: 1),
    NSColor(srgbRed: 0.59, green: 0.36, blue: 0.84, alpha: 1),
    NSColor(srgbRed: 0.48, green: 0.54, blue: 0.60, alpha: 1)
]
for row in 0..<2 {
    for col in 0..<3 {
        let rect = NSRect(x: 289 + col * 174, y: 267 + (1 - row) * 155,
                          width: 112, height: 112)
        let tile = NSBezierPath(roundedRect: rect, xRadius: 26, yRadius: 26)
        colors[row * 3 + col].setFill()
        tile.fill()
        NSColor.white.withAlphaComponent(0.17).setStroke()
        tile.lineWidth = 2
        tile.stroke()
    }
}
NSGraphicsContext.restoreGraphicsState()
let url = URL(fileURLWithPath: CommandLine.arguments[1])
try rep.representation(using: .png, properties: [:])!.write(to: url)
