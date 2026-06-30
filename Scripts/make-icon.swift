// Generates Assets/AppIcon-1024.png — the source art for the app icon.
// Run once (or after tweaking): swift Scripts/make-icon.swift
// make-app.sh turns this PNG into AppIcon.icns at build time.
// ponytail: programmatic placeholder art — replace Assets/AppIcon-1024.png with
// a designed 1024×1024 PNG anytime; the build pipeline doesn't care how it's made.
import AppKit

let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Squircle background (Apple-ish corner radius ≈ 0.2237 × size).
let rect = NSRect(x: 0, y: 0, width: size, height: size)
let radius = size * 0.2237
let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
squircle.addClip()

// Indigo → violet vertical gradient.
let grad = NSGradient(colors: [
    NSColor(srgbRed: 0.36, green: 0.40, blue: 0.95, alpha: 1),   // #5C66F2
    NSColor(srgbRed: 0.55, green: 0.30, blue: 0.92, alpha: 1),   // #8C4DEB
])!
grad.draw(in: rect, angle: -90)

// "PR" wordmark, white, centered.
let para = NSMutableParagraphStyle(); para.alignment = .center
let font = NSFont.systemFont(ofSize: size * 0.40, weight: .bold)
let text = NSAttributedString(string: "PR", attributes: [
    .font: font, .foregroundColor: NSColor.white, .paragraphStyle: para,
])
let tsize = text.size()
text.draw(in: NSRect(x: 0, y: (size - tsize.height) / 2 - size * 0.02,
                     width: size, height: tsize.height))

// Red count-badge dot (echoes the menubar "needs me" pill).
let r = size * 0.11
let badge = NSBezierPath(ovalIn: NSRect(x: size * 0.70, y: size * 0.70, width: r * 2, height: r * 2))
NSColor.white.setFill(); badge.fill()                                   // white ring
let inner = NSBezierPath(ovalIn: NSRect(x: size * 0.70 + size * 0.018, y: size * 0.70 + size * 0.018,
                                        width: r * 2 - size * 0.036, height: r * 2 - size * 0.036))
NSColor(srgbRed: 0.95, green: 0.26, blue: 0.21, alpha: 1).setFill(); inner.fill()  // #F24336

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("icon render failed\n".utf8)); exit(1)
}
let out = URL(fileURLWithPath: "Assets/AppIcon-1024.png")
try! FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
try! png.write(to: out)
print("wrote \(out.path)")
