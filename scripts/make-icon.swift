import AppKit

let size = 1024.0
// Output path is the first CLI argument (e.g. `swift scripts/make-icon.swift ./icon_1024.png`),
// defaulting to the current directory so nothing machine-specific is baked in.
let out = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath + "/icon_1024.png"

// App palette
let surface = NSColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1.0)
let surfaceEdge = NSColor(red: 0.14, green: 0.15, blue: 0.19, alpha: 1.0)
let series = NSColor(red: 0.45, green: 0.72, blue: 1.00, alpha: 1.0)

let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS "squircle"-ish rounded rect background with a subtle vertical gradient.
// Apple's grid: icon art sits in ~824/1024 with rounded corners ~185.
let inset = 100.0
let rect = CGRect(x: inset, y: inset, width: size - 2*inset, height: size - 2*inset)
let corner = (size - 2*inset) * 0.225
let path = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
ctx.saveGState()
ctx.addPath(path); ctx.clip()
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [surfaceEdge.cgColor, surface.cgColor] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])
ctx.restoreGState()

// The waveform symbol, in series blue, centered.
let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.52, weight: .regular)
if let sym = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
    .withSymbolConfiguration(cfg) {
    let tinted = NSImage(size: sym.size)
    tinted.lockFocus()
    series.set()
    let r = NSRect(origin: .zero, size: sym.size)
    r.fill()
    sym.draw(in: r, from: r, operation: .destinationIn, fraction: 1.0)
    tinted.unlockFocus()
    let w = sym.size.width, h = sym.size.height
    let drawRect = NSRect(x: (size - w)/2, y: (size - h)/2, width: w, height: h)
    tinted.draw(in: drawRect, from: NSRect(origin: .zero, size: sym.size),
                operation: .sourceOver, fraction: 1.0)
} else {
    print("SYMBOL LOAD FAILED"); exit(1)
}
img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    print("PNG ENCODE FAILED"); exit(1)
}
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)  (\(png.count) bytes)")
