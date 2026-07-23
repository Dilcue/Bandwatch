import AppKit

// GitHub social-preview card: 1280x640 (2:1). Reuses the app-icon palette and
// waveform mark, then adds the wordmark + tagline. Output path is the first CLI
// argument, defaulting to ./social-card.png in the current directory.
let W = 1280.0, H = 640.0
let out = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath + "/social-card.png"

// App palette (matches scripts/make-icon.swift)
let surface = NSColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1.0)
let surfaceEdge = NSColor(red: 0.14, green: 0.15, blue: 0.19, alpha: 1.0)
let series = NSColor(red: 0.45, green: 0.72, blue: 1.00, alpha: 1.0)
let subtle = NSColor(red: 0.62, green: 0.65, blue: 0.72, alpha: 1.0)

let img = NSImage(size: NSSize(width: W, height: H))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Background: subtle vertical gradient across the whole card.
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [surfaceEdge.cgColor, surface.cgColor] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])

// Waveform mark on the left, in series blue.
let markSize = 300.0
let cfg = NSImage.SymbolConfiguration(pointSize: markSize, weight: .regular)
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
    let drawRect = NSRect(x: 120, y: (H - h)/2, width: w, height: h)
    tinted.draw(in: drawRect, from: NSRect(origin: .zero, size: sym.size),
                operation: .sourceOver, fraction: 1.0)
}

// Wordmark + tagline on the right.
let textX = 120 + markSize + 70.0
let textRight = 70.0                 // right margin
let textW = W - textX - textRight
let title = "Bandwatch"
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 96, weight: .bold),
    .foregroundColor: NSColor.white,
]
let titleY = H/2 + 24
(title as NSString).draw(at: NSPoint(x: textX, y: titleY), withAttributes: titleAttrs)

// Line 1: the descriptive sentence. Line 2: the three features, on ONE line —
// its font shrinks until the bulleted list fits the available width.
let desc = "Native macOS noise-nuisance monitor"
let features = "Frequency-band detection · evidence clips · coverage logging"

let descAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 34, weight: .regular),
    .foregroundColor: subtle,
]
let descY = titleY - 66
(desc as NSString).draw(at: NSPoint(x: textX, y: descY), withAttributes: descAttrs)

var featSize = 34.0
func featuresAttrs(_ pt: Double) -> [NSAttributedString.Key: Any] {
    [.font: NSFont.systemFont(ofSize: pt, weight: .regular),
     .foregroundColor: subtle]
}
while featSize > 16,
      (features as NSString).size(withAttributes: featuresAttrs(featSize)).width > textW {
    featSize -= 1
}
let featY = descY - 58
(features as NSString).draw(at: NSPoint(x: textX, y: featY), withAttributes: featuresAttrs(featSize))

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    print("PNG ENCODE FAILED"); exit(1)
}
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)  (\(png.count) bytes)")
