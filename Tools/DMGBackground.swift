// Draws the background of SoundBin's disk image window: sage green, like the icon, with an arrow from
// the app to the Applications shortcut and a line saying what to do. Positions match Tools/dmg/settings.py.
//
// Regenerate from the repo root:
//   swiftc -O Tools/DMGBackground.swift -o /tmp/dmgbackground
//   /tmp/dmgbackground 1 Tools/dmg/background.png && /tmp/dmgbackground 2 Tools/dmg/background@2x.png
//
import AppKit

let scale = CGFloat(Double(CommandLine.arguments[1]) ?? 1)
let output = URL(filePath: CommandLine.arguments[2])

// In points. The window shows 640 × 400; the extra height covers however much the title bar takes.
let size = CGSize(width: 640, height: 440)
// Icon centres, measured from the top as in settings.py.
let appCenter = CGPoint(x: 180, y: 170)
let applicationsCenter = CGPoint(x: 460, y: 170)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Converts a point measured from the top into Core Graphics' bottom-up coordinates.
func flip(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: size.height - point.y) }

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
// Setting the size in points records the resolution, so the 2x image is marked as Retina.
rep.size = size
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Background: a deeper sage than the icon, so Finder's labels read in both light mode (black text)
// and dark mode (white text), with the same soft top-left glow.
let background = NSGradient(colors: [rgb(0x95A885), rgb(0x82966F), rgb(0x6C8160)],
                            atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
background.draw(in: CGRect(origin: .zero, size: size), angle: -90)
let glow = NSGradient(colors: [rgb(0xFFFFFF, 0.2), rgb(0xFFFFFF, 0)])!
glow.draw(fromCenter: flip(CGPoint(x: 120, y: 40)), radius: 0, toCenter: flip(CGPoint(x: 120, y: 40)), radius: 420, options: [])

let ink = rgb(0xFCFBF6, 0.95)
ctx.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 5, color: rgb(0x2C3D29, 0.35).cgColor)

// The arrow: a gentle arc between the two icons, ending in an open arrowhead.
let start = flip(CGPoint(x: appCenter.x + 88, y: appCenter.y + 6))
let end = flip(CGPoint(x: applicationsCenter.x - 88, y: applicationsCenter.y + 6))
let control = flip(CGPoint(x: (appCenter.x + applicationsCenter.x) / 2, y: appCenter.y - 26))
let arrow = CGMutablePath()
arrow.move(to: start)
arrow.addQuadCurve(to: end, control: control)
// The head follows the curve's direction where it arrives.
let direction = atan2(end.y - control.y, end.x - control.x)
for side in [CGFloat.pi * 0.8, -CGFloat.pi * 0.8] {
    arrow.move(to: end)
    arrow.addLine(to: CGPoint(x: end.x + 15 * cos(direction + side), y: end.y + 15 * sin(direction + side)))
}
ctx.addPath(arrow)
ctx.setStrokeColor(ink.cgColor)
ctx.setLineWidth(5)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.strokePath()

// The instruction, centred below the icons and their labels.
let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let text = NSAttributedString(string: "Drag SoundBin to Applications to install it", attributes: [
    .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
    .foregroundColor: ink,
    .paragraphStyle: paragraph,
])
let textHeight = text.size().height
text.draw(in: CGRect(x: 0, y: size.height - 318 - textHeight / 2, width: size.width, height: textHeight))

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: output)
