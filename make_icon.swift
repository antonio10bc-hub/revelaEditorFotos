// Genera AppIcon.icns: cuadrado oscuro estilo app de revelado con un smiley amarillo verdoso eléctrico.
//
// Uso:   swift make_icon.swift   (crea AppIcon.iconset y AppIcon.icns junto a este archivo)

import AppKit
import CoreGraphics

let lime = CGColor(red: 0.80, green: 1.0, blue: 0.10, alpha: 1)
let limeLight = CGColor(red: 0.93, green: 1.0, blue: 0.55, alpha: 1)
let limeDeep = CGColor(red: 0.58, green: 0.86, blue: 0.0, alpha: 1)
let ink = CGColor(red: 0.04, green: 0.07, blue: 0.13, alpha: 1)

func drawIcon(_ c: CGContext, _ S: CGFloat) {
    let k = S / 1024
    // Rejilla de iconos de macOS: cuadrado redondeado de 824 px centrado
    let tile = CGRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185 * k, cornerHeight: 185 * k, transform: nil)

    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 28 * k, color: CGColor(gray: 0, alpha: 0.45))
    c.addPath(shape)
    c.setFillColor(ink)
    c.fillPath()
    c.restoreGState()

    // Fondo: azul noche con un leve brillo arriba
    c.saveGState()
    c.addPath(shape)
    c.clip()
    let bg = CGGradient(colorsSpace: nil, colors: [CGColor(red: 0.10, green: 0.15, blue: 0.25, alpha: 1), ink] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(bg, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    let glow = CGGradient(colorsSpace: nil, colors: [CGColor(red: 0.8, green: 1, blue: 0.1, alpha: 0.22), CGColor(red: 0.8, green: 1, blue: 0.1, alpha: 0)] as CFArray, locations: [0, 1])!
    c.drawRadialGradient(glow, startCenter: CGPoint(x: 512 * k, y: 512 * k), startRadius: 0,
                         endCenter: CGPoint(x: 512 * k, y: 512 * k), endRadius: 420 * k, options: [])
    c.restoreGState()

    // Borde interior fino
    c.saveGState()
    c.addPath(CGPath(roundedRect: tile.insetBy(dx: 3 * k, dy: 3 * k), cornerWidth: 182 * k, cornerHeight: 182 * k, transform: nil))
    c.setStrokeColor(CGColor(red: 0.8, green: 1, blue: 0.1, alpha: 0.18))
    c.setLineWidth(5 * k)
    c.strokePath()
    c.restoreGState()

    // Smiley
    let center = CGPoint(x: 512 * k, y: 505 * k), R = 268 * k
    let face = CGRect(x: center.x - R, y: center.y - R, width: 2 * R, height: 2 * R)
    c.saveGState()
    c.setShadow(offset: .zero, blur: 70 * k, color: CGColor(red: 0.8, green: 1, blue: 0.1, alpha: 0.75))
    c.setFillColor(lime)
    c.fillEllipse(in: face)
    c.restoreGState()
    c.saveGState()
    c.addEllipse(in: face)
    c.clip()
    let shade = CGGradient(colorsSpace: nil, colors: [limeLight, lime, limeDeep] as CFArray, locations: [0, 0.5, 1])!
    c.drawRadialGradient(shade, startCenter: CGPoint(x: center.x - 90 * k, y: center.y + 110 * k), startRadius: 0,
                         endCenter: center, endRadius: R * 1.05, options: [.drawsAfterEndLocation])
    c.restoreGState()

    // Ojos y boca
    c.setFillColor(ink)
    for dx in [-95.0, 95.0] {
        c.fillEllipse(in: CGRect(x: center.x + CGFloat(dx) * k - 32 * k, y: center.y + 45 * k, width: 64 * k, height: 96 * k))
    }
    c.setStrokeColor(ink)
    c.setLineWidth(46 * k)
    c.setLineCap(.round)
    c.addArc(center: CGPoint(x: center.x, y: center.y + 20 * k), radius: 165 * k,
             startAngle: .pi * 1.18, endAngle: .pi * 1.82, clockwise: false)
    c.strokePath()
}

func png(_ size: Int) -> Data {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    drawIcon(c, CGFloat(size))
    return NSBitmapImageRep(cgImage: c.makeImage()!).representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let set = dir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! png(base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try! png(base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", dir.appendingPathComponent("AppIcon.icns").path]
try! p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: set)
print(p.terminationStatus == 0 ? "AppIcon.icns listo" : "iconutil falló")
