// Draws SoundBin's app icon: a stack of sound tiles on a sage green background.
//
// Regenerate the asset catalog icons from the repo root:
//   swiftc -O Tools/AppIcon.swift -o /tmp/appicon
//   /tmp/appicon /tmp/icon.png && /tmp/appicon /tmp/icon-small.png --small
//   ICONS=SoundBin/Assets.xcassets/AppIcon.appiconset
//   for s in 16 32; do sips -z $s $s /tmp/icon-small.png --out $ICONS/icon_$s.png; sips -z $((s*2)) $((s*2)) /tmp/icon-small.png --out $ICONS/icon_$s@2x.png; done
//   for s in 128 256 512; do sips -z $s $s /tmp/icon.png --out $ICONS/icon_$s.png; sips -z $((s*2)) $((s*2)) /tmp/icon.png --out $ICONS/icon_$s@2x.png; done
//
import AppKit
import CoreGraphics

// "--small" draws a simplified version for 16 and 32 pt: fewer, thicker bars and no stack behind.
let isSmall = CommandLine.arguments.contains("--small")

// Full-bleed artwork; macOS applies its rounded-rectangle mask and margins itself.
let size: CGFloat = 1024
let space = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    let r = CGFloat((hex >> 16) & 0xFF) / 255, g = CGFloat((hex >> 8) & 0xFF) / 255, b = CGFloat(hex & 0xFF) / 255
    return CGColor(srgbRed: r, green: g, blue: b, alpha: alpha)
}

// Sage background: lighter at the top, a touch deeper at the bottom, with a soft top-left glow.
let background = CGGradient(colorsSpace: space, colors: [rgb(0xBFCDB0), rgb(0x9DB08C), rgb(0x879C77)] as CFArray,
                            locations: [0, 0.6, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: size * 0.3, y: size), end: CGPoint(x: size * 0.7, y: 0),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
let glow = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.28), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: size * 0.28, y: size * 0.82), startRadius: 0,
                       endCenter: CGPoint(x: size * 0.28, y: size * 0.82), endRadius: size * 0.7, options: [])

// A tile: a rounded card, scaled about its centre.
let cardSize = CGSize(width: 620, height: 440)
let cardCenter = CGPoint(x: size / 2, y: size * 0.445)
let cornerRadius: CGFloat = 72

func drawCard(lift: CGFloat, scale: CGFloat, fill: CGColor, shadowAlpha: CGFloat, shadowBlur: CGFloat, shadowY: CGFloat) {
    ctx.saveGState()
    let width = cardSize.width * scale
    let height = cardSize.height * scale
    let rect = CGRect(x: cardCenter.x - width / 2, y: cardCenter.y - height / 2 + lift, width: width, height: height)
    let radius = cornerRadius * scale
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.setShadow(offset: CGSize(width: 0, height: -shadowY), blur: shadowBlur, color: rgb(0x2C3D29, shadowAlpha))
    ctx.addPath(path)
    ctx.setFillColor(fill)
    ctx.fillPath()
    ctx.restoreGState()
}

// The stack: two smaller tiles peeking out above the front one.
if !isSmall {
    drawCard(lift: 136, scale: 0.8, fill: rgb(0xF4F3EA, 0.6), shadowAlpha: 0.1, shadowBlur: 20, shadowY: 4)
    drawCard(lift: 70, scale: 0.9, fill: rgb(0xF8F7F0, 0.85), shadowAlpha: 0.14, shadowBlur: 26, shadowY: 6)
}
drawCard(lift: isSmall ? 50 : 0, scale: isSmall ? 1.12 : 1, fill: rgb(0xFCFBF6), shadowAlpha: 0.3, shadowBlur: 48, shadowY: 22)

// Waveform on the front tile: a hit that rises then decays, like the app's tiles.
let peaks: [CGFloat] = isSmall
    ? [0.45, 1.0, 0.82, 0.66, 0.48, 0.32]
    : [0.3, 0.62, 1.0, 0.9, 0.76, 0.84, 0.64, 0.56, 0.6, 0.44, 0.38, 0.29, 0.23, 0.17]
let barWidth: CGFloat = isSmall ? 62 : 26
let gap: CGFloat = isSmall ? 34 : 13
let totalWidth = CGFloat(peaks.count) * barWidth + CGFloat(peaks.count - 1) * gap
let startX = cardCenter.x - totalWidth / 2
let barsCenterY = cardCenter.y + (isSmall ? 50 : 0)
let maxHeight: CGFloat = isSmall ? 340 : 290
let bars = CGMutablePath()
for (index, peak) in peaks.enumerated() {
    let height = max(barWidth, peak * maxHeight)
    bars.addRoundedRect(in: CGRect(x: startX + CGFloat(index) * (barWidth + gap), y: cardCenter.y - height / 2,
                                   width: barWidth, height: height).offsetBy(dx: 0, dy: barsCenterY - cardCenter.y),
                        cornerWidth: barWidth / 2, cornerHeight: barWidth / 2)
}
ctx.saveGState()
ctx.addPath(bars)
ctx.clip()
let ink = CGGradient(colorsSpace: space, colors: [rgb(0x4F7048), rgb(0x2F4A2E)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(ink, start: CGPoint(x: 0, y: barsCenterY + maxHeight / 2), end: CGPoint(x: 0, y: barsCenterY - maxHeight / 2), options: [])
ctx.restoreGState()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(filePath: CommandLine.arguments[1]))
