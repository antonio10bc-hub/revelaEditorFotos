// Genera AppIcon.icns: el histograma del panel de Revela10bc sobre un cuadrado carbón (estilo ficha técnica),
// con rejilla en cuartos, marcas de recorte, escala inferior y el marcador verde en el pico.
//
// Uso:   swift make_icon.swift   (crea AppIcon.icns junto a este archivo)

import AppKit
import CoreGraphics

let tile = CGColor(red: 0.078, green: 0.082, blue: 0.082, alpha: 1)
let outline = CGColor(red: 0.173, green: 0.180, blue: 0.176, alpha: 1)
let frameLine = CGColor(red: 0.227, green: 0.235, blue: 0.231, alpha: 1)
let grid = CGColor(red: 0.149, green: 0.157, blue: 0.153, alpha: 1)
let light = CGColor(red: 0.894, green: 0.902, blue: 0.882, alpha: 1)
let gray = CGColor(red: 0.424, green: 0.439, blue: 0.416, alpha: 1)
let accent = CGColor(red: 0.643, green: 0.784, blue: 0.4, alpha: 1)

/// Dibuja en coordenadas de 1024 con el origen arriba a la izquierda (como el diseño).
func drawIcon(_ c: CGContext, _ S: CGFloat) {
    let k = S / 1024
    c.translateBy(x: 0, y: S)
    c.scaleBy(x: k, y: -k)

    // Rejilla de iconos de macOS: cuadrado redondeado de 824 px centrado
    let shape = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 186, cornerHeight: 186, transform: nil)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: CGColor(gray: 0, alpha: 0.45))
    c.addPath(shape)
    c.setFillColor(tile)
    c.fillPath()
    c.restoreGState()
    c.addPath(CGPath(roundedRect: CGRect(x: 102, y: 102, width: 820, height: 820), cornerWidth: 184, cornerHeight: 184, transform: nil))
    c.setStrokeColor(outline)
    c.setLineWidth(4)
    c.strokePath()

    // Marco del histograma y rejilla en cuartos
    c.setStrokeColor(grid)
    c.setLineWidth(5)
    for x in [362.0, 512, 662] {
        c.move(to: CGPoint(x: x, y: 282)); c.addLine(to: CGPoint(x: x, y: 742))
    }
    c.strokePath()
    c.setStrokeColor(frameLine)
    c.setLineWidth(6)
    c.stroke(CGRect(x: 212, y: 282, width: 600, height: 460))

    // Histograma
    let h = CGMutablePath()
    h.move(to: CGPoint(x: 212, y: 742))
    h.addCurve(to: CGPoint(x: 300, y: 650), control1: CGPoint(x: 250, y: 738), control2: CGPoint(x: 270, y: 690))
    h.addCurve(to: CGPoint(x: 380, y: 600), control1: CGPoint(x: 330, y: 610), control2: CGPoint(x: 350, y: 640))
    h.addCurve(to: CGPoint(x: 470, y: 430), control1: CGPoint(x: 410, y: 560), control2: CGPoint(x: 430, y: 470))
    h.addCurve(to: CGPoint(x: 560, y: 500), control1: CGPoint(x: 505, y: 395), control2: CGPoint(x: 525, y: 470))
    h.addCurve(to: CGPoint(x: 650, y: 470), control1: CGPoint(x: 595, y: 530), control2: CGPoint(x: 615, y: 455))
    h.addCurve(to: CGPoint(x: 750, y: 650), control1: CGPoint(x: 690, y: 488), control2: CGPoint(x: 710, y: 600))
    h.addCurve(to: CGPoint(x: 812, y: 735), control1: CGPoint(x: 780, y: 690), control2: CGPoint(x: 795, y: 725))
    h.addLine(to: CGPoint(x: 812, y: 742))
    h.closeSubpath()
    c.addPath(h)
    c.setFillColor(light)
    c.fillPath()

    // Avisos de recorte y escala inferior
    c.setFillColor(gray)
    for x in [232.0, 762] {
        c.move(to: CGPoint(x: x, y: 272)); c.addLine(to: CGPoint(x: x + 30, y: 272)); c.addLine(to: CGPoint(x: x + 15, y: 246))
        c.closePath()
    }
    c.fillPath()
    c.setStrokeColor(gray)
    c.setLineWidth(6)
    for i in 0...8 {
        let x = 212 + CGFloat(i) * 75
        c.move(to: CGPoint(x: x, y: 762)); c.addLine(to: CGPoint(x: x, y: i % 4 == 0 ? 800 : 784))
    }
    c.strokePath()

    // Marcador verde en el pico
    c.setFillColor(accent)
    c.fill(CGRect(x: 451, y: 386, width: 36, height: 36))
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
