// Revela — editor de fotos RAW para macOS inspirado en el módulo Revelar de Lightroom.
//
// Compilar y abrir:   ./build.sh && open Revela.app
// (o directamente:    swiftc -parse-as-library -O -swift-version 5 Revela.swift -o Revela && ./Revela)
//
// Edición no destructiva: los ajustes se guardan en
// ~/Library/Application Support/Revela/catalog.json y los originales nunca se modifican.

import SwiftUI
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

// MARK: - Idioma

/// Traduce un texto de la interfaz. El español es el idioma base (las claves); el inglés está en
/// en.lproj/Localizable.strings. Los textos fijos de SwiftUI se traducen solos; los que llegan como String pasan por aquí.
func tr(_ s: String) -> String { Bundle.main.localizedString(forKey: s, value: s, table: nil) }

/// Traduce un formato con `%@` y lo rellena (pasa los valores ya como texto).
func tr(_ format: String, _ args: CVarArg...) -> String { String(format: tr(format), arguments: args) }

enum AppLanguage: String, CaseIterable, Identifiable {
    case es, en
    var id: String { rawValue }
    var name: String { self == .es ? "Español" : "English" }

    /// Idioma en uso: el elegido en la app o, si no, el preferido del sistema entre los disponibles.
    static var current: AppLanguage {
        let pref = Bundle.main.preferredLocalizations.first ?? "es"
        return pref.hasPrefix("en") ? .en : .es
    }

    /// Guarda el idioma (se aplica al reiniciar) y ofrece reiniciar ya.
    static func choose(_ l: AppLanguage) {
        guard l != current else { return }
        UserDefaults.standard.set([l.rawValue], forKey: "AppleLanguages")
        let a = NSAlert()
        a.messageText = l == .en ? "Restart Revela to switch to English?" : "¿Reiniciar Revela para cambiar a español?"
        a.addButton(withTitle: l == .en ? "Restart now" : "Reiniciar ahora")
        a.addButton(withTitle: l == .en ? "Later" : "Más tarde")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.6; open \"\(Bundle.main.bundlePath)\""]
        try? p.run()
        NSApp.terminate(nil)
    }
}

// MARK: - Tema

/// Estilo "ficha técnica": líneas finas y opacas, esquinas rectas; lo seleccionado se invierte (gris claro,
/// texto oscuro) y el verde queda solo para marcadores pequeños de activo o modificado.
enum Theme {
    static let window = Color(red: 0.063, green: 0.067, blue: 0.067)
    static let canvas = Color(red: 0.043, green: 0.047, blue: 0.047)
    static let panel = Color(red: 0.075, green: 0.078, blue: 0.078)
    static let raised = Color(red: 0.102, green: 0.106, blue: 0.106)
    static let separator = Color(red: 0.165, green: 0.173, blue: 0.169)
    static let rule = Color(red: 0.118, green: 0.125, blue: 0.122)
    static let text = Color(red: 0.925, green: 0.933, blue: 0.914)
    static let secondary = Color(white: 0.66)
    static let dim = Color(white: 0.53)
    /// Selección: fondo gris claro con texto oscuro.
    static let select = Color(red: 0.894, green: 0.902, blue: 0.882)
    static let onSelect = Color(red: 0.067, green: 0.071, blue: 0.071)
    /// Verde sutil: solo marcadores de activo / modificado.
    static let accent = Color(red: 0.643, green: 0.784, blue: 0.4)
    static let border = Color(red: 0.227, green: 0.235, blue: 0.231)
    static let track = Color(red: 0.227, green: 0.235, blue: 0.231)
    static let fill = Color.white.opacity(0.05)
    static let selection = Color.white.opacity(0.08)
}

/// Cuadradito de 5 px en el verde de acento: marca lo activo o modificado.
struct Marker: View {
    var on = true
    var body: some View { Rectangle().fill(on ? Theme.accent : Color.clear).frame(width: 5, height: 5) }
}

/// Pistas de color solo donde el color aporta información (temperatura, matiz, saturación, HSL…).
enum Tracks {
    static let gray = [Color(white: 0.1), Color(white: 0.78)]
    static let temp = [Color(red: 0.3, green: 0.5, blue: 0.9), Color(red: 0.92, green: 0.82, blue: 0.35)]
    static let tint = [Color(red: 0.35, green: 0.75, blue: 0.35), Color(red: 0.8, green: 0.35, blue: 0.8)]
    static let color = [Color(white: 0.45), .red, .yellow, .green, .cyan, .blue, .purple]
    static let shadowTint = [Color.green, Color(red: 0.8, green: 0.35, blue: 0.8)]
}

// MARK: - Modelo

struct CurvePoint: Codable, Equatable, Hashable {
    var x: Double
    var y: Double
}

struct GradeWheel: Codable, Equatable, Hashable {
    var hue: Double = 0
    var sat: Double = 0
    var lum: Double = 0
}

/// Punto de color: un color concreto elegido con el cuentagotas y cómo se transforma.
struct PointColor: Codable, Equatable, Hashable, Identifiable {
    var id = UUID()
    var color: [Double] = [0.5, 0.5, 0.5]   // sRGB 0…1, muestreado justo antes de la LUT
    var hue = 0.0, sat = 0.0, lum = 0.0     // desplazamientos −100…100
    var variance = 0.0                      // −100 unifica los tonos del rango, +100 los separa
    var range = 50.0                        // 0…100
}

enum Profile: String, Codable, CaseIterable, Identifiable {
    case color = "Color", vivid = "Vívido", neutral = "Neutro", landscape = "Paisaje", portrait = "Retrato", mono = "Monocromo"
    var id: String { rawValue }
}

struct ProfileLook {
    var contrast = 0.0
    var sat = 0.0
    var bandSat = [Double](repeating: 0, count: 8)
    var bandLum = [Double](repeating: 0, count: 8)
}

extension Profile {
    var look: ProfileLook {
        var l = ProfileLook()
        switch self {
        case .color, .mono: break
        case .vivid: l.contrast = 14; l.sat = 18
        case .neutral: l.contrast = -18; l.sat = -8
        case .landscape: l.contrast = 10; l.sat = 8; l.bandSat[3] = 15; l.bandSat[5] = 15; l.bandLum[5] = -8
        case .portrait: l.contrast = -6; l.bandSat[0] = -4; l.bandSat[1] = -8; l.bandLum[1] = 6
        }
        return l
    }
}

let identityCurve = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]
let hslNames = ["Rojo", "Naranja", "Amarillo", "Verde", "Aguamarina", "Azul", "Púrpura", "Magenta"]

struct EditSettings: Codable, Equatable {
    // Básico
    var profile: Profile = .color
    var temp = 0.0, tint = 0.0
    var exposure = 0.0, contrast = 0.0
    var highlights = 0.0, shadows = 0.0, whites = 0.0, blacks = 0.0
    var texture = 0.0, clarity = 0.0, dehaze = 0.0
    var vibrance = 0.0, saturation = 0.0
    // HDR: edición con luces por encima del blanco SDR (rango en pasos)
    var hdr = false, hdrHeadroom = 2.0
    // Curva de tonos
    var pcHighlights = 0.0, pcLights = 0.0, pcDarks = 0.0, pcShadows = 0.0
    var curveRGB = identityCurve, curveR = identityCurve, curveG = identityCurve, curveB = identityCurve
    // Mezcla de colores (HSL) y mezcla B/N
    var hslHue = [Double](repeating: 0, count: 8)
    var hslSat = [Double](repeating: 0, count: 8)
    var hslLum = [Double](repeating: 0, count: 8)
    var bwMix = [Double](repeating: 0, count: 8)
    // Punto de color
    var pointColors: [PointColor] = []
    // Gradación de color
    var gradeShadows = GradeWheel(), gradeMidtones = GradeWheel(), gradeHighlights = GradeWheel(), gradeGlobal = GradeWheel()
    var gradeBlending = 50.0, gradeBalance = 0.0
    // Detalle
    var sharpAmount = 0.0, sharpRadius = 1.0, sharpDetail = 25.0, sharpMasking = 0.0
    var nrLuminance = 0.0, nrDetail = 50.0, nrContrast = 0.0
    var nrColor = 0.0, nrColorDetail = 50.0, nrColorSmooth = 50.0
    // Óptica
    var removeCA = false, lensProfile = false
    var distortion = 0.0, lensVignette = 0.0, lensVignetteMid = 50.0
    var defringePurple = 0.0, defringeGreen = 0.0
    // Geometría
    var vertical = 0.0, horizontal = 0.0, rotate = 0.0, aspect = 0.0, scale = 100.0, offsetX = 0.0, offsetY = 0.0
    // Efectos
    var vigAmount = 0.0, vigMidpoint = 50.0, vigRoundness = 0.0, vigFeather = 50.0, vigHighlights = 0.0
    var grainAmount = 0.0, grainSize = 25.0, grainRoughness = 50.0
    // Calibración
    var calShadowTint = 0.0
    var calRedHue = 0.0, calRedSat = 0.0, calGreenHue = 0.0, calGreenSat = 0.0, calBlueHue = 0.0, calBlueSat = 0.0
    // Recorte y orientación
    var cropX = 0.0, cropY = 0.0, cropW = 1.0, cropH = 1.0, cropAngle = 0.0
    var rotation90 = 0
    var flipH = false
    // Máscaras (ajustes locales) y correcciones (herramienta Eliminar)
    var masks: [Mask] = []
    var heals: [HealSpot] = []

    static func defaults(raw: Bool) -> EditSettings {
        var s = EditSettings()
        if raw { s.sharpAmount = 40; s.nrColor = 25 }
        return s
    }

    /// Copia el "look" (tono, color, detalle, efectos) de otro ajuste conservando el encuadre propio.
    func withLook(from o: EditSettings) -> EditSettings {
        var r = o
        r.cropX = cropX; r.cropY = cropY; r.cropW = cropW; r.cropH = cropH; r.cropAngle = cropAngle
        r.rotation90 = rotation90; r.flipH = flipH
        r.vertical = vertical; r.horizontal = horizontal; r.rotate = rotate; r.aspect = aspect
        r.scale = scale; r.offsetX = offsetX; r.offsetY = offsetY
        r.masks = masks
        r.heals = heals
        return r
    }
}

/// Grupos de ajustes que se restablecen o desactivan de una vez (paneles y subgrupos).
enum AdjustGroup: String, CaseIterable {
    case basic, whiteBalance, tone, presence, curve, color, grading, detail, sharpening, noise
    case optics, geometry, effects, vignette, grain, calibration
}

extension EditSettings {
    /// Estos ajustes con un grupo devuelto a sus valores por defecto.
    func resetting(_ g: AdjustGroup, raw: Bool) -> EditSettings {
        let d = EditSettings.defaults(raw: raw)
        var s = self
        switch g {
        case .basic:
            s = s.resetting(.whiteBalance, raw: raw).resetting(.tone, raw: raw).resetting(.presence, raw: raw)
            s.profile = d.profile; s.hdr = d.hdr; s.hdrHeadroom = d.hdrHeadroom
        case .whiteBalance: s.temp = d.temp; s.tint = d.tint
        case .tone:
            s.exposure = d.exposure; s.contrast = d.contrast; s.highlights = d.highlights
            s.shadows = d.shadows; s.whites = d.whites; s.blacks = d.blacks
        case .presence:
            s.texture = d.texture; s.clarity = d.clarity; s.dehaze = d.dehaze; s.vibrance = d.vibrance; s.saturation = d.saturation
        case .curve:
            s.pcHighlights = d.pcHighlights; s.pcLights = d.pcLights; s.pcDarks = d.pcDarks; s.pcShadows = d.pcShadows
            s.curveRGB = d.curveRGB; s.curveR = d.curveR; s.curveG = d.curveG; s.curveB = d.curveB
        case .color:
            s.hslHue = d.hslHue; s.hslSat = d.hslSat; s.hslLum = d.hslLum; s.bwMix = d.bwMix; s.pointColors = d.pointColors
        case .grading:
            s.gradeShadows = d.gradeShadows; s.gradeMidtones = d.gradeMidtones; s.gradeHighlights = d.gradeHighlights
            s.gradeGlobal = d.gradeGlobal; s.gradeBlending = d.gradeBlending; s.gradeBalance = d.gradeBalance
        case .detail: s = s.resetting(.sharpening, raw: raw).resetting(.noise, raw: raw)
        case .sharpening:
            s.sharpAmount = d.sharpAmount; s.sharpRadius = d.sharpRadius; s.sharpDetail = d.sharpDetail; s.sharpMasking = d.sharpMasking
        case .noise:
            s.nrLuminance = d.nrLuminance; s.nrDetail = d.nrDetail; s.nrContrast = d.nrContrast
            s.nrColor = d.nrColor; s.nrColorDetail = d.nrColorDetail; s.nrColorSmooth = d.nrColorSmooth
        case .optics:
            s.removeCA = d.removeCA; s.lensProfile = d.lensProfile; s.distortion = d.distortion
            s.lensVignette = d.lensVignette; s.lensVignetteMid = d.lensVignetteMid
            s.defringePurple = d.defringePurple; s.defringeGreen = d.defringeGreen
        case .geometry:
            s.vertical = d.vertical; s.horizontal = d.horizontal; s.rotate = d.rotate; s.aspect = d.aspect
            s.scale = d.scale; s.offsetX = d.offsetX; s.offsetY = d.offsetY
        case .effects: s = s.resetting(.vignette, raw: raw).resetting(.grain, raw: raw)
        case .vignette:
            s.vigAmount = d.vigAmount; s.vigMidpoint = d.vigMidpoint; s.vigRoundness = d.vigRoundness
            s.vigFeather = d.vigFeather; s.vigHighlights = d.vigHighlights
        case .grain: s.grainAmount = d.grainAmount; s.grainSize = d.grainSize; s.grainRoughness = d.grainRoughness
        case .calibration:
            s.calShadowTint = d.calShadowTint; s.calRedHue = d.calRedHue; s.calRedSat = d.calRedSat
            s.calGreenHue = d.calGreenHue; s.calGreenSat = d.calGreenSat; s.calBlueHue = d.calBlueHue; s.calBlueSat = d.calBlueSat
        }
        return s
    }

    func isModified(_ g: AdjustGroup, raw: Bool) -> Bool { resetting(g, raw: raw) != self }
}

// MARK: - Máscaras

enum MaskKind: String, Codable, CaseIterable {
    case subject, people, background, brush, linear, radial, color, luminance

    /// Máscaras que se calculan con Vision y se guardan como imagen.
    var isDetected: Bool { self == .subject || self == .people || self == .background }

    var label: String {
        switch self {
        case .subject: return "Sujeto"
        case .people: return "Personas"
        case .background: return "Fondo"
        case .brush: return "Pincel"
        case .linear: return "Degradado lineal"
        case .radial: return "Degradado radial"
        case .color: return "Rango de color"
        case .luminance: return "Rango de luminancia"
        }
    }

    var shortLabel: String {
        switch self {
        case .subject: return "Sujeto"
        case .people: return "Personas"
        case .background: return "Fondo"
        case .brush: return "Pincel"
        case .linear: return "Lineal"
        case .radial: return "Radial"
        case .color: return "Color"
        case .luminance: return "Luminancia"
        }
    }

    var icon: String {
        switch self {
        case .subject: return "person.crop.rectangle"
        case .people: return "person.2"
        case .background: return "mountain.2"
        case .brush: return "paintbrush.pointed"
        case .linear: return "square.tophalf.filled"
        case .radial: return "circle.dashed"
        case .color: return "eyedropper.halffull"
        case .luminance: return "sun.max"
        }
    }
}

struct MaskAdjust: Codable, Equatable {
    var temp = 0.0, tint = 0.0, exposure = 0.0, contrast = 0.0
    var highlights = 0.0, shadows = 0.0, whites = 0.0, blacks = 0.0
    var texture = 0.0, clarity = 0.0, dehaze = 0.0, saturation = 0.0
    var sharpness = 0.0, noise = 0.0
    var colorHue = 0.0, colorSat = 0.0
}

struct BrushStroke: Codable, Equatable, Hashable {
    var points: [Double]    // x0, y0, x1, y1… normalizados en la imagen sin recortar
    var size: Double        // radio, relativo al lado largo
    var feather: Double
    var flow: Double
    var erase: Bool
}

/// Coordenadas normalizadas (0…1, origen arriba a la izquierda) sobre la imagen enderezada sin recortar,
/// así las máscaras no se mueven al cambiar el recorte.
struct Mask: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var kind: MaskKind
    var enabled = true
    var invert = false
    // Lineal: efecto completo en (x0, y0), nulo en (x1, y1)
    var x0 = 0.5, y0 = 0.1, x1 = 0.5, y1 = 0.5
    // Radial: centro, radios (relativos a ancho / alto), ángulo en grados y desvanecimiento
    var cx = 0.5, cy = 0.5, rx = 0.25, ry = 0.25, angle = 0.0, feather = 50.0
    // Pincel
    var strokes: [BrushStroke] = []
    // Sujeto: máscara en escala de grises (PNG) calculada con Vision
    var raster: Data?
    // Rango de color: color elegido (sRGB 0…1, vacío = sin elegir) y tolerancia
    var rangeColor: [Double] = []
    var rangeTolerance = 30.0
    // Rango de luminancia (0…100)
    var lumLow = 60.0, lumHigh = 100.0, lumSmooth = 30.0
    var adjust = MaskAdjust()

    static let placeholder = Mask(name: "", kind: .radial)
}

enum HealMode: String, Codable { case heal, clone }

/// Punto de la herramienta Eliminar. Coordenadas como las máscaras (imagen enderezada sin recortar).
struct HealSpot: Codable, Equatable, Identifiable {
    var id = UUID()
    var x: Double, y: Double        // destino
    var sx: Double, sy: Double      // origen
    var size: Double                // radio relativo al lado largo
    var feather = 50.0
    var opacity = 100.0
    var mode = HealMode.heal
}

struct Photo: Identifiable, Equatable {
    let id = UUID()
    var url: URL
    let isRAW: Bool
    /// El archivo ya no está donde se importó (se ha movido, renombrado o el disco no está conectado).
    var missing = false
    var settings: EditSettings
    var thumbnail: CGImage?
    var exif = ""
    var pixelSize = CGSize.zero
    var asShot: WhitePoint?

    var name: String { url.lastPathComponent }
    var isEdited: Bool { settings != EditSettings.defaults(raw: isRAW) }
}

struct WhitePoint: Equatable { var temp: Double; var tint: Double }

struct HistoryEntry: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let settings: EditSettings
}

struct HistoryState: Equatable {
    var entries: [HistoryEntry]
    var index: Int
}

struct UserPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var settings: EditSettings
}

struct Catalog: Codable {
    struct Entry: Codable { var path: String; var settings: EditSettings }
    var photos: [Entry] = []
    var presets: [UserPreset] = []
}

enum CropAspect: String, CaseIterable, Identifiable {
    case free = "Libre", original = "Original", square = "1 x 1", r45 = "4 x 5", r57 = "5 x 7", r23 = "2 x 3", r34 = "3 x 4", r916 = "9 x 16"
    var id: String { rawValue }
    /// Proporción lado largo / lado corto.
    var longRatio: Double? {
        switch self {
        case .free, .original: return nil
        case .square: return 1
        case .r45: return 1.25
        case .r57: return 1.4
        case .r23: return 1.5
        case .r34: return 4.0 / 3.0
        case .r916: return 16.0 / 9.0
        }
    }
}

enum ExportFormat: String, CaseIterable, Identifiable {
    case jpeg = "JPEG", heic = "HEIC", tiff = "TIFF 16 bits", png = "PNG"
    var id: String { rawValue }
    var ext: String {
        switch self { case .jpeg: return "jpg"; case .heic: return "heic"; case .tiff: return "tif"; case .png: return "png" }
    }
    var lossy: Bool { self == .jpeg || self == .heic }
    var uti: CFString {
        switch self {
        case .jpeg: return UTType.jpeg.identifier as CFString
        case .heic: return UTType.heic.identifier as CFString
        case .tiff: return UTType.tiff.identifier as CFString
        case .png: return UTType.png.identifier as CFString
        }
    }
}

enum ExportSizing: String, CaseIterable, Identifiable {
    case original = "Tamaño original", longEdge = "Lado largo", shortEdge = "Lado corto", width = "Ancho", height = "Alto"
    case megapixels = "Megapíxeles", percent = "Porcentaje"
    var id: String { rawValue }
    var unit: String { self == .megapixels ? "MP" : (self == .percent ? "%" : "px") }

    /// Escala a aplicar a una imagen de `w`×`h` píxeles.
    func scale(_ w: Double, _ h: Double, value v: Double) -> Double {
        guard v > 0, w > 0, h > 0 else { return 1 }
        switch self {
        case .original: return 1
        case .longEdge: return v / max(w, h)
        case .shortEdge: return v / min(w, h)
        case .width: return v / w
        case .height: return v / h
        case .megapixels: return (v * 1_000_000 / (w * h)).squareRoot()
        case .percent: return v / 100
        }
    }
}

enum ExportMetadata: String, CaseIterable, Identifiable {
    case all = "Todos", noLocation = "Todos menos la ubicación", none = "Ninguno (eliminar)"
    var id: String { rawValue }
}

enum ExportNaming: String, CaseIterable, Identifiable {
    case original = "Nombre original", suffix = "Original + sufijo", custom = "Nombre + número"
    var id: String { rawValue }
}

struct ExportOptions {
    var format = ExportFormat.jpeg
    var quality = 0.9
    var sizing = ExportSizing.original
    var sizeValue = 2048.0
    var noEnlarge = true
    var ppi = 300
    var metadata = ExportMetadata.all
}

let rawExtensions: Set<String> = ["cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "rwl",
                                  "dng", "pef", "srw", "3fr", "fff", "iiq", "erf", "mos", "mrw", "x3f", "raw", "kdc", "dcr"]

func isSupportedImage(_ url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    if rawExtensions.contains(ext) { return true }
    guard let t = UTType(filenameExtension: ext) else { return false }
    return t.conforms(to: .image)
}

func isRAWFile(_ url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    if rawExtensions.contains(ext) { return true }
    return UTType(filenameExtension: ext)?.conforms(to: .rawImage) ?? false
}

// MARK: - Matemáticas de color

enum CMath {
    @inline(__always) static func clamp(_ x: Double, _ a: Double = 0, _ b: Double = 1) -> Double { min(max(x, a), b) }

    @inline(__always) static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = clamp((x - e0) / (e1 - e0))
        return t * t * (3 - 2 * t)
    }

    @inline(__always) static func bell(_ x: Double, _ c: Double, _ w: Double) -> Double {
        let d = (x - c) / w
        return exp(-d * d)
    }

    @inline(__always) static func luma(_ r: Double, _ g: Double, _ b: Double) -> Double { 0.299 * r + 0.587 * g + 0.114 * b }

    @inline(__always) static func srgbEncode(_ x: Double) -> Double {
        x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
    }

    static func hueDist(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }

    static func rgbToHsl(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2
        let d = mx - mn
        if d < 1e-6 { return (0, 0, l) }
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        if mx == r { h = (g - b) / d + (g < b ? 6 : 0) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
        h *= 60
        return (h, clamp(s), l)
    }

    static func hslToRgb(_ h: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
        if s <= 0 { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        let hk = ((h.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360) / 360
        func f(_ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6.0 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3.0 { return p + (q - p) * (2.0 / 3.0 - t) * 6 }
            return p
        }
        return (f(hk + 1.0 / 3.0), f(hk), f(hk - 1.0 / 3.0))
    }

    static let bandHues: [Double] = [0, 30, 60, 120, 180, 225, 270, 315]

    /// Devuelve las dos bandas HSL vecinas y el peso de interpolación para un tono dado.
    static func bandWeights(_ h0: Double) -> (Int, Int, Double) {
        let h = (h0.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        for k in 0..<8 {
            let a = bandHues[k], b = k == 7 ? 360 : bandHues[k + 1]
            if h >= a && h < b {
                let t = (h - a) / (b - a)
                return (k, (k + 1) % 8, t * t * (3 - 2 * t))
            }
        }
        return (0, 1, 0)
    }

    static func bandValue(_ arr: [Double], _ h: Double) -> Double {
        let (i, j, t) = bandWeights(h)
        return arr[i] * (1 - t) + arr[j] * t
    }
}

enum Spline {
    /// Spline cúbica monótona (Fritsch–Carlson) muestreada en `n` puntos sobre [0, 1].
    static func table(_ pts: [CurvePoint], n: Int = 1024) -> [Double] {
        let p = pts.sorted { $0.x < $1.x }
        guard p.count >= 2 else { return (0..<n).map { Double($0) / Double(n - 1) } }
        let xs = p.map(\.x), ys = p.map(\.y), m = p.count
        var d = [Double](repeating: 0, count: m - 1)
        for i in 0..<m - 1 { d[i] = (ys[i + 1] - ys[i]) / max(1e-6, xs[i + 1] - xs[i]) }
        var t = [Double](repeating: 0, count: m)
        t[0] = d[0]
        t[m - 1] = d[m - 2]
        if m > 2 { for i in 1..<m - 1 { t[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 } }
        for i in 0..<m - 1 {
            if d[i] == 0 { t[i] = 0; t[i + 1] = 0; continue }
            let a = t[i] / d[i], b = t[i + 1] / d[i], s = a * a + b * b
            if s > 9 { let k = 3 / s.squareRoot(); t[i] = k * a * d[i]; t[i + 1] = k * b * d[i] }
        }
        var out = [Double](repeating: 0, count: n)
        var seg = 0
        for k in 0..<n {
            let x = Double(k) / Double(n - 1)
            if x <= xs[0] { out[k] = CMath.clamp(ys[0]); continue }
            if x >= xs[m - 1] { out[k] = CMath.clamp(ys[m - 1]); continue }
            while seg < m - 2 && x > xs[seg + 1] { seg += 1 }
            let h = max(1e-6, xs[seg + 1] - xs[seg]), u = (x - xs[seg]) / h
            let u2 = u * u, u3 = u2 * u
            let v = (2 * u3 - 3 * u2 + 1) * ys[seg] + (u3 - 2 * u2 + u) * h * t[seg]
                + (-2 * u3 + 3 * u2) * ys[seg + 1] + (u3 - u2) * h * t[seg + 1]
            out[k] = CMath.clamp(v)
        }
        return out
    }

    static func lookup(_ t: [Double], _ x: Double) -> Double {
        let n = t.count
        let f = CMath.clamp(x) * Double(n - 1)
        let i = Int(f)
        if i >= n - 1 { return t[n - 1] }
        return t[i] + (t[i + 1] - t[i]) * (f - Double(i))
    }
}

enum Tone {
    /// Contraste, iluminaciones, sombras, blancos y negros como curva global (complementa el ajuste local).
    static func basic(_ x: Double, _ s: EditSettings, extraContrast: Double = 0) -> Double {
        var y = x
        let c = CMath.clamp((s.contrast + extraContrast) / 100, -1, 1)
        y += c * 0.85 * (x * x * (3 - 2 * x) - x)
        let hl = s.highlights / 100
        y += (hl > 0 ? 0.16 : 0.07) * hl * CMath.bell(x, 0.78, 0.2)
        y += 0.07 * s.shadows / 100 * CMath.bell(x, 0.22, 0.16)
        y += 0.22 * s.whites / 100 * CMath.smoothstep(0.4, 1.0, x)
        y += 0.16 * s.blacks / 100 * (1 - CMath.smoothstep(0.0, 0.45, x))
        return y
    }

    static func parametric(_ x: Double, _ s: EditSettings) -> Double {
        var y = x
        y += s.pcShadows / 100 * 0.16 * CMath.bell(x, 0.12, 0.11)
        y += s.pcDarks / 100 * 0.16 * CMath.bell(x, 0.37, 0.12)
        y += s.pcLights / 100 * 0.16 * CMath.bell(x, 0.63, 0.12)
        y += s.pcHighlights / 100 * 0.16 * CMath.bell(x, 0.88, 0.11)
        return y
    }
}

// MARK: - LUT 3D (tono, curvas, HSL, gradación, calibración)

enum LUTBuilder {
    static let size = 33

    /// Subconjunto de ajustes que afecta a la LUT (para cachearla).
    static func key(_ s: EditSettings) -> EditSettings {
        var k = EditSettings()
        k.profile = s.profile
        k.contrast = s.contrast; k.highlights = s.highlights; k.shadows = s.shadows; k.whites = s.whites; k.blacks = s.blacks
        k.vibrance = s.vibrance; k.saturation = s.saturation
        k.pcHighlights = s.pcHighlights; k.pcLights = s.pcLights; k.pcDarks = s.pcDarks; k.pcShadows = s.pcShadows
        k.curveRGB = s.curveRGB; k.curveR = s.curveR; k.curveG = s.curveG; k.curveB = s.curveB
        k.hslHue = s.hslHue; k.hslSat = s.hslSat; k.hslLum = s.hslLum; k.bwMix = s.bwMix
        k.pointColors = s.pointColors
        k.gradeShadows = s.gradeShadows; k.gradeMidtones = s.gradeMidtones; k.gradeHighlights = s.gradeHighlights; k.gradeGlobal = s.gradeGlobal
        k.gradeBlending = s.gradeBlending; k.gradeBalance = s.gradeBalance
        k.calShadowTint = s.calShadowTint
        k.calRedHue = s.calRedHue; k.calRedSat = s.calRedSat; k.calGreenHue = s.calGreenHue
        k.calGreenSat = s.calGreenSat; k.calBlueHue = s.calBlueHue; k.calBlueSat = s.calBlueSat
        return k
    }

    static func isIdentity(_ s: EditSettings) -> Bool { key(s) == EditSettings() }

    static func channelTables(_ s: EditSettings, extraContrast: Double) -> ([Double], [Double], [Double]) {
        let n = 1024
        var base = [Double](repeating: 0, count: n)
        var run = 0.0
        for k in 0..<n {
            let x = Double(k) / Double(n - 1)
            let y = CMath.clamp(Tone.parametric(Tone.basic(x, s, extraContrast: extraContrast), s))
            run = max(run, y)
            base[k] = run
        }
        let master = Spline.table(s.curveRGB, n: n)
        func compose(_ c: [CurvePoint]) -> [Double] {
            let t = Spline.table(c, n: n)
            return base.map { Spline.lookup(t, Spline.lookup(master, $0)) }
        }
        return (compose(s.curveR), compose(s.curveG), compose(s.curveB))
    }

    static func calibrate(_ r0: Double, _ g0: Double, _ b0: Double, _ s: EditSettings) -> (Double, Double, Double) {
        var r = r0, g = g0, b = b0
        var (h, sl, l) = CMath.rgbToHsl(r, g, b)
        if sl > 1e-4 {
            let wr = max(0, 1 - CMath.hueDist(h, 0) / 120)
            let wg = max(0, 1 - CMath.hueDist(h, 120) / 120)
            let wb = max(0, 1 - CMath.hueDist(h, 240) / 120)
            h += (s.calRedHue * wr + s.calGreenHue * wg + s.calBlueHue * wb) / 100 * 25
            sl = CMath.clamp(sl * (1 + (s.calRedSat * wr + s.calGreenSat * wg + s.calBlueSat * wb) / 100 * 0.7))
            (r, g, b) = CMath.hslToRgb(h, sl, l)
        }
        if s.calShadowTint != 0 {
            let w = pow(1 - CMath.clamp(CMath.luma(r, g, b)), 3)
            let t = s.calShadowTint / 100
            g -= 0.08 * t * w; r += 0.04 * t * w; b += 0.04 * t * w
        }
        return (r, g, b)
    }

    /// Peso (0…1) con el que un color (HSL) pertenece al rango de un punto de color.
    static func pointWeight(_ h: Double, _ sl: Double, _ l: Double, target t: (Double, Double, Double), range: Double) -> Double {
        let tol = 0.04 + range / 100 * 0.36
        let dh = CMath.hueDist(h, t.0) / 180 * min(1, min(sl, t.1) * 3)
        let d = (dh * dh * 4 + (sl - t.1) * (sl - t.1) * 0.6 + (l - t.2) * (l - t.2) * 0.8).squareRoot()
        return 1 - CMath.smoothstep(tol * 0.4, tol, d)
    }

    /// Aplica los puntos de color: variación (acerca o aleja del color elegido) y desplazamientos de tono, saturación y luminancia.
    static func pointColor(_ r: Double, _ g: Double, _ b: Double, _ pts: [PointColor],
                           _ targets: [(Double, Double, Double)]) -> (Double, Double, Double) {
        var (h, sl, l) = CMath.rgbToHsl(CMath.clamp(r), CMath.clamp(g), CMath.clamp(b))
        var changed = false
        for (p, t) in zip(pts, targets) {
            let w = pointWeight(h, sl, l, target: t, range: p.range)
            guard w > 1e-4 else { continue }
            changed = true
            let v = p.variance / 100 * w
            var dh = h - t.0
            if dh > 180 { dh -= 360 } else if dh < -180 { dh += 360 }
            h += dh * v
            sl = CMath.clamp(sl + (sl - t.1) * v)
            h += p.hue / 100 * 40 * w
            sl = CMath.clamp(sl * (1 + p.sat / 100 * w))
            l = CMath.clamp(l + p.lum / 100 * 0.3 * w * (1 - abs(2 * l - 1) * 0.6))
        }
        return changed ? CMath.hslToRgb(h, sl, l) : (r, g, b)
    }

    static func pointTargets(_ pts: [PointColor]) -> [(Double, Double, Double)] {
        pts.map { $0.color.count == 3 ? CMath.rgbToHsl($0.color[0], $0.color[1], $0.color[2]) : (0, 0, 0.5) }
    }

    struct WheelOffset { var r = 0.0, g = 0.0, b = 0.0, lum = 0.0 }

    static func wheelOffset(_ w: GradeWheel) -> WheelOffset {
        let (hr, hg, hb) = CMath.hslToRgb(w.hue, 1, 0.5)
        let l = CMath.luma(hr, hg, hb)
        let k = w.sat / 100 * 0.3
        return WheelOffset(r: (hr - l) * k, g: (hg - l) * k, b: (hb - l) * k, lum: w.lum / 100 * 0.2)
    }

    static func build(_ s: EditSettings) -> Data {
        let n = size
        let look = s.profile.look
        let (tr, tg, tb) = channelTables(s, extraContrast: look.contrast)
        let satAmt = (s.saturation + look.sat) / 100, vib = s.vibrance / 100
        var hH = s.hslHue, hS = s.hslSat, hL = s.hslLum
        for i in 0..<8 { hS[i] += look.bandSat[i]; hL[i] += look.bandLum[i] }
        let hasHSL = (hH + hS + hL).contains { $0 != 0 }
        let mono = s.profile == .mono
        let hasCal = [s.calRedHue, s.calRedSat, s.calGreenHue, s.calGreenSat, s.calBlueHue, s.calBlueSat, s.calShadowTint].contains { $0 != 0 }
        let points = s.pointColors.filter { $0.hue != 0 || $0.sat != 0 || $0.lum != 0 || $0.variance != 0 }
        let targets = pointTargets(points)
        let wheels = [s.gradeShadows, s.gradeMidtones, s.gradeHighlights, s.gradeGlobal]
        let hasGrade = wheels.contains { $0.sat != 0 || $0.lum != 0 }
        let oS = wheelOffset(s.gradeShadows), oM = wheelOffset(s.gradeMidtones)
        let oH = wheelOffset(s.gradeHighlights), oG = wheelOffset(s.gradeGlobal)
        let bal = s.gradeBalance / 100, blend = s.gradeBlending / 100
        let pivot = 0.5 - 0.25 * bal, width = 0.08 + 0.42 * blend
        let midC = 0.5 - 0.15 * bal, midW = 0.12 + 0.22 * blend
        hH = hH.map { $0 / 100 * 30 }

        var out = [Float](repeating: 0, count: n * n * n * 4)
        let inv = 1.0 / Double(n - 1)
        var i = 0
        for bi in 0..<n {
            for gi in 0..<n {
                for ri in 0..<n {
                    var r = Double(ri) * inv, g = Double(gi) * inv, b = Double(bi) * inv
                    if !points.isEmpty { (r, g, b) = pointColor(r, g, b, points, targets) }
                    if hasCal { (r, g, b) = calibrate(r, g, b, s) }

                    r = Spline.lookup(tr, r); g = Spline.lookup(tg, g); b = Spline.lookup(tb, b)

                    if satAmt != 0 || vib != 0 {
                        let L = CMath.luma(r, g, b)
                        let cr = r - L, cg = g - L, cb = b - L
                        var f = 1 + satAmt
                        if vib != 0 {
                            let chroma = max(abs(cr), abs(cg), abs(cb))
                            let (h, _, _) = CMath.rgbToHsl(CMath.clamp(r), CMath.clamp(g), CMath.clamp(b))
                            let skin = 1 - 0.5 * CMath.bell(h, 30, 18)
                            f *= 1 + vib * (1 - CMath.clamp(chroma * 1.8)) * skin
                        }
                        f = max(0, f)
                        r = L + cr * f; g = L + cg * f; b = L + cb * f
                    }

                    if mono {
                        let (h, sl, _) = CMath.rgbToHsl(CMath.clamp(r), CMath.clamp(g), CMath.clamp(b))
                        var gray = CMath.luma(r, g, b)
                        gray += CMath.bandValue(s.bwMix, h) / 100 * 0.45 * sl
                        r = gray; g = gray; b = gray
                    } else if hasHSL {
                        var (h, sl, l) = CMath.rgbToHsl(CMath.clamp(r), CMath.clamp(g), CMath.clamp(b))
                        if sl > 1e-4 {
                            let (i0, i1, t) = CMath.bandWeights(h)
                            let strength = min(1, sl * 2)
                            h += (hH[i0] * (1 - t) + hH[i1] * t) * strength
                            sl = CMath.clamp(sl * (1 + (hS[i0] * (1 - t) + hS[i1] * t) / 100))
                            let dl = (hL[i0] * (1 - t) + hL[i1] * t) / 100
                            l = CMath.clamp(l + dl * 0.3 * strength * (1 - abs(2 * l - 1)))
                            (r, g, b) = CMath.hslToRgb(h, sl, l)
                        }
                    }

                    if hasGrade {
                        let L = CMath.clamp(CMath.luma(r, g, b))
                        let wh = CMath.smoothstep(pivot - width, pivot + width, L)
                        let ws = 1 - wh, wm = CMath.bell(L, midC, midW)
                        for (o, w) in [(oS, ws), (oM, wm), (oH, wh), (oG, 1.0)] {
                            r += (o.r + o.lum) * w; g += (o.g + o.lum) * w; b += (o.b + o.lum) * w
                        }
                    }

                    out[i] = Float(CMath.clamp(r)); out[i + 1] = Float(CMath.clamp(g)); out[i + 2] = Float(CMath.clamp(b)); out[i + 3] = 1
                    i += 4
                }
            }
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// LUT cuya salida es el peso de la máscara (gris) según el color o la luminancia de entrada.
    static func rangeMask(_ m: Mask) -> Data {
        let n = size
        var target: (Double, Double, Double)?
        if m.kind == .color, m.rangeColor.count == 3 { target = CMath.rgbToHsl(m.rangeColor[0], m.rangeColor[1], m.rangeColor[2]) }
        let tol = 0.05 + m.rangeTolerance / 100 * 0.45
        let lo = min(m.lumLow, m.lumHigh), hi = max(m.lumLow, m.lumHigh), f = max(0.5, m.lumSmooth / 100 * 25)
        var out = [Float](repeating: 0, count: n * n * n * 4)
        let inv = 1.0 / Double(n - 1)
        var i = 0
        for bi in 0..<n {
            for gi in 0..<n {
                for ri in 0..<n {
                    let r = Double(ri) * inv, g = Double(gi) * inv, b = Double(bi) * inv
                    var w = 0.0
                    if m.kind == .luminance {
                        let L = CMath.luma(r, g, b) * 100
                        w = CMath.smoothstep(lo - f, lo, L) * (1 - CMath.smoothstep(hi, hi + f, L))
                    } else if let (th, ts, tl) = target {
                        let (h, sl, l) = CMath.rgbToHsl(r, g, b)
                        let dh = CMath.hueDist(h, th) / 180 * min(1, min(sl, ts) * 3)
                        let d = (dh * dh * 4 + (sl - ts) * (sl - ts) * 0.6 + (l - tl) * (l - tl) * 0.8).squareRoot()
                        w = 1 - CMath.smoothstep(tol * 0.5, tol, d)
                    }
                    let e = Float(CMath.srgbEncode(w))
                    out[i] = e; out[i + 1] = e; out[i + 2] = e; out[i + 3] = 1
                    i += 4
                }
            }
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// LUT cuya salida es el peso (gris) de un punto de color: para visualizar su rango.
    static func pointMask(_ p: PointColor) -> Data {
        let n = size
        let t = pointTargets([p])[0]
        var out = [Float](repeating: 0, count: n * n * n * 4)
        let inv = 1.0 / Double(n - 1)
        var i = 0
        for bi in 0..<n {
            for gi in 0..<n {
                for ri in 0..<n {
                    let (h, sl, l) = CMath.rgbToHsl(Double(ri) * inv, Double(gi) * inv, Double(bi) * inv)
                    let e = Float(CMath.srgbEncode(pointWeight(h, sl, l, target: t, range: p.range)))
                    out[i] = e; out[i + 1] = e; out[i + 2] = e; out[i + 3] = 1
                    i += 4
                }
            }
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static let clipSize = 64

    /// LUT identidad que pinta de rojo los canales quemados y de azul el negro puro.
    static func clipWarning(high: Bool, low: Bool) -> Data {
        let n = clipSize
        var out = [Float](repeating: 0, count: n * n * n * 4)
        let inv = 1.0 / Double(n - 1)
        var i = 0
        for bi in 0..<n {
            for gi in 0..<n {
                for ri in 0..<n {
                    var c = (Float(Double(ri) * inv), Float(Double(gi) * inv), Float(Double(bi) * inv))
                    if high && (ri == n - 1 || gi == n - 1 || bi == n - 1) { c = (1, 0.12, 0.12) }
                    else if low && ri == 0 && gi == 0 && bi == 0 { c = (0.1, 0.4, 1) }
                    out[i] = c.0; out[i + 1] = c.1; out[i + 2] = c.2; out[i + 3] = 1
                    i += 4
                }
            }
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static let defringeSize = 17

    /// LUT que desatura franjas púrpura / verdes (se aplica solo en bordes).
    static func defringe(purple: Double, green: Double) -> Data {
        let n = defringeSize
        var out = [Float](repeating: 0, count: n * n * n * 4)
        let inv = 1.0 / Double(n - 1)
        var i = 0
        for bi in 0..<n {
            for gi in 0..<n {
                for ri in 0..<n {
                    var r = Double(ri) * inv, g = Double(gi) * inv, b = Double(bi) * inv
                    let (h, sl, l) = CMath.rgbToHsl(r, g, b)
                    let wp = CMath.bell(CMath.hueDist(h, 285), 0, 35), wg = CMath.bell(CMath.hueDist(h, 110), 0, 35)
                    let f = 1 - CMath.clamp(purple / 20 * wp + green / 20 * wg)
                    (r, g, b) = CMath.hslToRgb(h, sl * f, l)
                    out[i] = Float(r); out[i + 1] = Float(g); out[i + 2] = Float(b); out[i + 3] = 1
                    i += 4
                }
            }
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

// MARK: - Motor de revelado (Core Image)

extension CIImage {
    func normalized() -> CIImage { transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)) }
    func exposure(_ ev: Double) -> CIImage { ev == 0 ? self : applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev]) }
    func blurred(_ r: CGFloat) -> CIImage { clampedToExtent().applyingGaussianBlur(sigma: Double(r)).cropped(to: extent) }
    func unsharp(_ r: CGFloat, _ i: Double) -> CIImage {
        clampedToExtent().applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: r, kCIInputIntensityKey: i]).cropped(to: extent)
    }
    func dissolve(to target: CIImage, _ t: Double) -> CIImage {
        applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: target, kCIInputTimeKey: t])
    }
    func gainBias(_ gain: CGFloat, _ bias: CGFloat) -> CIImage {
        applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
        ])
    }
    /// Usa el canal rojo como gris y aplica ganancia/desplazamiento.
    func redAsGray(_ gain: CGFloat, _ bias: CGFloat) -> CIImage {
        let v = CIVector(x: gain, y: 0, z: 0, w: 0)
        return applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": v, "inputGVector": v, "inputBVector": v,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
        ])
    }
    /// Toma solo la luminancia de esta imagen y el color de `background` (evita halos de color).
    func luminance(over background: CIImage, limit: CGFloat = 1) -> CIImage {
        guard limit > 1 else {
            return applyingFilter("CIColorClamp").applyingFilter("CILuminosityBlendMode", parameters: [
                kCIInputBackgroundImageKey: background.applyingFilter("CIColorClamp"),
            ])
        }
        // HDR: CILuminosityBlendMode recorta en 1, así que se escala el color de fondo por el cociente de luminancias
        func luma(_ i: CIImage) -> CIImage {
            let v = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
            return i.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": v, "inputGVector": v, "inputBVector": v, "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 0.01, y: 0.01, z: 0.01, w: 0),
            ])
        }
        let ratio = luma(self).times(luma(background).applyingFilter("CIGammaAdjust", parameters: ["inputPower": -1]))
            .applyingFilter("CIColorClamp", parameters: ["inputMaxComponents": CIVector(x: 4, y: 4, z: 4, w: 1)])
        return background.times(ratio).clamped(to: limit)
    }
    /// Limita los valores a 0…`limit` (en HDR las luces pueden pasar del blanco SDR).
    func clamped(to limit: CGFloat) -> CIImage {
        applyingFilter("CIColorClamp", parameters: ["inputMaxComponents": CIVector(x: limit, y: limit, z: limit, w: 1)])
    }
    func times(_ other: CIImage) -> CIImage {
        applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: other])
    }
    /// 1 / x (CIDivideBlendMode satura en 1; una potencia −1 no).
    func reciprocal() -> CIImage {
        gainBias(1, 0.002).applyingFilter("CIGammaAdjust", parameters: ["inputPower": -1])
    }
    func masked(over background: CIImage, mask: CIImage) -> CIImage {
        applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: background, kCIInputMaskImageKey: mask])
    }
}

let sRGBSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
let extendedSRGBSpace = CGColorSpace(name: CGColorSpace.extendedSRGB)!

final class Engine: @unchecked Sendable {
    struct Request {
        var url: URL
        var isRAW: Bool
        var settings: EditSettings
        var maxPixel: CGFloat?      // nil = resolución completa
        var cropEditing = false     // true = sin aplicar el recorte (modo herramienta Recortar)
        var fresh = false           // true = sin cachés (exportación)
        var overlayMask: UUID?      // máscara a resaltar en rojo
        var overlayPoint: PointColor? // punto de color cuyo rango se resalta en rojo
        var clipHigh = false        // aviso de luces quemadas
        var clipLow = false         // aviso de sombras empastadas
        var stopBeforeMasks = false // devuelve la imagen justo antes de las máscaras (para muestrear color)
    }

    struct Result {
        var image: CGImage
        var histogramSource: CGImage?
        var fullSize: CGSize
        var asShot: WhitePoint?
    }

    private struct RawKey: Equatable {
        var url: URL, scale: CGFloat, temp: Double, tint: Double
        var nrL: Double, nrC: Double, nrS: Double, nrD: Double, nrK: Double, lens: Bool, hdr: Bool
    }

    /// Se crea uno nuevo al cambiar de foto: Core Image guarda una reserva de texturas por cada tamaño de imagen
    /// y, al recorrer muchas fotos seguidas, la memoria llegaba a 2–3 GB hasta que la soltaba sola.
    private(set) var ctx = Engine.makeContext()
    private var contextURL: URL?

    private static func makeContext() -> CIContext {
        CIContext(options: [.workingColorSpace: linearSpace, .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
    }
    private var rawFilters: [URL: (CIRAWFilter, WhitePoint)] = [:]
    private var rawCache: (key: RawKey, image: CIImage)?
    private var bitmapCache: (url: URL, maxPx: Int, hdr: Bool, image: CIImage, full: CGSize)?
    private var lutKey: EditSettings?
    private var lutData = Data()
    private var defringeKey: [Double] = []
    private var defringeData = Data()
    private var lastOverlay: CIImage?
    private var clipKey: [Double] = []
    private var clipData = Data()
    private var rangeCache: [UUID: (key: [Double], data: Data)] = [:]
    /// Valor máximo de la imagen en esta pasada: 1 en SDR, 2^rango en HDR.
    private var limit: CGFloat = 1
    private var pointMaskCache: (key: [Double], data: Data)?

    // MARK: Base (decodificación)

    private func rawFilter(_ url: URL, fresh: Bool) -> (CIRAWFilter, WhitePoint)? {
        if !fresh, let f = rawFilters[url] { return f }
        guard let f = CIRAWFilter(imageURL: url) else { return nil }
        let shot = WhitePoint(temp: Double(f.neutralTemperature), tint: Double(f.neutralTint))
        if !fresh {
            if rawFilters.count > 6 { rawFilters.removeAll() }
            rawFilters[url] = (f, shot)
        }
        return (f, shot)
    }

    func asShot(for url: URL) -> WhitePoint? { rawFilters[url]?.1 }

    private func rawBase(_ req: Request) -> (CIImage, CGFloat)? {
        let s = req.settings
        guard let (raw, shot) = rawFilter(req.url, fresh: req.fresh) else { return nil }
        let native = raw.nativeSize
        let longE = max(native.width, native.height, 1)
        let scale = req.maxPixel.map { min(1, $0 / longE) } ?? 1
        let key = RawKey(url: req.url, scale: scale, temp: s.temp, tint: s.tint, nrL: s.nrLuminance, nrC: s.nrColor,
                         nrS: s.nrColorSmooth, nrD: s.nrDetail, nrK: s.nrContrast, lens: s.lensProfile || s.removeCA, hdr: s.hdr)
        if !req.fresh, let c = rawCache, c.key == key { return (c.image, scale) }

        raw.scaleFactor = Float(scale)
        raw.exposure = 0
        raw.neutralTemperature = Float(shot.temp * pow(2, s.temp / 60))
        raw.neutralTint = Float(shot.tint + s.tint * 1.5)
        if raw.isLuminanceNoiseReductionSupported { raw.luminanceNoiseReductionAmount = Float(s.nrLuminance / 100) }
        if raw.isColorNoiseReductionSupported {
            raw.colorNoiseReductionAmount = Float(min(1, s.nrColor / 100 * (0.7 + 0.6 * s.nrColorSmooth / 100)))
        }
        if raw.isDetailSupported { raw.detailAmount = Float(s.nrDetail / 100) }
        if raw.isContrastSupported { raw.contrastAmount = Float(s.nrContrast / 100) }
        if raw.isSharpnessSupported { raw.sharpnessAmount = 0 }
        if raw.isLensCorrectionSupported { raw.isLensCorrectionEnabled = s.lensProfile || s.removeCA }
        raw.extendedDynamicRangeAmount = s.hdr ? 2 : 0
        guard let out = raw.outputImage?.normalized() else { return nil }
        if req.fresh { return (out, scale) }
        // Se cachea el RAW revelado: mover cualquier deslizador que no sea de RAW no vuelve a decodificar.
        guard let cg = ctx.createCGImage(out, from: out.extent, format: .RGBAh, colorSpace: linearSpace) else { return (out, scale) }
        let img = CIImage(cgImage: cg)
        rawCache = (key, img)
        return (img, scale)
    }

    private func bitmapBase(_ req: Request) -> (CIImage, CGFloat)? {
        let url = req.url
        let full = Self.pixelSize(url)
        let hdr = req.settings.hdr
        if req.fresh {
            guard let img = Self.loadBitmap(url, hdr: hdr) else { return nil }
            return (img.normalized(), 1)
        }
        let maxPx = req.maxPixel.map { Int(($0 / 256).rounded(.up) * 256) } ?? 0
        if let c = bitmapCache, c.url == url, c.maxPx == maxPx, c.hdr == hdr {
            return (c.image, c.image.extent.width / max(1, c.full.width))
        }
        var cg: CGImage?
        if hdr, let big = Self.loadBitmap(url, hdr: true)?.normalized() {
            // Fotos con mapa de ganancia (iPhone, HEIC/JPEG HDR): se conservan las luces por encima del blanco
            let k = maxPx > 0 ? min(1, CGFloat(maxPx) / max(big.extent.width, big.extent.height)) : 1
            let small = big.transformed(by: CGAffineTransform(scaleX: k, y: k))
            cg = ctx.createCGImage(small, from: small.extent.integral, format: .RGBAh, colorSpace: linearSpace)
        } else if maxPx > 0, let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPx,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        } else if let img = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) {
            let n = img.normalized()
            cg = ctx.createCGImage(n, from: n.extent, format: .RGBA8, colorSpace: sRGBSpace)
        }
        guard let cg else { return nil }
        let img = CIImage(cgImage: cg)
        bitmapCache = (url, maxPx, hdr, img, full)
        return (img, img.extent.width / max(1, full.width))
    }

    private static func loadBitmap(_ url: URL, hdr: Bool) -> CIImage? {
        if hdr, #available(macOS 15, *) {
            return CIImage(contentsOf: url, options: [.applyOrientationProperty: true, .expandToHDR: true])
        }
        return CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
    }

    static func pixelSize(_ url: URL) -> CGSize {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return .zero }
        let w = p[kCGImagePropertyPixelWidth] as? Int ?? 0, h = p[kCGImagePropertyPixelHeight] as? Int ?? 0
        let o = p[kCGImagePropertyOrientation] as? Int ?? 1
        return o >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    private func base(_ req: Request) -> (CIImage, CGFloat)? {
        let s = req.settings
        if req.isRAW, let (img, sc) = rawBase(req) { return (img.exposure(s.exposure), sc) }
        guard var (img, sc) = bitmapBase(req) else { return nil }
        img = img.exposure(s.exposure)
        if s.temp != 0 || s.tint != 0 {
            img = img.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500 * pow(2, s.temp / 70), y: s.tint),
                "inputTargetNeutral": CIVector(x: 6500, y: 0),
            ])
        }
        if s.nrLuminance > 0 {
            img = img.clampedToExtent().applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": 0.005 + s.nrLuminance / 100 * 0.06,
                "inputSharpness": 0.2 + s.nrDetail / 100 * 1.5,
            ]).cropped(to: img.extent)
            if s.nrContrast > 0 { img = img.unsharp(max(1, 2 * sc), s.nrContrast / 100 * 0.4) }
        }
        if s.nrColor > 0 {
            let radius = max(0.5, (1 + s.nrColor / 100 * 6 * (0.5 + s.nrColorSmooth / 100)) * sc)
            var chroma = img.blurred(radius).applyingFilter("CIColorBlendMode", parameters: [kCIInputBackgroundImageKey: img])
            if s.nrColorDetail > 0 { chroma = chroma.dissolve(to: img, s.nrColorDetail / 100 * 0.5) }
            img = chroma
        }
        return (img, sc)
    }

    // MARK: Pasos del revelado

    private func distort(_ img: CIImage, _ amount: Double) -> CIImage {
        let e = img.extent
        return img.clampedToExtent().applyingFilter("CIBumpDistortion", parameters: [
            kCIInputCenterKey: CIVector(x: e.midX, y: e.midY),
            kCIInputRadiusKey: hypot(e.width, e.height) / 2 * 1.05,
            kCIInputScaleKey: -amount / 100 * 0.35,
        ]).cropped(to: e)
    }

    private func vignette(_ img: CIImage, amount: Double, midpoint: Double, roundness: Double, feather: Double, highlights: Double) -> CIImage {
        guard amount != 0 else { return img }
        let e = img.extent
        let m = midpoint / 100, f = feather / 100, r = roundness / 100
        var rx = e.width / 2, ry = e.height / 2
        if r > 0 {
            let c = (rx * ry).squareRoot()
            rx += (c - rx) * r; ry += (c - ry) * r
        } else if r < 0 {
            rx *= 1 - r * 0.15; ry *= 1 - r * 0.15
        }
        let center = 0.45 + 0.75 * m
        let inner = max(0, center - 0.5 * f - 0.02), outer = center + 0.5 * f + 0.02
        guard let grad = CIFilter(name: "CIRadialGradient", parameters: [
            kCIInputCenterKey: CIVector(x: 0, y: 0),
            "inputRadius0": inner * 1000, "inputRadius1": outer * 1000,
            "inputColor0": CIColor(red: 0, green: 0, blue: 0), "inputColor1": CIColor(red: 1, green: 1, blue: 1),
        ])?.outputImage else { return img }
        let mask = grad.transformed(by: CGAffineTransform(scaleX: rx / 1000, y: ry / 1000)
            .concatenating(CGAffineTransform(translationX: e.midX, y: e.midY))).cropped(to: e)
        let a = amount / 100
        var effect: CIImage
        if a < 0 {
            effect = img.exposure(a * 2.2)
            if highlights > 0 {
                let lum = img.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
                    .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 0.6])
                    .gainBias(highlights / 100, 0).applyingFilter("CIColorClamp")
                effect = img.masked(over: effect, mask: lum)
            }
        } else {
            effect = img.gainBias(1 - a * 0.85, a * 0.85)
        }
        return effect.masked(over: img, mask: mask)
    }

    private func edgeMask(_ img: CIImage, threshold: Double, blur: CGFloat) -> CIImage {
        let gray = img.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        let edges = gray.clampedToExtent().applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 6]).cropped(to: img.extent)
        let gain = 1 + threshold * 12
        return edges.blurred(blur).redAsGray(gain, -threshold * 0.6).applyingFilter("CIColorClamp")
    }

    private func geometry(_ input: CIImage, _ s: EditSettings) -> CIImage {
        if s.vertical == 0 && s.horizontal == 0 && s.rotate == 0 && s.aspect == 0 && s.scale == 100 && s.offsetX == 0 && s.offsetY == 0 {
            return input
        }
        let ext = input.extent, w = ext.width, h = ext.height
        var img = input
        if s.vertical != 0 || s.horizontal != 0 {
            var tl = CGPoint(x: 0, y: h), tr = CGPoint(x: w, y: h), bl = CGPoint.zero, br = CGPoint(x: w, y: 0)
            let kv = 0.3 * abs(s.vertical) / 100 * w
            if s.vertical > 0 { tl.x -= kv; tr.x += kv } else if s.vertical < 0 { bl.x -= kv; br.x += kv }
            let kh = 0.3 * abs(s.horizontal) / 100 * h
            if s.horizontal > 0 { tl.y += kh; bl.y -= kh } else if s.horizontal < 0 { tr.y += kh; br.y -= kh }
            img = img.applyingFilter("CIPerspectiveTransform", parameters: [
                "inputTopLeft": CIVector(cgPoint: tl), "inputTopRight": CIVector(cgPoint: tr),
                "inputBottomLeft": CIVector(cgPoint: bl), "inputBottomRight": CIVector(cgPoint: br),
            ])
            let e = img.extent
            img = img.transformed(by: CGAffineTransform(translationX: w / 2 - e.midX, y: h / 2 - e.midY))
        }
        let a = s.aspect / 100
        let sx = (a > 0 ? 1 + a * 0.5 : 1) * s.scale / 100, sy = (a < 0 ? 1 - a * 0.5 : 1) * s.scale / 100
        let t = CGAffineTransform(translationX: -w / 2, y: -h / 2)
            .concatenating(CGAffineTransform(scaleX: sx, y: sy))
            .concatenating(CGAffineTransform(rotationAngle: -s.rotate * .pi / 180))
            .concatenating(CGAffineTransform(translationX: w / 2 + s.offsetX / 100 * w * 0.5, y: h / 2 - s.offsetY / 100 * h * 0.5))
        let bg = CIImage(color: CIColor(red: 0.06, green: 0.06, blue: 0.06)).cropped(to: ext)
        return img.transformed(by: t).composited(over: bg).cropped(to: ext)
    }

    private func straighten(_ img: CIImage, _ deg: Double) -> CIImage {
        guard deg != 0 else { return img }
        let ext = img.extent, w = ext.width, h = ext.height
        let a = abs(deg) * .pi / 180
        // Escala mínima para que no aparezcan esquinas vacías.
        let sc = max((w * cos(a) + h * sin(a)) / w, (w * sin(a) + h * cos(a)) / h)
        let t = CGAffineTransform(translationX: -w / 2, y: -h / 2)
            .concatenating(CGAffineTransform(scaleX: sc, y: sc))
            .concatenating(CGAffineTransform(rotationAngle: -deg * .pi / 180))
            .concatenating(CGAffineTransform(translationX: w / 2, y: h / 2))
        return img.clampedToExtent().transformed(by: t).cropped(to: ext)
    }

    private func crop(_ img: CIImage, _ s: EditSettings) -> CIImage {
        if s.cropX == 0 && s.cropY == 0 && s.cropW == 1 && s.cropH == 1 { return img }
        let e = img.extent
        let r = CGRect(x: e.minX + s.cropX * e.width, y: e.minY + (1 - s.cropY - s.cropH) * e.height,
                       width: s.cropW * e.width, height: s.cropH * e.height).integral.intersection(e)
        guard r.width >= 1, r.height >= 1 else { return img }
        return img.cropped(to: r).normalized()
    }

    private func applyCube(_ img: CIImage, _ data: Data, _ n: Int) -> CIImage {
        img.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": n, "inputCubeData": data, "inputColorSpace": sRGBSpace,
        ])
    }

    private func grain(_ img: CIImage, _ s: EditSettings, _ scale: CGFloat) -> CIImage {
        guard s.grainAmount > 0, let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return img }
        let e = img.extent
        let size = max(0.5, (0.6 + s.grainSize / 100 * 3.0) * scale)
        let rough = s.grainRoughness / 100
        let k = s.grainAmount / 100 * (0.35 + (1 - rough) * 0.4)
        let blurred = noise.redAsGray(1, 0)
            .transformed(by: CGAffineTransform(scaleX: size, y: size))
            .applyingGaussianBlur(sigma: (1 - rough) * size * 0.6 + 0.2)
        if limit > 1 {
            // En HDR la luz suave recortaría las luces: el grano es un factor alrededor de 1 (0…2× la imagen).
            // El ruido trae un alfa aleatorio: se hace opaco antes de la matriz de color, que si no lo divide y oscurece
            let f = blurred.cropped(to: e).settingAlphaOne(in: e).gainBias(k, 0.5 - 0.5 * k)
            return img.gainBias(2, 0).masked(over: img.gainBias(0, 0), mask: f)
        }
        let g = blurred.gainBias(k, 0.5 - 0.5 * k).cropped(to: e)
        return g.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: img])
    }

    // MARK: Pipeline

    func pipeline(_ req: Request) -> (CIImage, CGSize)? {
        if req.url != contextURL {
            if contextURL != nil { ctx = Self.makeContext() }
            contextURL = req.url
        }
        guard var (img, scale) = base(req) else { return nil }
        let s = req.settings
        limit = s.hdr ? CGFloat(pow(2, s.hdrHeadroom)) : 1
        img = img.normalized()
        if s.flipH { img = img.oriented(.upMirrored) }
        switch s.rotation90 & 3 {
        case 1: img = img.oriented(.right)
        case 2: img = img.oriented(.down)
        case 3: img = img.oriented(.left)
        default: break
        }
        img = img.normalized()
        let full = CGSize(width: img.extent.width / scale, height: img.extent.height / scale)

        // Óptica
        if s.distortion != 0 { img = distort(img, s.distortion) }
        img = vignette(img, amount: s.lensVignette, midpoint: s.lensVignetteMid, roundness: 0, feather: 50, highlights: 0)
        let purple = s.defringePurple + (s.removeCA && !req.isRAW ? 3 : 0)
        let green = s.defringeGreen + (s.removeCA && !req.isRAW ? 3 : 0)
        if purple > 0 || green > 0 {
            if defringeKey != [purple, green] {
                defringeData = LUTBuilder.defringe(purple: purple, green: green)
                defringeKey = [purple, green]
            }
            let fixed = applyCube(img, defringeData, LUTBuilder.defringeSize)
            img = fixed.masked(over: img, mask: edgeMask(img, threshold: 0.1, blur: max(1, 2 * scale)))
        }

        // Geometría, enderezado y recorte
        img = geometry(img, s)
        img = straighten(img, s.cropAngle)
        if !s.heals.isEmpty { img = applyHeals(img, s.heals) }
        if !req.cropEditing { img = crop(img, s) }

        let rel = max(img.extent.width, img.extent.height) / 1000

        // Tono local
        if s.shadows != 0 || s.highlights < 0 {
            img = img.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputShadowAmount": s.shadows / 100 * 0.9,
                "inputHighlightAmount": 1 + min(0, s.highlights) / 100 * 0.75,
                kCIInputRadiusKey: 2.5,
            ])
        }

        // Presencia
        img = presence(img, texture: s.texture, clarity: s.clarity, dehaze: s.dehaze, scale: scale, rel: rel)

        if req.stopBeforeMasks { return (img, full) }

        // Máscaras (ajustes locales)
        var overlay: CIImage?
        if !s.masks.isEmpty {
            (img, overlay) = applyMasks(img, s, cropEditing: req.cropEditing, scale: scale, rel: rel, overlayID: req.overlayMask)
        }
        if let p = req.overlayPoint {
            let key = p.color + [p.range]
            if pointMaskCache?.key != key { pointMaskCache = (key, LUTBuilder.pointMask(p)) }
            if let data = pointMaskCache?.data { overlay = applyCube(img.applyingFilter("CIColorClamp"), data, LUTBuilder.size) }
        }

        // Color global: perfil, curvas, HSL, B/N, gradación, calibración
        if !LUTBuilder.isIdentity(s) {
            let key = LUTBuilder.key(s)
            if key != lutKey { lutData = LUTBuilder.build(s); lutKey = key }
            if s.hdr {
                // La LUT solo ve 0…1: se aplica al color normalizado por su canal máximo y luego se recupera ese exceso
                let gain = img.applyingFilter("CIMaximumComponent").applyingFilter("CIColorClamp", parameters: [
                    "inputMinComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
                    "inputMaxComponents": CIVector(x: limit, y: limit, z: limit, w: 1),
                ])
                img = applyCube(img.times(gain.reciprocal()), lutData, LUTBuilder.size).times(gain)
            } else {
                img = applyCube(img, lutData, LUTBuilder.size)
            }
        }

        // Enfoque
        if s.sharpAmount > 0 {
            let a = s.sharpAmount / 150, det = s.sharpDetail / 100
            let r = max(0.5, s.sharpRadius * scale)
            var sharp = img.unsharp(r, a * 1.6 * (1 - 0.5 * det))
            if det > 0 { sharp = sharp.unsharp(max(0.4, r * 0.5), a * 1.2 * det) }
            if s.sharpMasking > 0 {
                sharp = sharp.masked(over: img, mask: edgeMask(img, threshold: s.sharpMasking / 100, blur: max(1, 1.5 * scale)))
            }
            img = sharp.luminance(over: img, limit: limit)
        }

        // Efectos
        img = vignette(img, amount: s.vigAmount, midpoint: s.vigMidpoint, roundness: s.vigRoundness,
                       feather: s.vigFeather, highlights: s.vigHighlights)
        img = grain(img, s, scale)

        if s.hdr { img = img.clamped(to: limit) }
        lastOverlay = overlay
        return (img.cropped(to: img.extent.integral), full)
    }

    /// Capas solo de visualización: aviso de recorte y superposición roja de la máscara.
    private func decorate(_ input: CIImage, _ req: Request, overlay: CIImage?) -> CIImage {
        var img = input
        if req.clipHigh || req.clipLow {
            let key = [req.clipHigh ? 1.0 : 0, req.clipLow ? 1.0 : 0]
            if clipKey != key { clipData = LUTBuilder.clipWarning(high: req.clipHigh, low: req.clipLow); clipKey = key }
            img = applyCube(img.applyingFilter("CIColorClamp"), clipData, LUTBuilder.clipSize)
        }
        if let overlay {
            let red = CIImage(color: CIColor(red: 1, green: 0.12, blue: 0.12)).cropped(to: img.extent)
            img = red.masked(over: img.applyingFilter("CIColorClamp"), mask: overlay.gainBias(0.45, 0))
        }
        return img
    }

    // MARK: Presencia y ajustes locales

    private func presence(_ input: CIImage, texture: Double, clarity: Double, dehaze: Double, scale: CGFloat, rel: CGFloat) -> CIImage {
        var img = input
        if dehaze != 0 {
            let d = dehaze / 100
            if d > 0 {
                let k = 0.035 * d
                img = img.gainBias(1 / (1 - k), -k / (1 - k))
                    .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1 + 0.3 * d, kCIInputContrastKey: 1 + 0.08 * d])
                img = img.unsharp(60 * rel, 0.25 * d).luminance(over: img, limit: limit)
            } else {
                let a = -d * 0.4
                img = img.gainBias(1 - a, a * 0.55)
                    .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1 + 0.35 * d, kCIInputContrastKey: 1 + 0.1 * d])
            }
        }
        if clarity != 0 {
            let c = clarity / 100
            let local = c > 0 ? img.unsharp(20 * rel, 0.6 * c) : img.dissolve(to: img.blurred(8 * rel), -c * 0.6)
            img = local.luminance(over: img, limit: limit)
        }
        if texture != 0 {
            let t = texture / 100
            let local = t > 0 ? img.unsharp(max(0.8, 4 * scale), 0.9 * t) : img.dissolve(to: img.blurred(max(0.5, 2.5 * scale)), -t * 0.7)
            img = local.luminance(over: img, limit: limit)
        }
        return img
    }

    private func localAdjust(_ input: CIImage, _ a: MaskAdjust, scale: CGFloat, rel: CGFloat) -> CIImage {
        var img = input
        if a.temp != 0 || a.tint != 0 {
            img = img.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500 * pow(2, a.temp / 70), y: a.tint),
                "inputTargetNeutral": CIVector(x: 6500, y: 0),
            ])
        }
        img = img.exposure(a.exposure * 2)
        if a.contrast != 0 || a.highlights != 0 || a.shadows != 0 || a.whites != 0 || a.blacks != 0 {
            // Curva de 5 puntos en espacio perceptual
            let c = a.contrast / 100, h = a.highlights / 100, sh = a.shadows / 100, w = a.whites / 100, b = a.blacks / 100
            func v(_ x: Double, _ y: Double) -> CIVector { CIVector(x: x, y: CMath.clamp(y)) }
            img = img.applyingFilter("CILinearToSRGBToneCurve")
                .applyingFilter("CIToneCurve", parameters: [
                    "inputPoint0": v(0, max(0, b) * 0.15),
                    "inputPoint1": v(0.25, 0.25 + sh * 0.15 + min(0, b) * 0.1 - c * 0.06),
                    "inputPoint2": v(0.5, 0.5 + (sh + h) * 0.04),
                    "inputPoint3": v(0.75, 0.75 + h * 0.15 + max(0, w) * 0.1 + c * 0.06),
                    "inputPoint4": v(1, 1 + min(0, w) * 0.15),
                ])
                .applyingFilter("CISRGBToneCurveToLinear")
        }
        img = presence(img, texture: a.texture, clarity: a.clarity, dehaze: a.dehaze, scale: scale, rel: rel)
        if a.sharpness != 0 {
            let k = a.sharpness / 100
            let local = k > 0 ? img.unsharp(max(0.6, 1.2 * scale), 1.5 * k) : img.dissolve(to: img.blurred(max(0.5, 3 * scale)), -k)
            img = local.luminance(over: img, limit: limit)
        }
        if a.noise > 0 {
            img = img.clampedToExtent().applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": 0.005 + a.noise / 100 * 0.06, "inputSharpness": 0.4,
            ]).cropped(to: input.extent)
        }
        if a.saturation != 0 {
            img = img.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1 + a.saturation / 100])
        }
        if a.colorSat > 0 {
            let (r, g, b) = CMath.hslToRgb(a.colorHue, 1, 0.5)
            let l = CMath.luma(r, g, b), k = a.colorSat / 100 * 0.8
            img = img.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1 + (r - l) * k, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1 + (g - l) * k, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1 + (b - l) * k, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
        }
        return img
    }

    private var rasterCache: [UUID: (key: Int, image: CIImage)] = [:]

    /// Máscara rasterizada (pincel o sujeto) en el espacio normalizado de la imagen sin recortar.
    private func maskRaster(_ m: Mask, aspect: Double) -> CIImage? {
        var hasher = Hasher()
        hasher.combine(m.kind)
        if m.kind == .brush { hasher.combine(m.strokes); hasher.combine(Int(aspect * 1000)) } else { hasher.combine(m.raster) }
        let key = hasher.finalize()
        if let c = rasterCache[m.id], c.key == key { return c.image }
        let cg: CGImage?
        if m.kind == .brush {
            cg = MaskRaster.brush(m.strokes, aspect: aspect)
        } else if let data = m.raster, let src = CGImageSourceCreateWithData(data as CFData, nil) {
            cg = CGImageSourceCreateImageAtIndex(src, 0, nil)?.copy(colorSpace: CGColorSpace(name: CGColorSpace.linearGray)!)
        } else {
            cg = nil
        }
        guard let cg else { return nil }
        let img = CIImage(cgImage: cg)
        rasterCache[m.id] = (key, img)
        return img
    }

    private func applyMasks(_ input: CIImage, _ s: EditSettings, cropEditing: Bool, scale: CGFloat, rel: CGFloat,
                            overlayID: UUID?) -> (CIImage, CIImage?) {
        var img = input
        let e = img.extent
        let cropped = !cropEditing && !(s.cropX == 0 && s.cropY == 0 && s.cropW == 1 && s.cropH == 1)
        let ox = cropped ? s.cropX : 0, oy = cropped ? s.cropY : 0
        let cw = cropped ? s.cropW : 1, ch = cropped ? s.cropH : 1
        let preW = e.width / cw, preH = e.height / ch
        func px(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: (x - ox) * preW, y: e.height - (y - oy) * preH) }
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: e)
        let white = CIColor(red: 1, green: 1, blue: 1), dark = CIColor(red: 0, green: 0, blue: 0)
        var overlay: CIImage?

        for m in s.masks {
            let showOverlay = m.id == overlayID
            guard m.enabled || showOverlay else { continue }
            var mask: CIImage?
            switch m.kind {
            case .linear:
                mask = CIFilter(name: "CILinearGradient", parameters: [
                    "inputPoint0": CIVector(cgPoint: px(m.x0, m.y0)), "inputPoint1": CIVector(cgPoint: px(m.x1, m.y1)),
                    "inputColor0": white, "inputColor1": dark,
                ])?.outputImage
            case .radial:
                let inner = 1 - CMath.clamp(m.feather / 100) * 0.95
                let t = CGAffineTransform(scaleX: m.rx * preW / 1000, y: m.ry * preH / 1000)
                    .concatenating(CGAffineTransform(rotationAngle: -m.angle * .pi / 180))
                    .concatenating(CGAffineTransform(translationX: px(m.cx, m.cy).x, y: px(m.cx, m.cy).y))
                mask = CIFilter(name: "CIRadialGradient", parameters: [
                    kCIInputCenterKey: CIVector(x: 0, y: 0), "inputRadius0": inner * 1000, "inputRadius1": 1000,
                    "inputColor0": white, "inputColor1": dark,
                ])?.outputImage?.transformed(by: t)
            case .color, .luminance:
                if m.kind == .luminance || m.rangeColor.count == 3 {
                    let key = m.rangeColor + [m.kind == .color ? 1 : 0, m.rangeTolerance, m.lumLow, m.lumHigh, m.lumSmooth]
                    if rangeCache[m.id]?.key != key { rangeCache[m.id] = (key, LUTBuilder.rangeMask(m)) }
                    if let data = rangeCache[m.id]?.data {
                        mask = applyCube(img.applyingFilter("CIColorClamp"), data, LUTBuilder.size)
                    }
                }
            case .brush, .subject, .people, .background:
                if let r = maskRaster(m, aspect: Double(preW / preH)) {
                    let t = CGAffineTransform(scaleX: preW / r.extent.width, y: preH / r.extent.height)
                        .concatenating(CGAffineTransform(translationX: -ox * preW, y: -(1 - oy - ch) * preH))
                    mask = r.transformed(by: t)
                }
            }
            guard var mk = mask?.cropped(to: e).composited(over: black) else { continue }
            if m.invert { mk = mk.applyingFilter("CIColorInvert") }
            if showOverlay { overlay = mk }
            if m.enabled && m.adjust != MaskAdjust() {
                img = localAdjust(img, m.adjust, scale: scale, rel: rel).masked(over: img, mask: mk)
            }
        }
        return (img, overlay)
    }

    /// Herramienta Eliminar: clona el origen sobre el destino y, en modo Corregir, adapta su tono y luz
    /// a los alrededores del destino (convolución normalizada para que la mancha no contamine el resultado).
    private func applyHeals(_ input: CIImage, _ heals: [HealSpot]) -> CIImage {
        var img = input
        let e = img.extent, W = e.width, H = e.height, long = max(W, H)
        let white = CIColor(red: 1, green: 1, blue: 1), dark = CIColor(red: 0, green: 0, blue: 0)
        for h in heals {
            let r = max(1, h.size * long)
            let d = CGPoint(x: h.x * W, y: (1 - h.y) * H), src = CGPoint(x: h.sx * W, y: (1 - h.sy) * H)
            let region = CGRect(x: d.x - r * 1.5, y: d.y - r * 1.5, width: r * 3, height: r * 3).intersection(e).integral
            guard !region.isEmpty else { continue }
            let base = img.clampedToExtent()
            let shifted = base.transformed(by: CGAffineTransform(translationX: d.x - src.x, y: d.y - src.y))
            var patch = shifted
            if h.mode == .heal {
                let sigma = Double(r) * 0.75
                let area = region.insetBy(dx: -CGFloat(sigma) * 3, dy: -CGFloat(sigma) * 3)
                guard let outside = CIFilter(name: "CIRadialGradient", parameters: [
                    kCIInputCenterKey: CIVector(cgPoint: d), "inputRadius0": r, "inputRadius1": r * 1.15,
                    "inputColor0": dark, "inputColor1": white,
                ])?.outputImage?.cropped(to: area) else { continue }
                func lowFreq(_ x: CIImage) -> CIImage { x.cropped(to: area).times(outside).applyingGaussianBlur(sigma: sigma) }
                let den = outside.applyingGaussianBlur(sigma: sigma).reciprocal()
                let lfDst = lowFreq(base).times(den), lfSrc = lowFreq(shifted).times(den)
                let ratio = lfDst.times(lfSrc.reciprocal())
                    .applyingFilter("CIColorClamp", parameters: ["inputMaxComponents": CIVector(x: 8, y: 8, z: 8, w: 1)])
                patch = shifted.times(ratio)
            }
            guard let mask = CIFilter(name: "CIRadialGradient", parameters: [
                kCIInputCenterKey: CIVector(cgPoint: d), "inputRadius0": r * (1 - CMath.clamp(h.feather / 100) * 0.8), "inputRadius1": r,
                "inputColor0": white, "inputColor1": dark,
            ])?.outputImage else { continue }
            img = patch.cropped(to: region).masked(over: img, mask: mask.gainBias(CMath.clamp(h.opacity / 100), 0).cropped(to: region))
                .cropped(to: e)
        }
        return img
    }

    /// Color medio (sRGB 0…1) de la imagen justo antes de las máscaras, en un punto normalizado de la vista.
    func sampleMaskStage(_ base: Request, at p: CGPoint) -> [Double]? {
        var req = base
        req.stopBeforeMasks = true
        guard let (img, _) = pipeline(req) else { return nil }
        let e = img.extent
        let c = CGPoint(x: e.minX + p.x * e.width, y: e.minY + (1 - p.y) * e.height)
        let rect = CGRect(x: c.x - 3, y: c.y - 3, width: 7, height: 7).intersection(e)
        guard !rect.isEmpty else { return nil }
        let avg = img.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rect)])
        var px = [Float](repeating: 0, count: 4)
        ctx.render(avg, toBitmap: &px, rowBytes: 16, bounds: avg.extent, format: .RGBAf, colorSpace: sRGBSpace)
        return px.prefix(3).map { CMath.clamp(Double($0)) }
    }

    /// Imagen de análisis: enderezada sin recortar, sin máscaras ni avisos.
    private func analysisImage(_ base: Request, maxPixel: CGFloat = 1024) -> CGImage? {
        var req = base
        req.cropEditing = true
        req.maxPixel = maxPixel
        req.overlayMask = nil
        req.overlayPoint = nil
        req.clipHigh = false
        req.clipLow = false
        req.settings.masks = []
        return render(req)?.image
    }

    /// Calcula con Vision una máscara de sujeto, fondo o personas sobre la imagen enderezada sin recortar.
    func detectMask(_ kind: MaskKind, _ base: Request) -> Data? {
        guard let image = analysisImage(base) else { return nil }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        var mask: CIImage?
        if kind == .people {
            let inst = VNGeneratePersonInstanceMaskRequest()
            if (try? handler.perform([inst])) != nil, let obs = inst.results?.first, !obs.allInstances.isEmpty,
               let buf = try? obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler) {
                mask = CIImage(cvPixelBuffer: buf)
            } else {
                // Personas pequeñas o de espaldas: la segmentación global las encuentra mejor
                let seg = VNGeneratePersonSegmentationRequest()
                seg.qualityLevel = .accurate
                if (try? handler.perform([seg])) != nil, let obs = seg.results?.first {
                    let m = CIImage(cvPixelBuffer: obs.pixelBuffer)
                    mask = m.transformed(by: CGAffineTransform(scaleX: CGFloat(image.width) / m.extent.width,
                                                               y: CGFloat(image.height) / m.extent.height))
                }
            }
        } else {
            let fg = VNGenerateForegroundInstanceMaskRequest()
            if (try? handler.perform([fg])) != nil, let obs = fg.results?.first,
               let buf = try? obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler) {
                mask = CIImage(cvPixelBuffer: buf)
            }
        }
        guard var ci = mask else { return nil }
        // Sin nada detectado la máscara sale vacía
        let peak = ci.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: ci.extent)])
        var px = [Float](repeating: 0, count: 4)
        ctx.render(peak, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        guard px[0] > 0.25 else { return nil }
        // Las máscaras de personas dejan un residuo bajo en el fondo: se limpia con unos niveles
        if kind == .people { ci = ci.redAsGray(1.25, -0.125).applyingFilter("CIColorClamp") }
        if kind == .background { ci = ci.redAsGray(-1, 1) }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let cg = ctx.createCGImage(ci, from: rect, format: .L8, colorSpace: CGColorSpace(name: CGColorSpace.linearGray)!) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// Luminancia media logarítmica (lineal) del revelado: el brillo percibido, para igualar exposiciones.
    func keyLuminance(_ req: Request) -> Double? {
        guard let (img, _) = pipeline(req) else { return nil }
        let k = min(1, 256 / max(img.extent.width, img.extent.height, 1))
        let small = img.transformed(by: CGAffineTransform(scaleX: k, y: k))
        let r = small.extent.integral
        let w = Int(r.width), h = Int(r.height)
        guard w > 0, h > 0 else { return nil }
        var px = [Float](repeating: 0, count: w * h * 4)
        ctx.render(small, toBitmap: &px, rowBytes: w * 16, bounds: r, format: .RGBAf, colorSpace: linearSpace)
        var sum = 0.0
        for i in stride(from: 0, to: px.count, by: 4) {
            let L = 0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2])
            sum += log(max(L, 1e-4))
        }
        return exp(sum / Double(w * h))
    }

    /// Ángulo de enderezado (grados, como `cropAngle`) que nivela la foto. Se fía de las líneas rectas
    /// casi horizontales o verticales; el horizonte de Vision solo cuenta si coincide con ellas.
    func autoStraightenAngle(_ base: Request) -> Double? {
        var req = base
        req.settings.cropAngle = 0
        guard let image = analysisImage(req) else { return nil }
        var tilt = 0.0, confidence = 0.0
        for pass in 0..<3 {
            let cg: CGImage
            if pass == 0 {
                cg = image
            } else {
                let t = straighten(CIImage(cgImage: image), -tilt)
                guard let r = ctx.createCGImage(t, from: t.extent, format: .RGBA8, colorSpace: sRGBSpace) else { break }
                cg = r
            }
            guard let (d, c) = ImageUtil.lineTilt(cg) else { return nil }
            if pass == 0 { confidence = c }
            tilt += d
            if abs(d) < 0.05 { break }
        }
        if confidence >= 3 { return -tilt }
        let hz = VNDetectHorizonRequest()
        if (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([hz])) != nil, let obs = hz.results?.first {
            let h = Double(obs.angle) * 180 / .pi
            if abs(h - tilt) < 1 { return -(h + tilt) / 2 }
        }
        return nil
    }

    /// Geometría automática (como Upright): nivela y corrige la convergencia de las verticales.
    /// Devuelve los valores de Vertical y Girar, o nil si no hay líneas verticales claras.
    func autoGeometry(_ base: Request) -> (vertical: Double, rotate: Double)? {
        var req = base
        req.settings.horizontal = 0
        var v = 0.0, r = 0.0
        for pass in 0..<3 {
            req.settings.vertical = v
            req.settings.rotate = r
            guard let img = analysisImage(req, maxPixel: 900), let fit = ImageUtil.verticalFit(img) else {
                if pass == 0 { return nil }
                break
            }
            if pass == 0 && fit.weight < 0.08 { return nil }
            // Una línea en x (−0,5…0,5) inclinada k·x grados se endereza abriendo cada esquina h·tan(k)/2
            let aspect = Double(img.height) / Double(img.width)
            let dv = -fit.keystone * .pi / 180 * aspect / 0.6 * 100
            let dr = -fit.tilt
            v = CMath.clamp(v + dv, -100, 100)
            r = CMath.clamp(r + dr, -10, 10)
            if abs(dv) < 0.5 && abs(dr) < 0.05 { break }
        }
        return (v.rounded(), (r * 10).rounded() / 10)
    }

    func render(_ req: Request) -> Result? {
        lastOverlay = nil
        guard let (clean, full) = pipeline(req) else { return nil }
        let overlay = lastOverlay
        lastOverlay = nil
        // Histograma siempre sobre la imagen limpia (sin avisos ni superposiciones)
        let k = min(1, 320 / max(clean.extent.width, clean.extent.height, 1))
        let small = clean.transformed(by: CGAffineTransform(scaleX: k, y: k))
        let histCG = ctx.createCGImage(small, from: small.extent.integral, format: .RGBA8, colorSpace: sRGBSpace)
        let img = decorate(clean, req, overlay: overlay)
        let hdr = req.settings.hdr
        guard let cg = ctx.createCGImage(img, from: img.extent, format: hdr ? .RGBAh : .RGBA8,
                                         colorSpace: hdr ? extendedSRGBSpace : sRGBSpace) else { return nil }
        return Result(image: cg, histogramSource: histCG, fullSize: full, asShot: asShot(for: req.url))
    }

    func export(_ req: Request, to url: URL, options o: ExportOptions) throws {
        guard var (img, _) = pipeline(req) else { throw CocoaError(.fileReadCorruptFile) }
        var s = o.sizing.scale(Double(img.extent.width), Double(img.extent.height), value: o.sizeValue)
        if o.noEnlarge { s = min(s, 1) }
        if abs(s - 1) > 1e-4 {
            img = img.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1]).normalized()
            img = img.cropped(to: img.extent.integral)
        }
        if req.settings.hdr {
            if o.format == .heic {
                // HEIC de 10 bits con curva PQ: conserva el HDR en pantallas y móviles compatibles
                let props = Self.exportProperties(source: req.url, options: o)
                let q = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): o.quality]
                try ctx.writeHEIF10Representation(of: img.settingProperties(props), to: url,
                                                  colorSpace: CGColorSpace(name: CGColorSpace.displayP3_PQ)!, options: q)
                return
            }
            // Resto de formatos (SDR): se comprimen las luces en lugar de recortarlas
            let peak = Float(pow(2, req.settings.hdrHeadroom))
            if #available(macOS 15, *) {
                img = img.applyingFilter("CIToneMapHeadroom", parameters: ["inputSourceHeadroom": peak, "inputTargetHeadroom": Float(1)])
            } else {
                img = img.clamped(to: 1)
            }
        }
        let deep = o.format == .tiff
        guard let cg = ctx.createCGImage(img, from: img.extent, format: deep ? .RGBA16 : .RGBA8, colorSpace: sRGBSpace),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, o.format.uti, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, cg, Self.exportProperties(source: req.url, options: o) as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Metadatos de la copia exportada: los del original según la opción elegida, sin orientación
    /// (los píxeles ya están girados) ni dimensiones antiguas.
    static func exportProperties(source: URL, options o: ExportOptions) -> [CFString: Any] {
        var props: [CFString: Any] = [
            kCGImagePropertyOrientation: 1,
            kCGImagePropertyDPIWidth: o.ppi,
            kCGImagePropertyDPIHeight: o.ppi,
        ]
        if o.format.lossy { props[kCGImageDestinationLossyCompressionQuality] = o.quality }
        guard o.metadata != .none, let src = CGImageSourceCreateWithURL(source as CFURL, nil),
              let orig = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return props }
        var keys = [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary,
                    kCGImagePropertyExifAuxDictionary]
        if o.metadata == .all { keys.append(kCGImagePropertyGPSDictionary) }
        for k in keys {
            guard var d = orig[k] as? [CFString: Any] else { continue }
            d[kCGImagePropertyTIFFOrientation] = nil
            d[kCGImagePropertyExifPixelXDimension] = nil
            d[kCGImagePropertyExifPixelYDimension] = nil
            if k == kCGImagePropertyIPTCDictionary && o.metadata == .noLocation {
                for loc in [kCGImagePropertyIPTCCity, kCGImagePropertyIPTCSubLocation, kCGImagePropertyIPTCProvinceState,
                            kCGImagePropertyIPTCCountryPrimaryLocationName, kCGImagePropertyIPTCCountryPrimaryLocationCode] {
                    d[loc] = nil
                }
            }
            props[k] = d
        }
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFSoftware] = "Revela"
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        return props
    }
}

// MARK: - Histograma y utilidades de imagen

struct Histogram: Equatable {
    var r: [Float], g: [Float], b: [Float]
    var clipLow = false, clipHigh = false
    var mean = (0.5, 0.5, 0.5)
    var median = 0.5, p01 = 0.0, p10 = 0.1, p99 = 1.0

    static func == (a: Histogram, b: Histogram) -> Bool { a.r == b.r && a.g == b.g && a.b == b.b }

    static func compute(_ cg: CGImage) -> Histogram {
        let sc = min(1, 320 / Double(max(cg.width, cg.height)))
        let w = max(1, Int(Double(cg.width) * sc)), h = max(1, Int(Double(cg.height) * sc))
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { p in
            guard let c = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: sRGBSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            c.interpolationQuality = .low
            c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var cr = [Int](repeating: 0, count: 256), cgc = cr, cb = cr, cl = cr
        var sr = 0, sg = 0, sb = 0
        for i in stride(from: 0, to: buf.count, by: 4) {
            let r = Int(buf[i]), g = Int(buf[i + 1]), b = Int(buf[i + 2])
            cr[r] += 1; cgc[g] += 1; cb[b] += 1
            cl[(r * 77 + g * 150 + b * 29) >> 8] += 1
            sr += r; sg += g; sb += b
        }
        let total = max(1, w * h)
        let peak = Float(max(1, (1..<255).map { max(cr[$0], cgc[$0], cb[$0]) }.max() ?? 1))
        func norm(_ a: [Int]) -> [Float] { a.map { min(1, Float($0) / peak) } }
        func pct(_ p: Double) -> Double {
            var acc = 0
            let target = Int(Double(total) * p)
            for i in 0..<256 { acc += cl[i]; if acc >= target { return Double(i) / 255 } }
            return 1
        }
        var hgm = Histogram(r: norm(cr), g: norm(cgc), b: norm(cb))
        let lim = max(1, total / 500)
        hgm.clipLow = cr[0] > lim || cgc[0] > lim || cb[0] > lim
        hgm.clipHigh = cr[255] > lim || cgc[255] > lim || cb[255] > lim
        hgm.mean = (Double(sr) / Double(total) / 255, Double(sg) / Double(total) / 255, Double(sb) / Double(total) / 255)
        hgm.median = pct(0.5); hgm.p01 = pct(0.01); hgm.p10 = pct(0.1); hgm.p99 = pct(0.99)
        return hgm
    }
}

enum ImageUtil {
    static func embeddedThumbnail(_ url: URL, max: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: max,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    static func downscale(_ cg: CGImage, max m: Int) -> CGImage? {
        let sc = min(1, Double(m) / Double(max(cg.width, cg.height)))
        let w = max(1, Int(Double(cg.width) * sc)), h = max(1, Int(Double(cg.height) * sc))
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGBSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.interpolationQuality = .high
        c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return c.makeImage()
    }

    /// Color medio (sRGB 0…1) de una zona de 7×7 px alrededor de un punto normalizado.
    static func sample(_ cg: CGImage, at p: CGPoint) -> (Double, Double, Double)? {
        let x = Int(p.x * CGFloat(cg.width)), y = Int(p.y * CGFloat(cg.height))
        let rect = CGRect(x: x - 3, y: y - 3, width: 7, height: 7).intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard !rect.isEmpty, let sub = cg.cropping(to: rect) else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        px.withUnsafeMutableBytes { p in
            guard let c = CGContext(data: p.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: sRGBSpace,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            c.interpolationQuality = .medium
            c.draw(sub, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return (Double(px[0]) / 255, Double(px[1]) / 255, Double(px[2]) / 255)
    }

    /// Giro aparente (grados) de las líneas casi horizontales o verticales y una confianza (pico / media).
    /// Usa el tensor de estructura: solo cuentan los bordes rectos y coherentes, no las texturas.
    static func lineTilt(_ cg: CGImage) -> (Double, Double)? {
        let (w, h, jxx, jyy, jxy) = structureTensor(cg)
        // Histograma de desviaciones respecto al eje más cercano, de −10° a 10° en pasos de 0,05°
        let bins = 401
        var hist = [Double](repeating: 0, count: bins)
        for y in 4..<h - 4 {
            for x in 4..<w - 4 {
                guard let (ang, wt) = edge(jxx, jyy, jxy, y * w + x) else { continue }
                var dev = ang.truncatingRemainder(dividingBy: 90)
                if dev > 45 { dev -= 90 } else if dev < -45 { dev += 90 }
                guard abs(dev) <= 10 else { continue }
                hist[Int(((dev + 10) * 20).rounded())] += wt
            }
        }
        var sm = [Double](repeating: 0, count: bins)
        for i in 0..<bins {
            var s = 0.0, ws = 0.0
            for k in -8...8 where i + k >= 0 && i + k < bins {
                let wt = exp(-Double(k * k) / 18)
                s += hist[i + k] * wt
                ws += wt
            }
            sm[i] = s / ws
        }
        guard let peak = sm.indices.max(by: { sm[$0] < sm[$1] }), sm[peak] > 0 else { return nil }
        let mean = sm.reduce(0, +) / Double(bins)
        var off = 0.0
        if peak > 0 && peak < bins - 1 {
            let a = sm[peak - 1], b = sm[peak], c = sm[peak + 1], d = a - 2 * b + c
            if d != 0 { off = 0.5 * (a - c) / d }
        }
        return ((Double(peak) + off) / 20 - 10, sm[peak] / mean)
    }

    /// Ajuste de las líneas casi verticales: inclinación media (grados) y cuánto cambia de un borde
    /// a otro de la foto (convergencia por perspectiva), más la confianza (peso de las verticales).
    static func verticalFit(_ cg: CGImage) -> (tilt: Double, keystone: Double, weight: Double)? {
        let (w, h, jxx, jyy, jxy) = structureTensor(cg)
        var pts: [(x: Double, dev: Double, wt: Double)] = []
        var total = 0.0
        for y in 4..<h - 4 {
            for x in 4..<w - 4 {
                guard let (ang, wt) = edge(jxx, jyy, jxy, y * w + x) else { continue }
                total += wt
                // Gradiente casi horizontal = línea casi vertical
                guard abs(ang) <= 15 else { continue }
                pts.append((Double(x) / Double(w) - 0.5, ang, wt))
            }
        }
        guard total > 0, pts.count > 50 else { return nil }
        // Mínimos cuadrados ponderados de dev = a + k·x, descartando lo que se aleja más de 3° en una segunda pasada
        var a = 0.0, k = 0.0
        for pass in 0..<2 {
            var sw = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
            for p in pts where pass == 0 || abs(p.dev - (a + k * p.x)) < 3 {
                sw += p.wt; sx += p.wt * p.x; sy += p.wt * p.dev; sxx += p.wt * p.x * p.x; sxy += p.wt * p.x * p.dev
            }
            let det = sw * sxx - sx * sx
            guard sw > 0, abs(det) > 1e-9 else { return nil }
            k = (sw * sxy - sx * sy) / det
            a = (sy - k * sx) / sw
        }
        let vw = pts.filter { abs($0.dev - (a + k * $0.x)) < 3 }.reduce(0) { $0 + $1.wt }
        return (a, k, vw / total)
    }

    /// Ángulo del gradiente (grados, −90…90) y peso de un píxel de borde coherente.
    private static func edge(_ jxx: [Float], _ jyy: [Float], _ jxy: [Float], _ i: Int) -> (Double, Double)? {
        let a = Double(jxx[i]), b = Double(jyy[i]), c = Double(jxy[i])
        let tr = a + b
        guard tr > 1e4 else { return nil }
        let diff = ((a - b) * (a - b) + 4 * c * c).squareRoot()
        let coh = diff / tr
        guard coh > 0.6 else { return nil }
        return (0.5 * atan2(2 * c, a - b) * 180 / .pi, diff.squareRoot() * coh * coh)
    }

    /// Tensor de estructura (gradientes Sobel sumados en ventanas de 7×7) de la imagen en gris a ≤ 720 px.
    private static func structureTensor(_ cg: CGImage) -> (Int, Int, [Float], [Float], [Float]) {
        let sc = min(1, 720 / Double(max(cg.width, cg.height)))
        let w = max(16, Int(Double(cg.width) * sc)), h = max(16, Int(Double(cg.height) * sc))
        var g = [UInt8](repeating: 0, count: w * h)
        g.withUnsafeMutableBytes { p in
            guard let c = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            c.interpolationQuality = .high
            c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        // Productos del gradiente (Sobel)
        var xx = [Float](repeating: 0, count: w * h), yy = xx, xy = xx
        for y in 1..<h - 1 {
            for x in 1..<w - 1 {
                func v(_ dx: Int, _ dy: Int) -> Float { Float(g[(y + dy) * w + x + dx]) }
                let gx = (v(1, -1) + 2 * v(1, 0) + v(1, 1)) - (v(-1, -1) + 2 * v(-1, 0) + v(-1, 1))
                let gy = (v(-1, 1) + 2 * v(0, 1) + v(1, 1)) - (v(-1, -1) + 2 * v(0, -1) + v(1, -1))
                let i = y * w + x
                xx[i] = gx * gx; yy[i] = gy * gy; xy[i] = gx * gy
            }
        }
        // Suma en ventanas de 7×7 (caja separable)
        func box(_ a: [Float]) -> [Float] {
            let r = 3
            var t = [Float](repeating: 0, count: w * h), o = t
            for y in 0..<h {
                var s: Float = 0
                for x in 0..<w + r {
                    if x < w { s += a[y * w + x] }
                    if x - 2 * r - 1 >= 0 { s -= a[y * w + x - 2 * r - 1] }
                    if x >= r { t[y * w + x - r] = s }
                }
            }
            for x in 0..<w {
                var s: Float = 0
                for y in 0..<h + r {
                    if y < h { s += t[y * w + x] }
                    if y - 2 * r - 1 >= 0 { s -= t[(y - 2 * r - 1) * w + x] }
                    if y >= r { o[(y - r) * w + x] = s }
                }
            }
            return o
        }
        let jxx = box(xx), jyy = box(yy), jxy = box(xy)
        return (w, h, jxx, jyy, jxy)
    }

    static func exifSummary(_ url: URL) -> (String, CGSize) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return ("", .zero) }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        var parts: [String] = []
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first { parts.append("ISO \(iso)") }
        if let f = exif[kCGImagePropertyExifFocalLength] as? Double { parts.append("\(Int(f.rounded())) mm") }
        if let n = exif[kCGImagePropertyExifFNumber] as? Double { parts.append(String(format: "f/%.1f", n)) }
        if let t = exif[kCGImagePropertyExifExposureTime] as? Double, t > 0 {
            parts.append(t >= 1 ? String(format: "%.1f s", t) : "1/\(Int((1 / t).rounded())) s")
        }
        if let model = tiff[kCGImagePropertyTIFFModel] as? String { parts.insert(model.trimmingCharacters(in: .whitespaces), at: 0) }
        return (parts.joined(separator: "  ·  "), Engine.pixelSize(url))
    }
}

enum MaskRaster {
    static let longEdge = 1024.0

    /// Rasteriza los trazos del pincel en una imagen gris lineal (lado largo 1024 px).
    static func brush(_ strokes: [BrushStroke], aspect: Double) -> CGImage? {
        let W = Int(aspect >= 1 ? longEdge : max(1, (longEdge * aspect).rounded()))
        let H = Int(aspect >= 1 ? max(1, (longEdge / aspect).rounded()) : longEdge)
        var buf = [Float](repeating: 0, count: W * H)
        buf.withUnsafeMutableBufferPointer { b in
            for s in strokes where s.points.count >= 2 {
                let r = max(1, s.size * longEdge)
                let inner = 1 - CMath.clamp(s.feather / 100)
                let flow = s.flow >= 99.9 ? Float(1) : Float(CMath.clamp(s.flow / 100) * 0.3)
                var pts: [(Double, Double)] = []
                for i in stride(from: 0, to: s.points.count - 1, by: 2) {
                    pts.append((s.points[i] * Double(W), s.points[i + 1] * Double(H)))
                }
                // Toques espaciados a lo largo del trazo
                var dabs = [pts[0]]
                let spacing = max(1, r * 0.2)
                var carry = 0.0
                for k in 1..<max(1, pts.count) where pts.count > 1 {
                    let a = pts[k - 1], c = pts[k]
                    let len = hypot(c.0 - a.0, c.1 - a.1)
                    guard len > 0 else { continue }
                    var t = spacing - carry
                    while t <= len {
                        dabs.append((a.0 + (c.0 - a.0) * t / len, a.1 + (c.1 - a.1) * t / len))
                        t += spacing
                    }
                    carry = len - (t - spacing)
                }
                for (cx, cy) in dabs {
                    let xa = max(0, Int(cx - r)), xb = min(W - 1, Int(cx + r))
                    let ya = max(0, Int(cy - r)), yb = min(H - 1, Int(cy + r))
                    guard xa <= xb, ya <= yb else { continue }
                    for y in ya...yb {
                        let dy = Double(y) + 0.5 - cy
                        for x in xa...xb {
                            let dx = Double(x) + 0.5 - cx
                            let d = (dx * dx + dy * dy).squareRoot() / r
                            if d >= 1 { continue }
                            let fall = d <= inner ? 1 : 1 - CMath.smoothstep(inner, 1, d)
                            let a = Float(fall) * flow
                            let i = y * W + x
                            if s.erase { b[i] *= 1 - a } else { b[i] += (1 - b[i]) * a }
                        }
                    }
                }
            }
        }
        let bytes = buf.map { UInt8(min(255, max(0, $0 * 255))) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: W,
                       space: CGColorSpace(name: CGColorSpace.linearGray)!, bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

// MARK: - Ajustes preestablecidos integrados

struct BuiltinPreset: Identifiable {
    let name: String
    let apply: (inout EditSettings) -> Void
    var id: String { name }

    static let all: [BuiltinPreset] = [
        BuiltinPreset(name: "B/N alto contraste") { s in
            s.profile = .mono; s.contrast = 40; s.clarity = 20; s.blacks = -15; s.whites = 15
            s.bwMix = [10, 15, 10, -10, -20, -30, -10, 0]
        },
        BuiltinPreset(name: "B/N suave") { s in
            s.profile = .mono; s.contrast = -10; s.highlights = -30; s.shadows = 20; s.grainAmount = 20
        },
        BuiltinPreset(name: "Película cálida") { s in
            s.temp = 12; s.vibrance = 10; s.contrast = 10
            s.curveRGB = [CurvePoint(x: 0, y: 0.06), CurvePoint(x: 0.5, y: 0.52), CurvePoint(x: 1, y: 0.96)]
            s.gradeShadows = GradeWheel(hue: 200, sat: 12, lum: 0); s.gradeHighlights = GradeWheel(hue: 45, sat: 18, lum: 0)
            s.grainAmount = 25
        },
        BuiltinPreset(name: "Teal & Orange") { s in
            s.contrast = 15; s.vibrance = 10
            s.gradeShadows = GradeWheel(hue: 195, sat: 30, lum: 0); s.gradeHighlights = GradeWheel(hue: 35, sat: 25, lum: 0)
            s.hslHue[1] = -5; s.hslSat[4] = 20; s.hslSat[3] = -20
        },
        BuiltinPreset(name: "Mate") { s in
            s.curveRGB = [CurvePoint(x: 0, y: 0.1), CurvePoint(x: 0.25, y: 0.24), CurvePoint(x: 0.75, y: 0.78), CurvePoint(x: 1, y: 0.95)]
            s.saturation = -10; s.contrast = -5
        },
        BuiltinPreset(name: "Vívido") { s in
            s.profile = .vivid; s.vibrance = 25; s.clarity = 10; s.dehaze = 10
        },
        BuiltinPreset(name: "Paisaje dramático") { s in
            s.profile = .landscape; s.dehaze = 20; s.clarity = 25; s.highlights = -60; s.shadows = 40; s.vibrance = 20
            s.hslLum[5] = -25; s.vigAmount = -15
        },
        BuiltinPreset(name: "Retrato luminoso") { s in
            s.profile = .portrait; s.exposure = 0.2; s.highlights = -20; s.shadows = 15; s.texture = -15; s.clarity = -10
            s.hslLum[1] = 10; s.hslSat[1] = -5
        },
        BuiltinPreset(name: "Frío nórdico") { s in
            s.temp = -15; s.saturation = -15; s.contrast = 10; s.hslSat[3] = -30
            s.gradeShadows = GradeWheel(hue: 210, sat: 15, lum: 0)
        },
    ]
}

struct WBPreset { let name: String; let kelvin: Double; let tint: Double }

let wbPresets = [
    WBPreset(name: "Luz de día", kelvin: 5500, tint: 10), WBPreset(name: "Nublado", kelvin: 6500, tint: 10),
    WBPreset(name: "Sombra", kelvin: 7500, tint: 10), WBPreset(name: "Tungsteno", kelvin: 2850, tint: 0),
    WBPreset(name: "Fluorescente", kelvin: 3800, tint: 21), WBPreset(name: "Flash", kelvin: 5500, tint: 0),
]

/// Imágenes que llegan del revelado. Separadas del Store para que su llegada no redibuje los paneles.
final class PreviewModel: ObservableObject {
    @Published var preview: CGImage?
    @Published var histogram: Histogram?
    @Published var beforePreview: CGImage?
    @Published var referencePreview: CGImage?
    @Published var navigatorPreview: CGImage?
    @Published var navigatorLabel: String?
}

/// Referencia al Store que NO suscribe la vista a sus cambios (a diferencia de @EnvironmentObject):
/// para controles que solo lo usan para acciones y así no se redibujan con cada ajuste.
private struct StoreRefKey: EnvironmentKey { static let defaultValue: Store? = nil }

extension EnvironmentValues {
    var storeRef: Store? {
        get { self[StoreRefKey.self] }
        set { self[StoreRefKey.self] = newValue }
    }
}

/// Indicador compartido entre hilos para cancelar un trabajo en segundo plano.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return flag }
        set { lock.lock(); flag = newValue; lock.unlock() }
    }
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    enum Module { case library, develop }
    enum Tool { case none, crop, whiteBalance, mask, heal, pointColor }

    @Published var photos: [Photo] = []
    @Published var selectedID: UUID?
    /// Fotos marcadas además de la actual (⌘-clic / ⇧-clic en la tira).
    @Published var multiSelection: Set<UUID> = []
    @Published var settings = EditSettings() {
        didSet { if !loading && settings != oldValue { scheduleRender() } }
    }
    /// Vista previa e histograma: en su propio objeto para que una imagen nueva solo redibuje el lienzo,
    /// el histograma, la curva y el Navegador (no los ~100 deslizadores del panel derecho).
    let previews = PreviewModel()
    var preview: CGImage? { get { previews.preview } set { previews.preview = newValue } }
    var histogram: Histogram? { get { previews.histogram } set { previews.histogram = newValue } }
    @Published var module: Module = .develop
    @Published var tool: Tool = .none { didSet { if tool != oldValue { scheduleRender() } } }
    @Published var showBefore = false { didSet { scheduleRender() } }
    @Published var zoomed = false { didSet { scheduleRender() } }
    @Published var cropAspect: CropAspect = .free
    @Published var cropPortrait = false
    @Published var selectedMaskID: UUID? { didSet { if showMaskOverlay && tool == .mask { scheduleRender() } } }
    @Published var showMaskOverlay = true { didSet { scheduleRender() } }
    @Published var brushSize = 20.0
    @Published var brushFeather = 50.0
    @Published var brushFlow = 100.0
    @Published var brushErase = false
    /// Paneles desactivados temporalmente con el ojo (solo afecta a la vista previa).
    @Published var disabledGroups: Set<AdjustGroup> = [] { didSet { if disabledGroups != oldValue { scheduleRender() } } }
    // Punto de color
    @Published var selectedPointID: UUID? { didSet { if showPointRange { scheduleRender() } } }
    @Published var showPointRange = false { didSet { scheduleRender() } }
    // Comparación, avisos y visualización
    @Published var splitView = false { didSet { scheduleRender() } }
    @Published var splitPosition = 0.5
    var beforePreview: CGImage? { get { previews.beforePreview } set { previews.beforePreview = newValue } }
    @Published var clipHigh = false { didSet { scheduleRender() } }
    @Published var clipLow = false { didSet { scheduleRender() } }
    @Published var busy = false
    /// Comparación lado a lado: con la versión "antes" o, si `compareReference`, con otra foto de referencia.
    @Published var sideBySide = false { didSet { scheduleRender() } }
    @Published var compareReference = false { didSet { scheduleRender() } }
    @Published var referenceID: UUID? { didSet { referencePreview = nil; referenceKey = nil; scheduleRender() } }
    var referencePreview: CGImage? { get { previews.referencePreview } set { previews.referencePreview = newValue } }
    private var referenceKey: BeforeKey?
    var navigatorPreview: CGImage? { get { previews.navigatorPreview } set { previews.navigatorPreview = newValue } }
    var navigatorLabel: String? { get { previews.navigatorLabel } set { previews.navigatorLabel = newValue } }
    @Published var showShortcuts = false
    @Published var panelsHidden = false
    // Herramienta Eliminar
    @Published var selectedHealID: UUID?
    @Published var healMode: HealMode = .heal
    @Published var healSize = 20.0
    @Published var healFeather = 50.0
    @Published var healOpacity = 100.0
    @Published var showHealSpots = true
    @Published var histories: [UUID: HistoryState] = [:]
    @Published var userPresets: [UserPreset] = []
    @Published var showExport = false
    @Published var status: String?
    @Published var fullSize = CGSize(width: 3, height: 2)

    var viewport = CGSize(width: 1200, height: 800) {
        didSet {
            let target = previewTarget
            if abs(target - lastTarget) / max(lastTarget, 1) > 0.15 { scheduleRender() }
        }
    }
    let backingScale = NSScreen.main?.backingScaleFactor ?? 2
    private var lastTarget: CGFloat = 0
    private var clipboard: EditSettings?
    private var previousSettings: EditSettings?
    private var loading = false
    private var inFlight = false
    private var pending = false
    private var thumbDirty = false
    private var saveWork: DispatchWorkItem?
    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    private var busyWork: DispatchWorkItem?
    private var hoverToken = 0
    private struct BeforeKey: Equatable { var url: URL; var settings: EditSettings; var maxPixel: CGFloat? }
    private var beforeKey: BeforeKey?

    private let engine = Engine()
    private let exportEngine = Engine()
    private let thumbEngine = Engine()
    private let renderQueue = DispatchQueue(label: "revela.render", qos: .userInteractive)
    private let exportQueue = DispatchQueue(label: "revela.export", qos: .userInitiated)
    private let thumbQueue = DispatchQueue(label: "revela.thumbs", qos: .utility)
    /// Miniaturas al importar o arrancar: 3 colas con su propio motor para generar varias a la vez.
    private let thumbLoaders = (0..<3).map { (DispatchQueue(label: "revela.thumbload.\($0)", qos: .utility), Engine()) }
    private var thumbLoaderNext = 0
    /// Vista previa al pasar por un ajuste preestablecido: cola propia y solo cuenta la última petición.
    private let hoverQueue = DispatchQueue(label: "revela.hover", qos: .userInitiated)
    private let hoverEngine = Engine()
    private var hoverWork: DispatchWorkItem?

    init() {
        loadCatalog()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            if e.window?.firstResponder is NSTextView { return e }
            if !e.modifierFlags.intersection([.command, .control, .option]).isEmpty { return e }
            return MainActor.assumeIsolated { self.handleKey(e) } ? nil : e
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] e in
            guard let self else { return e }
            return MainActor.assumeIsolated { self.handleScroll(e) } ? nil : e
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveCatalog() }
        }
    }

    var currentIndex: Int? { photos.firstIndex { $0.id == selectedID } }
    var current: Photo? { currentIndex.map { photos[$0] } }
    var history: HistoryState? { selectedID.flatMap { histories[$0] } }
    var previewTarget: CGFloat { min(4096, max(viewport.width, viewport.height) * backingScale) }

    // MARK: Bindings

    func bind<T>(_ kp: WritableKeyPath<EditSettings, T>) -> Binding<T> {
        Binding(get: { self.settings[keyPath: kp] }, set: { self.settings[keyPath: kp] = $0 })
    }

    func bindIndex(_ kp: WritableKeyPath<EditSettings, [Double]>, _ i: Int) -> Binding<Double> {
        Binding(get: { self.settings[keyPath: kp][i] }, set: { self.settings[keyPath: kp][i] = $0 })
    }

    func toggle(_ kp: WritableKeyPath<EditSettings, Bool>, _ name: String) -> Binding<Bool> {
        Binding(get: { self.settings[keyPath: kp] }, set: { self.settings[keyPath: kp] = $0; self.commit(name) })
    }

    var cropRect: Binding<CGRect> {
        Binding(get: {
            let s = self.settings
            return CGRect(x: s.cropX, y: s.cropY, width: s.cropW, height: s.cropH)
        }, set: { r in
            var s = self.settings
            s.cropX = r.minX; s.cropY = r.minY; s.cropW = r.width; s.cropH = r.height
            self.settings = s
        })
    }

    // MARK: Importación

    func importPanel() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.allowedContentTypes = [.image, .rawImage]
        p.prompt = tr("Importar")
        p.message = tr("Elige fotos (RAW, JPEG, HEIC, TIFF, PNG…) o carpetas")
        if p.runModal() == .OK { add(urls: p.urls) }
    }

    func add(urls: [URL], settings saved: [URL: EditSettings] = [:]) {
        var files: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                while let f = en?.nextObject() as? URL { if isSupportedImage(f) { files.append(f) } }
            } else if isSupportedImage(url) {
                files.append(url)
            }
        }
        let existing = Set(photos.map { $0.url.standardizedFileURL })
        let newPhotos = files.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .filter { !existing.contains($0.standardizedFileURL) }
            .map { url -> Photo in
                let raw = isRAWFile(url)
                return Photo(url: url, isRAW: raw, settings: saved[url] ?? EditSettings.defaults(raw: raw))
            }
        guard !newPhotos.isEmpty else { return }
        photos.append(contentsOf: newPhotos)
        for p in newPhotos { loadThumbnail(p) }
        if selectedID == nil, let first = newPhotos.first { select(first.id) }
        if saved.isEmpty { saveCatalogSoon() }
    }

    private func loadThumbnail(_ p: Photo) {
        let id = p.id, url = p.url, raw = p.isRAW, settings = p.settings, edited = p.isEdited
        let (queue, engine) = thumbLoaders[thumbLoaderNext % thumbLoaders.count]
        thumbLoaderNext += 1
        queue.async {
            let (exif, size) = ImageUtil.exifSummary(url)
            var thumb = ImageUtil.embeddedThumbnail(url, max: 320)
            if edited {
                thumb = engine.render(Engine.Request(url: url, isRAW: raw, settings: settings, maxPixel: 320))?.image ?? thumb
            }
            DispatchQueue.main.async {
                guard let i = self.photos.firstIndex(where: { $0.id == id }) else { return }
                // Un solo cambio por foto: cada cambio en `photos` redibuja la ventana
                var ph = self.photos[i]
                ph.exif = exif
                ph.pixelSize = size
                if ph.thumbnail == nil || edited { ph.thumbnail = thumb }
                self.photos[i] = ph
            }
        }
    }

    func remove(_ id: UUID) {
        guard let i = photos.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = id == selectedID
        photos.remove(at: i)
        histories[id] = nil
        multiSelection.remove(id)
        if wasSelected {
            selectedID = nil
            preview = nil
            histogram = nil
            if !photos.isEmpty { select(photos[min(i, photos.count - 1)].id) }
        }
        saveCatalogSoon()
    }

    // MARK: Selección

    func select(_ id: UUID) {
        guard id != selectedID, let ni = photos.firstIndex(where: { $0.id == id }) else { return }
        if let i = currentIndex { photos[i].settings = settings; previousSettings = settings }
        selectedID = id
        loading = true
        settings = photos[ni].settings
        loading = false
        if histories[id] == nil { histories[id] = HistoryState(entries: [HistoryEntry(name: "Importar", settings: settings)], index: 0) }
        preview = nil
        histogram = nil
        zoomed = false
        tool = .none
        selectedMaskID = nil
        selectedHealID = nil
        selectedPointID = nil
        showPointRange = false
        disabledGroups = []
        multiSelection.remove(id)
        beforePreview = nil
        beforeKey = nil
        navigatorPreview = nil
        endEditing()
        scheduleRender()
    }

    /// Clic en una miniatura: ⌘ marca o desmarca la foto, ⇧ marca el intervalo desde la actual.
    func click(_ id: UUID) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command), let cur = selectedID, id != cur {
            if multiSelection.contains(id) { multiSelection.remove(id) } else { multiSelection.insert(id) }
        } else if flags.contains(.shift), let cur = selectedID, let a = currentIndex, let b = photos.firstIndex(where: { $0.id == id }) {
            multiSelection = Set(photos[min(a, b)...max(a, b)].map(\.id)).subtracting([cur])
        } else {
            multiSelection = []
            select(id)
        }
    }

    func step(_ d: Int) {
        guard let i = currentIndex else { if let f = photos.first { select(f.id) }; return }
        let n = i + d
        if photos.indices.contains(n) { select(photos[n].id) }
    }

    // MARK: Render

    func scheduleRender() {
        guard let photo = current, module == .develop else { return }
        if !FileManager.default.fileExists(atPath: photo.url.path) {
            if let i = currentIndex, !photos[i].missing { photos[i].missing = true }
            preview = nil
            return
        }
        if inFlight { pending = true; return }
        inFlight = true
        armBusy()
        let before = beforeSettings(photo)
        let s = showBefore ? before : disabledGroups.reduce(settings) { $0.resetting($1, raw: photo.isRAW) }
        lastTarget = previewTarget
        let maxPx: CGFloat? = zoomed ? nil : previewTarget
        var req = Engine.Request(url: photo.url, isRAW: photo.isRAW, settings: s, maxPixel: maxPx,
                                 cropEditing: tool == .crop, overlayMask: activeOverlay)
        req.clipHigh = clipHigh
        req.clipLow = clipLow
        req.overlayPoint = showBefore ? nil : activePointOverlay
        var beforeReq: Engine.Request?
        if sideBySideActive && compareReference, let rid = referenceID, let ref = photos.first(where: { $0.id == rid }) {
            let rs = rid == photo.id ? settings : ref.settings
            let key = BeforeKey(url: ref.url, settings: rs, maxPixel: maxPx)
            if key != referenceKey || referencePreview == nil {
                referenceKey = key
                let rreq = Engine.Request(url: ref.url, isRAW: ref.isRAW, settings: rs, maxPixel: maxPx)
                thumbQueue.async { [thumbEngine] in
                    let img = thumbEngine.render(rreq)?.image
                    DispatchQueue.main.async { if self.referenceKey == key { self.referencePreview = img } }
                }
            }
        }
        if splitActive || (sideBySideActive && !compareReference) {
            let key = BeforeKey(url: photo.url, settings: before, maxPixel: maxPx)
            if key != beforeKey || beforePreview == nil {
                beforeKey = key
                beforeReq = Engine.Request(url: photo.url, isRAW: photo.isRAW, settings: before, maxPixel: maxPx)
            }
        }
        let id = photo.id
        renderQueue.async { [engine] in
            let beforeImage = beforeReq.flatMap { engine.render($0)?.image }
            let result = engine.render(req)
            let hist = result?.histogramSource.map { Histogram.compute($0) }
            DispatchQueue.main.async {
                self.inFlight = false
                if self.selectedID == id, let r = result {
                    self.preview = r.image
                    if let hist { self.histogram = hist }
                    if self.fullSize != r.fullSize { self.fullSize = r.fullSize }
                    if let b = beforeImage { self.beforePreview = b }
                    if let i = self.currentIndex, self.photos[i].asShot == nil, let a = r.asShot { self.photos[i].asShot = a }
                }
                if self.pending {
                    self.pending = false
                    self.scheduleRender()
                } else {
                    self.busyWork?.cancel()
                    if self.busy { self.busy = false }
                    if self.thumbDirty { self.updateThumbnailFromPreview() }
                }
            }
        }
    }

    /// Ajustes de la vista "Antes": valores por defecto con el mismo encuadre.
    private func beforeSettings(_ photo: Photo) -> EditSettings {
        var b = settings.withLook(from: EditSettings.defaults(raw: photo.isRAW))
        b.masks = []
        b.heals = []
        return b
    }

    var splitActive: Bool { splitView && !sideBySide && tool == .none && !showBefore && !zoomed }
    var sideBySideActive: Bool { sideBySide && tool == .none && !showBefore && !zoomed }

    /// Modo de comparación de la barra inferior: 0 después, 1 antes, 2 dividido, 3 lado a lado, 4 referencia.
    var compareMode: Int {
        get { showBefore ? 1 : (sideBySide ? (compareReference ? 4 : 3) : (splitView ? 2 : 0)) }
        set {
            showBefore = newValue == 1
            splitView = newValue == 2
            sideBySide = newValue >= 3
            compareReference = newValue == 4
            if newValue >= 2 { zoomed = false }
        }
    }

    func setReference(_ id: UUID?) {
        referenceID = id
        if id != nil { compareMode = 4 } else if compareReference { compareMode = 0 }
    }

    /// Muestra el indicador de carga solo si el revelado tarda (evita parpadeos).
    private func armBusy() {
        busyWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { if self?.inFlight == true { self?.busy = true } } }
        busyWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    /// Vista previa en el Navegador al pasar el ratón por un ajuste preestablecido.
    func hoverPreview(_ label: String?, _ make: ((EditSettings) -> EditSettings)?) {
        hoverToken += 1
        let token = hoverToken
        guard let label, let make, let photo = current else {
            navigatorPreview = nil
            navigatorLabel = nil
            return
        }
        navigatorLabel = label
        let req = Engine.Request(url: photo.url, isRAW: photo.isRAW, settings: make(settings), maxPixel: 420)
        // Al recorrer la lista deprisa, las peticiones que aún no han empezado se descartan
        hoverWork?.cancel()
        let w = DispatchWorkItem { [hoverEngine] in
            let img = hoverEngine.render(req)?.image
            DispatchQueue.main.async { if token == self.hoverToken { self.navigatorPreview = img } }
        }
        hoverWork = w
        hoverQueue.async(execute: w)
    }

    private func updateThumbnailFromPreview() {
        guard !showBefore, tool != .crop, activeOverlay == nil, activePointOverlay == nil, !clipHigh, !clipLow, disabledGroups.isEmpty,
              let cg = preview, let i = currentIndex else { return }
        thumbDirty = false
        photos[i].thumbnail = ImageUtil.downscale(cg, max: 320)
    }

    // MARK: Historial

    func commit(_ name: String) {
        guard let id = selectedID, let i = currentIndex else { return }
        photos[i].settings = settings
        var h = histories[id] ?? HistoryState(entries: [HistoryEntry(name: "Importar", settings: settings)], index: 0)
        guard h.entries[h.index].settings != settings else { return }
        h.entries = Array(h.entries.prefix(h.index + 1))
        h.entries.append(HistoryEntry(name: tr(name), settings: settings))
        h.index = h.entries.count - 1
        histories[id] = h
        thumbDirty = true
        if !inFlight { updateThumbnailFromPreview() }
        saveCatalogSoon()
    }

    /// Cambia los ajustes de otra foto (no la abierta) dejando constancia en su historial.
    private func commitOther(_ id: UUID, _ s: EditSettings, _ name: String) {
        guard let i = photos.firstIndex(where: { $0.id == id }) else { return }
        var h = histories[id] ?? HistoryState(entries: [HistoryEntry(name: "Importar", settings: photos[i].settings)], index: 0)
        h.entries = Array(h.entries.prefix(h.index + 1))
        h.entries.append(HistoryEntry(name: tr(name), settings: s))
        h.index = h.entries.count - 1
        histories[id] = h
        photos[i].settings = s
        loadThumbnail(photos[i])
    }

    func jumpHistory(_ index: Int) {
        guard let id = selectedID, var h = histories[id], h.entries.indices.contains(index) else { return }
        h.index = index
        histories[id] = h
        settings = h.entries[index].settings
        if let i = currentIndex { photos[i].settings = settings }
        thumbDirty = true
        saveCatalogSoon()
    }

    func undo() { if let h = history, h.index > 0 { jumpHistory(h.index - 1) } }
    func redo() { if let h = history, h.index < h.entries.count - 1 { jumpHistory(h.index + 1) } }

    // MARK: Acciones de ajuste

    func reset() {
        guard let p = current else { return }
        settings = EditSettings.defaults(raw: p.isRAW)
        commit("Restablecer")
    }

    func resetGroup(_ g: AdjustGroup, _ name: String) {
        guard let p = current else { return }
        let s = settings.resetting(g, raw: p.isRAW)
        guard s != settings else { return }
        settings = s
        disabledGroups.remove(g)
        commit(tr("Restablecer %@", name))
    }

    func toggleGroup(_ g: AdjustGroup) {
        if disabledGroups.contains(g) { disabledGroups.remove(g) } else { disabledGroups.insert(g) }
    }

    func copySettings() { clipboard = settings; flash("Ajustes copiados") }

    func pasteSettings() {
        guard let c = clipboard else { return }
        settings = settings.withLook(from: c)
        commit("Pegar ajustes")
    }

    func pastePrevious() {
        guard let p = previousSettings else { return }
        settings = settings.withLook(from: p)
        commit("Ajustes anteriores")
    }

    func apply(_ preset: BuiltinPreset) {
        var s = settings
        preset.apply(&s)
        settings = s
        commit(preset.name)
    }

    func apply(_ preset: UserPreset) {
        settings = settings.withLook(from: preset.settings)
        commit(preset.name)
    }

    func saveUserPreset() {
        let a = NSAlert()
        a.messageText = tr("Nuevo ajuste preestablecido")
        a.informativeText = tr("Guarda los ajustes actuales (sin recorte ni geometría).")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        tf.stringValue = tr("Mi ajuste %@", "\(userPresets.count + 1)")
        a.accessoryView = tf
        a.addButton(withTitle: tr("Guardar"))
        a.addButton(withTitle: tr("Cancelar"))
        a.window.initialFirstResponder = tf
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = tf.stringValue.trimmingCharacters(in: .whitespaces)
        userPresets.append(UserPreset(name: name.isEmpty ? tr("Sin nombre") : name, settings: settings))
        saveCatalogSoon()
    }

    func deleteUserPreset(_ p: UserPreset) {
        userPresets.removeAll { $0.id == p.id }
        saveCatalogSoon()
    }

    func rotate(_ dir: Int) {
        var s = settings
        s.rotation90 = (s.rotation90 + dir + 4) % 4
        s.cropX = 0; s.cropY = 0; s.cropW = 1; s.cropH = 1
        settings = s
        commit(dir > 0 ? "Girar a la derecha" : "Girar a la izquierda")
    }

    func flip() {
        settings.flipH.toggle()
        commit("Voltear horizontal")
    }

    func neutralize(_ r: Double, _ g: Double, _ b: Double, name: String) {
        let lin = { (v: Double) in pow(max(v, 0.002), 2.2) }
        let R = lin(r), G = lin(g), B = lin(b)
        var s = settings
        s.temp = CMath.clamp((s.temp + 58 * log2(B / R)).rounded(), -100, 100)
        s.tint = CMath.clamp((s.tint + 110 * log2(G / ((R + B) / 2))).rounded(), -100, 100)
        settings = s
        commit(name)
    }

    func sampleWhiteBalance(at p: CGPoint) {
        guard let cg = preview, let (r, g, b) = ImageUtil.sample(cg, at: p) else { return }
        neutralize(r, g, b, name: "Balance de blancos (cuentagotas)")
        tool = .none
    }

    func autoWhiteBalance() {
        guard let h = histogram else { return }
        neutralize(h.mean.0, h.mean.1, h.mean.2, name: "Balance de blancos automático")
    }

    func asShotWhiteBalance() {
        settings.temp = 0
        settings.tint = 0
        commit("Balance de blancos: como se tomó")
    }

    func applyWB(_ p: WBPreset) {
        guard let shot = current?.asShot else { return }
        settings.temp = CMath.clamp((60 * log2(p.kelvin / shot.temp)).rounded(), -100, 100)
        settings.tint = CMath.clamp(((p.tint - shot.tint) / 1.5).rounded(), -100, 100)
        commit(tr("Balance de blancos: %@", tr(p.name)))
    }

    func autoTone() {
        guard let h = histogram else { return }
        var s = settings
        let med = max(0.02, h.median)
        s.exposure = CMath.clamp(((s.exposure + log2(0.46 / med) * 1.6) * 100).rounded() / 100, -5, 5)
        s.whites = CMath.clamp((s.whites + (0.97 - h.p99) * 200).rounded(), -100, 100)
        s.blacks = CMath.clamp((s.blacks - (h.p01 - 0.02) * 250).rounded(), -100, 100)
        if h.p99 > 0.96 { s.highlights = CMath.clamp(s.highlights - 30, -100, 100) }
        if h.p10 < 0.12 { s.shadows = CMath.clamp(s.shadows + 25, -100, 100) }
        s.vibrance = max(s.vibrance, 8)
        settings = s
        commit("Tono automático")
    }

    /// Iguala el brillo de las fotos marcadas (o de todas) al de la foto actual ajustando solo su exposición.
    func matchExposure() {
        guard let ref = current, let ci = currentIndex else { return }
        photos[ci].settings = settings
        var targets = photos.filter { multiSelection.contains($0.id) }
        if targets.isEmpty {
            guard photos.count > 1 else { flash("Importa más fotos para igualar su exposición"); return }
            let a = NSAlert()
            a.messageText = tr("Igualar exposición")
            a.informativeText = tr("No hay otras fotos marcadas (⌘-clic o ⇧-clic en la tira). ¿Igualar la exposición de las otras %@ fotos a la de esta?", "\(photos.count - 1)")
            a.addButton(withTitle: tr("Igualar todas"))
            a.addButton(withTitle: tr("Cancelar"))
            guard a.runModal() == .alertFirstButtonReturn else { return }
            targets = photos.filter { $0.id != ref.id }
        }
        status = tr("Igualando exposición…")
        let refReq = Engine.Request(url: ref.url, isRAW: ref.isRAW, settings: settings, maxPixel: 384)
        let jobs = targets.map { ($0.id, Engine.Request(url: $0.url, isRAW: $0.isRAW, settings: $0.settings, maxPixel: 384)) }
        thumbQueue.async { [thumbEngine] in
            let key = thumbEngine.keyLuminance(refReq)
            var out: [(UUID, Double)] = []
            if let key {
                for (id, base) in jobs {
                    // La curva de tonos comprime la respuesta: se itera hasta que el brillo coincide
                    var req = base
                    for _ in 0..<4 {
                        guard let k = thumbEngine.keyLuminance(req) else { break }
                        let d = log2(key / max(k, 1e-5))
                        let next = CMath.clamp(req.settings.exposure + d, -5, 5)
                        if abs(d) < 0.02 || next == req.settings.exposure { break }
                        req.settings.exposure = next
                    }
                    out.append((id, (req.settings.exposure * 100).rounded() / 100))
                }
            }
            DispatchQueue.main.async {
                guard key != nil else { self.flash("No se ha podido medir la foto de referencia"); return }
                var changed = 0
                for (id, ev) in out {
                    guard let i = self.photos.firstIndex(where: { $0.id == id }) else { continue }
                    var s = id == self.selectedID ? self.settings : self.photos[i].settings
                    guard abs(s.exposure - ev) >= 0.01 else { continue }
                    s.exposure = ev
                    if id == self.selectedID {
                        self.settings = s
                        self.commit("Igualar exposición")
                    } else {
                        self.commitOther(id, s, "Igualar exposición")
                    }
                    changed += 1
                }
                self.flash(changed == 0 ? "La exposición ya coincide" : tr(changed == 1 ? "Exposición igualada en %@ foto" : "Exposición igualada en %@ fotos", "\(changed)"))
                self.saveCatalogSoon()
            }
        }
    }

    /// Endereza la foto nivelando el horizonte o las líneas rectas.
    func autoStraighten() {
        guard let photo = current else { return }
        status = tr("Buscando el horizonte…")
        let req = Engine.Request(url: photo.url, isRAW: photo.isRAW, settings: settings)
        let id = photo.id
        renderQueue.async { [engine] in
            let angle = engine.autoStraightenAngle(req)
            DispatchQueue.main.async {
                self.status = nil
                guard self.selectedID == id else { return }
                guard let angle else { self.flash("No se ha encontrado un horizonte ni líneas rectas claras"); return }
                let a = (angle * 10).rounded() / 10
                if abs(a - self.settings.cropAngle) < 0.05 { self.flash("La foto ya está recta"); return }
                self.settings.cropAngle = a
                self.commit("Enderezar automáticamente")
            }
        }
    }

    /// Geometría automática: endereza y corrige las verticales convergentes (como Upright Auto).
    func autoGeometry() {
        guard let photo = current else { return }
        status = tr("Analizando líneas verticales…")
        let req = Engine.Request(url: photo.url, isRAW: photo.isRAW, settings: settings)
        let id = photo.id
        renderQueue.async { [engine] in
            let g = engine.autoGeometry(req)
            DispatchQueue.main.async {
                self.status = nil
                guard self.selectedID == id else { return }
                guard let g else { self.flash("No se han encontrado líneas verticales claras"); return }
                var s = self.settings
                s.vertical = g.vertical
                s.horizontal = 0
                s.rotate = g.rotate
                guard s != self.settings else { self.flash("La geometría ya está recta"); return }
                self.settings = s
                self.commit("Geometría automática")
            }
        }
    }

    // MARK: Punto de color

    var pointIndex: Int? { settings.pointColors.firstIndex { $0.id == selectedPointID } }
    var activePointOverlay: PointColor? { showPointRange && tool != .mask ? pointIndex.map { settings.pointColors[$0] } : nil }

    func bindPoint(_ kp: WritableKeyPath<PointColor, Double>) -> Binding<Double> {
        Binding(get: {
            guard let i = self.pointIndex else { return PointColor()[keyPath: kp] }
            return self.settings.pointColors[i][keyPath: kp]
        }, set: { v in
            guard let i = self.pointIndex else { return }
            self.settings.pointColors[i][keyPath: kp] = v
        })
    }

    func pickPointColor(at p: CGPoint) {
        guard let photo = current else { return }
        let req = Engine.Request(url: photo.url, isRAW: photo.isRAW, settings: settings, maxPixel: previewTarget)
        renderQueue.async { [engine] in
            let c = engine.sampleMaskStage(req, at: p)
            DispatchQueue.main.async {
                self.tool = .none
                guard let c else { return }
                guard self.settings.pointColors.count < 8 else { self.flash("Máximo 8 puntos de color por foto"); return }
                let pc = PointColor(color: c)
                self.settings.pointColors.append(pc)
                self.selectedPointID = pc.id
                self.commit("Nuevo punto de color")
            }
        }
    }

    func deletePointColor(_ id: UUID) {
        settings.pointColors.removeAll { $0.id == id }
        if selectedPointID == id { selectedPointID = settings.pointColors.last?.id }
        commit("Eliminar punto de color")
    }

    // MARK: Máscaras

    var maskIndex: Int? { settings.masks.firstIndex { $0.id == selectedMaskID } }
    var selectedMask: Mask? { maskIndex.map { settings.masks[$0] } }
    var activeOverlay: UUID? { tool == .mask && showMaskOverlay ? selectedMaskID : nil }

    func bindMask<T>(_ kp: WritableKeyPath<Mask, T>) -> Binding<T> {
        Binding(get: {
            guard let i = self.maskIndex else { return Mask.placeholder[keyPath: kp] }
            return self.settings.masks[i][keyPath: kp]
        }, set: { v in
            guard let i = self.maskIndex else { return }
            self.settings.masks[i][keyPath: kp] = v
        })
    }

    func addMask(_ kind: MaskKind, raster: Data? = nil) {
        let s = settings
        let n = s.masks.filter { $0.kind == kind }.count + 1
        var m = Mask(name: n > 1 ? "\(tr(kind.label)) \(n)" : tr(kind.label), kind: kind)
        switch kind {
        case .linear:
            m.x0 = s.cropX + s.cropW / 2; m.y0 = s.cropY + s.cropH * 0.1
            m.x1 = m.x0; m.y1 = s.cropY + s.cropH * 0.5
        case .radial:
            m.cx = s.cropX + s.cropW / 2; m.cy = s.cropY + s.cropH / 2
            m.rx = 0.25 * s.cropW; m.ry = m.rx * imageAspect
        case .subject, .people, .background:
            m.raster = raster
        case .brush, .color, .luminance:
            break
        }
        settings.masks.append(m)
        selectedMaskID = m.id
        if tool != .mask { zoomed = false; tool = .mask }
        endEditing()
        commit(tr("Nueva máscara: %@", tr(kind.label)))
    }

    /// Crea (o vuelve a calcular) una máscara de sujeto, personas o fondo con Vision.
    func addDetectedMask(_ kind: MaskKind, replacing id: UUID? = nil) {
        guard let photo = current else { return }
        status = tr(kind == .people ? "Detectando personas…" : (kind == .background ? "Detectando fondo…" : "Detectando sujeto…"))
        var s = settings
        s.masks = []
        let req = Engine.Request(url: photo.url, isRAW: photo.isRAW, settings: s)
        renderQueue.async { [engine] in
            let data = engine.detectMask(kind, req)
            DispatchQueue.main.async {
                self.status = nil
                guard let data else {
                    self.flash(kind == .people ? "No se han encontrado personas" : "No se ha encontrado ningún sujeto")
                    return
                }
                if let id, let i = self.settings.masks.firstIndex(where: { $0.id == id }) {
                    self.settings.masks[i].raster = data
                    self.commit(tr("Volver a detectar: %@", tr(kind.label)))
                } else {
                    self.addMask(kind, raster: data)
                }
            }
        }
    }

    func deleteMask(_ id: UUID) {
        settings.masks.removeAll { $0.id == id }
        if selectedMaskID == id { selectedMaskID = settings.masks.last?.id }
        commit("Eliminar máscara")
    }

    func duplicateMask(_ id: UUID) {
        guard let i = settings.masks.firstIndex(where: { $0.id == id }) else { return }
        var m = settings.masks[i]
        m.id = UUID()
        m.name += " copia"
        settings.masks.insert(m, at: i + 1)
        selectedMaskID = m.id
        commit("Duplicar máscara")
    }

    func updateSelectedMask(_ m: Mask) {
        guard let i = maskIndex else { return }
        settings.masks[i] = m
    }

    func brushBegin(_ x: Double, _ y: Double, erase: Bool) {
        guard let i = maskIndex, settings.masks[i].kind == .brush else { return }
        settings.masks[i].strokes.append(BrushStroke(points: [x, y], size: brushSize / 400, feather: brushFeather,
                                                     flow: brushFlow, erase: erase || brushErase))
    }

    func brushMove(_ x: Double, _ y: Double) {
        guard let i = maskIndex, let last = settings.masks[i].strokes.indices.last else { return }
        let st = settings.masks[i].strokes[last]
        let n = st.points.count
        // Descarta puntos muy próximos para mantener los trazos ligeros
        if n >= 2, hypot(st.points[n - 2] - x, st.points[n - 1] - y) < st.size * 0.1 { return }
        settings.masks[i].strokes[last].points += [x, y]
    }

    func pickRange(at p: CGPoint) {
        guard let photo = current, let mid = selectedMaskID else { return }
        var s = settings
        s.masks = []
        let req = Engine.Request(url: photo.url, isRAW: photo.isRAW, settings: s, maxPixel: previewTarget)
        renderQueue.async { [engine] in
            let c = engine.sampleMaskStage(req, at: p)
            DispatchQueue.main.async {
                guard let c, let i = self.settings.masks.firstIndex(where: { $0.id == mid }) else { return }
                if self.settings.masks[i].kind == .color {
                    self.settings.masks[i].rangeColor = c
                    self.commit("Elegir color")
                } else {
                    let L = CMath.luma(c[0], c[1], c[2]) * 100
                    self.settings.masks[i].lumLow = max(0, (L - 15).rounded())
                    self.settings.masks[i].lumHigh = min(100, (L + 15).rounded())
                    self.commit("Elegir luminancia")
                }
            }
        }
    }

    // MARK: Herramienta Eliminar

    var healIndex: Int? { settings.heals.firstIndex { $0.id == selectedHealID } }

    /// Valor de la corrección seleccionada (o el valor para las nuevas si no hay ninguna).
    func healBinding(_ kp: WritableKeyPath<HealSpot, Double>, _ def: ReferenceWritableKeyPath<Store, Double>, scale: Double = 1) -> Binding<Double> {
        Binding(get: {
            if let i = self.healIndex { return self.settings.heals[i][keyPath: kp] * scale }
            return self[keyPath: def]
        }, set: { v in
            self[keyPath: def] = v
            if let i = self.healIndex { self.settings.heals[i][keyPath: kp] = v / scale }
        })
    }

    var healModeBinding: Binding<HealMode> {
        Binding(get: { self.healIndex.map { self.settings.heals[$0].mode } ?? self.healMode }, set: { m in
            self.healMode = m
            if let i = self.healIndex {
                self.settings.heals[i].mode = m
                self.commit(m == .heal ? "Modo corregir" : "Modo clonar")
            }
        })
    }

    func addHeal(at x: Double, _ y: Double) {
        let size = healSize / 1000
        let a = imageAspect
        let fallback = (x + (x > 0.5 ? -1 : 1) * size * 2.6 * (a >= 1 ? 1 : 1 / a), y)
        let src = findHealSource(x, y, size) ?? fallback
        let spot = HealSpot(x: x, y: y, sx: src.0, sy: src.1, size: size, feather: healFeather, opacity: healOpacity, mode: healMode)
        settings.heals.append(spot)
        selectedHealID = spot.id
        commit(healMode == .heal ? "Corregir" : "Clonar")
    }

    func updateHeal(_ h: HealSpot) {
        guard let i = settings.heals.firstIndex(where: { $0.id == h.id }) else { return }
        settings.heals[i] = h
    }

    func deleteHeal(_ id: UUID) {
        settings.heals.removeAll { $0.id == id }
        if selectedHealID == id { selectedHealID = nil }
        commit("Eliminar corrección")
    }

    func clearHeals() {
        settings.heals = []
        selectedHealID = nil
        commit("Borrar correcciones")
    }

    /// Busca alrededor del destino la zona con textura y tono más parecidos a su entorno.
    private func findHealSource(_ x: Double, _ y: Double, _ size: Double) -> (Double, Double)? {
        guard let cg = preview else { return nil }
        let s = settings
        let k = min(1, 400 / Double(max(cg.width, cg.height)))
        let w = max(1, Int(Double(cg.width) * k)), h = max(1, Int(Double(cg.height) * k))
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { p in
            guard let c = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: sRGBSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let preLong = max(Double(w) / s.cropW, Double(h) / s.cropH)
        let r = size * preLong
        let dx = (x - s.cropX) / s.cropW * Double(w), dy = (y - s.cropY) / s.cropH * Double(h)
        func pixel(_ px: Double, _ py: Double) -> (Double, Double, Double)? {
            let ix = Int(px), iy = Int(py)
            guard ix >= 0, iy >= 0, ix < w, iy < h else { return nil }
            let i = (iy * w + ix) * 4
            return (Double(buf[i]) / 255, Double(buf[i + 1]) / 255, Double(buf[i + 2]) / 255)
        }
        func stats(_ cx: Double, _ cy: Double, _ radii: [Double]) -> (mean: (Double, Double, Double), std: Double)? {
            var sum = (0.0, 0.0, 0.0), sq = 0.0, n = 0.0
            for rad in radii {
                for a in stride(from: 0.0, to: 2 * Double.pi, by: Double.pi / 8) {
                    guard let c = pixel(cx + cos(a) * rad, cy + sin(a) * rad) else { return nil }
                    sum.0 += c.0; sum.1 += c.1; sum.2 += c.2
                    let l = CMath.luma(c.0, c.1, c.2)
                    sq += l * l
                    n += 1
                }
            }
            let m = (sum.0 / n, sum.1 / n, sum.2 / n)
            let ml = CMath.luma(m.0, m.1, m.2)
            return (m, max(0, sq / n - ml * ml).squareRoot())
        }
        guard let ring = stats(dx, dy, [r * 1.25, r * 1.6]) else { return nil }
        var best: (Double, Double, Double)?
        for dist in [2.3, 3.3] {
            for a in stride(from: 0.0, to: 2 * Double.pi, by: Double.pi / 6) {
                let cx = dx + cos(a) * r * dist, cy = dy + sin(a) * r * dist
                guard let inner = stats(cx, cy, [r * 0.15, r * 0.5, r * 0.85]),
                      let outer = stats(cx, cy, [r * 1.25, r * 1.6]) else { continue }
                let diff = abs(inner.mean.0 - ring.mean.0) + abs(inner.mean.1 - ring.mean.1) + abs(inner.mean.2 - ring.mean.2)
                let ringDiff = abs(outer.mean.0 - ring.mean.0) + abs(outer.mean.1 - ring.mean.1) + abs(outer.mean.2 - ring.mean.2)
                let score = diff + inner.std * 1.2 + ringDiff * 0.4 + dist * 0.01
                if best == nil || score < best!.2 { best = (cx, cy, score) }
            }
        }
        guard let b = best else { return nil }
        return (s.cropX + b.0 / Double(w) * s.cropW, s.cropY + b.1 / Double(h) * s.cropH)
    }

    // MARK: Recorte

    var imageAspect: Double { Double(fullSize.width / max(1, fullSize.height)) }

    var normalizedCropRatio: Double? {
        let ia = imageAspect
        let long: Double
        switch cropAspect {
        case .free: return nil
        case .original: long = ia >= 1 ? ia : 1 / ia
        default: long = cropAspect.longRatio ?? 1
        }
        return (cropPortrait ? 1 / long : long) / ia
    }

    func toggleTool(_ t: Tool) {
        if tool == t { tool = .none; return }
        if t == .crop { cropPortrait = imageAspect < 1 }
        zoomed = false
        tool = t
        endEditing()
    }

    func setCropAspect(_ a: CropAspect) {
        cropAspect = a
        fitCropToAspect()
    }

    func toggleCropOrientation() {
        cropPortrait.toggle()
        fitCropToAspect()
    }

    private func fitCropToAspect() {
        guard let rn = normalizedCropRatio else { return }
        var s = settings
        var w = 1.0, h = 1.0 / rn
        if h > 1 { h = 1; w = rn }
        let cx = s.cropX + s.cropW / 2, cy = s.cropY + s.cropH / 2
        s.cropX = CMath.clamp(cx - w / 2, 0, 1 - w); s.cropY = CMath.clamp(cy - h / 2, 0, 1 - h)
        s.cropW = w; s.cropH = h
        settings = s
        commit(tr("Aspecto de recorte %@", tr(cropAspect.rawValue)))
    }

    func resetCrop() {
        var s = settings
        s.cropX = 0; s.cropY = 0; s.cropW = 1; s.cropH = 1; s.cropAngle = 0
        settings = s
        cropAspect = .free
        commit("Restablecer recorte")
    }

    // MARK: Zoom

    /// Zoom en la vista Revelar: 1 = 100 % (un píxel de la foto por píxel de pantalla).
    @Published var zoomLevel = 1.0
    /// Centro de la vista dentro de la foto recortada (0…1).
    @Published var zoomCenter = CGPoint(x: 0.5, y: 0.5)
    /// Marco del lienzo en coordenadas de la ventana (origen arriba a la izquierda).
    var canvasFrame = CGRect.zero
    static let zoomPresets: [Double] = [0.25, 0.5, 1, 2, 4]

    /// Tamaño en puntos de la foto recortada a un nivel de zoom.
    func displaySize(_ level: Double) -> CGSize {
        let s = settings
        return CGSize(width: fullSize.width * s.cropW * level / backingScale, height: fullSize.height * s.cropH * level / backingScale)
    }

    var fitLevel: Double {
        let one = displaySize(1)
        guard one.width > 0, one.height > 0 else { return 1 }
        return min((viewport.width - 56) / one.width, (viewport.height - 56) / one.height)
    }

    var zoomPercent: Int { Int(((zoomed ? zoomLevel : fitLevel) * 100).rounded()) }

    func clampedCenter(_ c: CGPoint, _ level: Double) -> CGPoint {
        let d = displaySize(level)
        func axis(_ v: CGFloat, _ size: CGFloat, _ view: CGFloat) -> CGFloat {
            guard size > view else { return 0.5 }
            let half = view / (2 * size)
            return min(max(v, half), 1 - half)
        }
        return CGPoint(x: axis(c.x, d.width, viewport.width), y: axis(c.y, d.height, viewport.height))
    }

    /// Acerca a un nivel centrando la vista en un punto de la foto (0…1).
    func zoom(to level: Double, at p: CGPoint? = nil) {
        let l = min(max(level, 0.05), 16)
        guard l > fitLevel * 1.01 else { zoomed = false; return }
        zoomLevel = l
        zoomCenter = clampedCenter(p ?? zoomCenter, l)
        if !zoomed { zoomed = true }
    }

    /// Cambia el zoom manteniendo fijo el punto de la foto bajo `anchor` (coordenadas del lienzo).
    func zoom(by factor: Double, anchor: CGPoint) {
        let vc = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let cur = zoomed ? zoomLevel : fitLevel
        let d0 = displaySize(cur)
        guard d0.width > 0, d0.height > 0 else { return }
        let p = zoomed
            ? CGPoint(x: zoomCenter.x + (anchor.x - vc.x) / d0.width, y: zoomCenter.y + (anchor.y - vc.y) / d0.height)
            : CGPoint(x: 0.5 + (anchor.x - vc.x) / d0.width, y: 0.5 + (anchor.y - vc.y) / d0.height)
        let l = min(max(cur * factor, fitLevel), 16)
        guard l > fitLevel * 1.01 else { zoomed = false; return }
        let d1 = displaySize(l)
        zoomLevel = l
        zoomCenter = clampedCenter(CGPoint(x: p.x - (anchor.x - vc.x) / d1.width, y: p.y - (anchor.y - vc.y) / d1.height), l)
        if !zoomed { zoomed = true }
    }

    func zoomStep(_ dir: Int) {
        let cur = zoomed ? zoomLevel : fitLevel
        if dir > 0 {
            zoom(to: Self.zoomPresets.first { $0 > cur * 1.01 } ?? 16)
        } else if let l = Self.zoomPresets.last(where: { $0 < cur * 0.99 }), l > fitLevel {
            zoom(to: l)
        } else {
            zoomed = false
        }
    }

    // MARK: Rueda, trackpad y deslizadores

    /// Deslizador bajo el ratón: la rueda y las flechas ↑↓ lo ajustan.
    struct HoverSlider {
        let id: UUID
        let get: () -> Double
        let set: (Double) -> Void
        let range: ClosedRange<Double>
        let step: Double
        let commit: () -> Void
    }

    private(set) var hoverSlider: HoverSlider?
    private var hoverSince = Date.distantPast
    private var scrollToSlider = false
    private var lastPassScroll = Date.distantPast
    private var wheelAccum = 0.0
    private var wheelCommit: DispatchWorkItem?

    func setHoverSlider(_ h: HoverSlider?) {
        if h?.id != hoverSlider?.id { hoverSince = Date() }
        hoverSlider = h
    }

    /// Mueve el deslizador bajo el ratón `steps` pasos (1 paso = 1/200 del recorrido como mínimo).
    func nudgeSlider(_ steps: Double) {
        guard let h = hoverSlider else { return }
        let unit = max(h.step, (h.range.upperBound - h.range.lowerBound) / 200)
        var v = h.get() + steps * unit
        v = min(max((v / h.step).rounded() * h.step, h.range.lowerBound), h.range.upperBound)
        h.set(v)
        wheelCommit?.cancel()
        let w = DispatchWorkItem { h.commit() }
        wheelCommit = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    private func handleScroll(_ e: NSEvent) -> Bool {
        if e.type == .scrollWheel {
            // Inercia: pertenece al gesto anterior
            if e.momentumPhase != [] { return scrollToSlider }
            if e.phase == .began || e.phase == [] {
                // Solo si el ratón lleva un momento quieto sobre el deslizador y no se está desplazando el panel
                scrollToSlider = hoverSlider != nil && Date().timeIntervalSince(hoverSince) > 0.35
                    && Date().timeIntervalSince(lastPassScroll) > 0.5
            }
            if scrollToSlider, hoverSlider != nil {
                let dy = e.scrollingDeltaY != 0 ? e.scrollingDeltaY : e.scrollingDeltaX
                let phys = e.isDirectionInvertedFromDevice ? -dy : dy
                wheelAccum += e.hasPreciseScrollingDeltas ? phys / 6 : phys
                let steps = wheelAccum.rounded(.towardZero)
                if steps != 0 {
                    wheelAccum -= steps
                    nudgeSlider(steps * (e.modifierFlags.contains(.shift) ? 5 : 1))
                }
                return true
            }
        }
        guard module == .develop, tool == .none, current != nil, let win = e.window,
              !splitActive, !sideBySideActive else {
            if e.type == .scrollWheel { lastPassScroll = Date() }
            return false
        }
        let loc = CGPoint(x: e.locationInWindow.x, y: (win.contentView?.bounds.height ?? 0) - e.locationInWindow.y)
        guard canvasFrame.contains(loc) else {
            if e.type == .scrollWheel { lastPassScroll = Date() }
            return false
        }
        let anchor = CGPoint(x: loc.x - canvasFrame.minX, y: loc.y - canvasFrame.minY)
        if e.type == .magnify {
            zoom(by: 1 + e.magnification, anchor: anchor)
            return true
        }
        let phys = e.isDirectionInvertedFromDevice ? -e.scrollingDeltaY : e.scrollingDeltaY
        if !e.hasPreciseScrollingDeltas {
            // Rueda del ratón: zoom
            zoom(by: pow(1.15, phys), anchor: anchor)
            return true
        }
        if e.modifierFlags.contains(.command) {
            zoom(by: pow(1.008, phys), anchor: anchor)
            return true
        }
        guard zoomed else { return false }
        // Dos dedos: desplazar la foto ampliada
        let d = displaySize(zoomLevel)
        zoomCenter = clampedCenter(CGPoint(x: zoomCenter.x - e.scrollingDeltaX / d.width, y: zoomCenter.y - e.scrollingDeltaY / d.height),
                                   zoomLevel)
        return true
    }

    // MARK: Teclado

    /// Quita el foco de los campos numéricos para que funcionen los atajos de una tecla.
    func endEditing() {
        DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        switch e.keyCode {
        case 123: step(-1); return true
        case 124: step(1); return true
        case 125, 126:
            guard hoverSlider != nil else { return false }
            nudgeSlider((e.keyCode == 126 ? 1 : -1) * (e.modifierFlags.contains(.shift) ? 5 : 1))
            return true
        case 36, 76: if tool != .none { tool = .none; return true }; return false
        case 53: if tool != .none { tool = .none; return true }; if zoomed { zoomed = false; return true }; return false
        case 51, 117:
            if tool == .mask, let id = selectedMaskID { deleteMask(id); return true }
            if tool == .heal, let id = selectedHealID { deleteHeal(id); return true }
            return false
        case 48: withAnimation(.easeInOut(duration: 0.2)) { panelsHidden.toggle() }; return true
        default: break
        }
        guard module == .develop || ["g", "d", "e"].contains(e.charactersIgnoringModifiers?.lowercased() ?? "") else { return false }
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "\\": showBefore.toggle()
        case "y": splitView.toggle(); if splitView { showBefore = false }
        case "j": let on = !(clipHigh || clipLow); clipHigh = on; clipLow = on
        case "q": toggleTool(.heal)
        case "h": if tool == .heal { showHealSpots.toggle() } else { return false }
        case "?", "/": showShortcuts.toggle()
        case "r": toggleTool(.crop)
        case "m": toggleTool(.mask)
        case "o": if tool == .mask { showMaskOverlay.toggle() } else { return false }
        case "w": toggleTool(.whiteBalance)
        case "x": if tool == .crop { toggleCropOrientation() } else { return false }
        case "z", " ": if zoomed { zoomed = false } else { zoom(to: max(1, fitLevel * 2)) }
        case "g": module = .library
        case "d", "e": module = .develop; scheduleRender()
        default: return false
        }
        return true
    }

    // MARK: Exportación

    enum ExportScope: Int { case selected, marked, all }

    struct ExportDestination {
        var sameFolder = false      // junto a cada original
        var folder: URL?            // carpeta elegida
        var subfolder = ""          // opcional, dentro del destino
        var naming = ExportNaming.original
        var text = ""               // sufijo o nombre base
    }

    /// Progreso de la exportación en curso (0…1) y texto; nil si no se exporta nada.
    @Published var exportProgress: Double?
    @Published var exportLabel = ""
    private let exportCancel = CancelFlag()

    func exportItems(_ scope: ExportScope) -> [Photo] {
        switch scope {
        case .selected: return photos.filter { $0.id == selectedID }
        case .marked: return photos.filter { $0.id == selectedID || multiSelection.contains($0.id) }
        case .all: return photos
        }
    }

    func export(_ scope: ExportScope, options: ExportOptions, destination d: ExportDestination) {
        if let i = currentIndex { photos[i].settings = settings }
        let all = exportItems(scope)
        let items = all.filter { !$0.missing }
        guard !items.isEmpty else { flash("No hay fotos que exportar"); return }
        var base = d.folder
        if !d.sameFolder && base == nil {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = tr("Exportar aquí")
            guard panel.runModal() == .OK, let dir = panel.url else { return }
            base = dir
        }
        let skipped = all.count - items.count
        exportCancel.value = false
        exportProgress = 0
        exportLabel = tr("Exportando %@ de %@", "0", "\(items.count)")
        let jobs = items.map { Engine.Request(url: $0.url, isRAW: $0.isRAW, settings: $0.settings, maxPixel: nil, fresh: true) }
        let cancel = exportCancel
        exportQueue.async { [exportEngine] in
            var done: [URL] = []
            var errors = 0
            for (n, job) in jobs.enumerated() {
                if cancel.value { break }
                var dir = d.sameFolder ? job.url.deletingLastPathComponent() : base!
                let sub = d.subfolder.trimmingCharacters(in: .whitespaces)
                if !sub.isEmpty { dir.appendPathComponent(sub, isDirectory: true) }
                let original = job.url.deletingPathExtension().lastPathComponent
                let name: String
                switch d.naming {
                case .original: name = original
                case .suffix: name = original + d.text
                case .custom:
                    let digits = max(3, String(jobs.count).count)
                    name = (d.text.isEmpty ? "Foto" : d.text) + "-" + String(format: "%0\(digits)d", n + 1)
                }
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let out = Self.uniqueURL(in: dir, base: name, ext: options.format.ext)
                    try exportEngine.export(job, to: out, options: options)
                    done.append(out)
                } catch { errors += 1 }
                DispatchQueue.main.async {
                    self.exportProgress = Double(n + 1) / Double(jobs.count)
                    self.exportLabel = tr("Exportando %@ de %@", "\(n + 1)", "\(jobs.count)")
                }
            }
            DispatchQueue.main.async {
                self.exportProgress = nil
                var msg = tr(cancel.value ? "Exportación cancelada: %@ fotos" : "Exportadas %@ fotos", "\(done.count)")
                if errors > 0 { msg += tr(" · %@ con errores", "\(errors)") }
                if skipped > 0 { msg += tr(" · %@ no encontradas", "\(skipped)") }
                self.flash(msg)
                if !done.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(done) }
            }
        }
    }

    func cancelExport() { exportCancel.value = true }

    nonisolated static func uniqueURL(in dir: URL, base: String, ext: String) -> URL {
        var url = dir.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base)-\(n).\(ext)")
            n += 1
        }
        return url
    }

    func flash(_ msg: String) {
        let m = tr(msg)
        status = m
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if self.status == m { self.status = nil } }
    }

    // MARK: Catálogo

    private var catalogURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Revela")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("catalog.json")
    }

    /// Completa con valores por defecto los ajustes guardados por versiones anteriores (claves que falten).
    private static func migrateCatalog(_ data: Data) -> Data? {
        func json<T: Encodable>(_ v: T) -> [String: Any] {
            guard let d = try? JSONEncoder().encode(v) else { return [:] }
            return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
        }
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return data }
        let defaults = json(EditSettings()), maskDefaults = json(Mask.placeholder)
        let healDefaults = json(HealSpot(x: 0, y: 0, sx: 0, sy: 0, size: 0.02)), pointDefaults = json(PointColor())
        /// Mezcla profunda: lo guardado gana, lo que falta se toma de los valores por defecto.
        func merge(_ d: [String: Any], _ saved: [String: Any]) -> [String: Any] {
            var out = d
            for (k, v) in saved {
                if let dv = d[k] as? [String: Any], let sv = v as? [String: Any] { out[k] = merge(dv, sv) } else { out[k] = v }
            }
            return out
        }
        func fixSettings(_ saved: [String: Any]) -> [String: Any] {
            var st = merge(defaults, saved)
            st["masks"] = ((st["masks"] as? [[String: Any]]) ?? []).map { merge(maskDefaults, $0) }
            st["heals"] = ((st["heals"] as? [[String: Any]]) ?? []).map { merge(healDefaults, $0) }
            st["pointColors"] = ((st["pointColors"] as? [[String: Any]]) ?? []).map { merge(pointDefaults, $0) }
            return st
        }
        func fix(_ list: Any?) -> [[String: Any]] {
            ((list as? [[String: Any]]) ?? []).map { entry in
                var e = entry
                e["settings"] = fixSettings(entry["settings"] as? [String: Any] ?? [:])
                return e
            }
        }
        root["photos"] = fix(root["photos"])
        root["presets"] = fix(root["presets"])
        return try? JSONSerialization.data(withJSONObject: root)
    }

    private func loadCatalog() {
        guard let raw = try? Data(contentsOf: catalogURL), let data = Self.migrateCatalog(raw),
              let cat = try? JSONDecoder().decode(Catalog.self, from: data) else { return }
        userPresets = cat.presets
        // Se conservan también las fotos que faltan, marcadas, para poder localizarlas
        photos = cat.photos.map { e in
            let u = URL(fileURLWithPath: e.path)
            return Photo(url: u, isRAW: isRAWFile(u), missing: !FileManager.default.fileExists(atPath: e.path), settings: e.settings)
        }
        for p in photos where !p.missing { loadThumbnail(p) }
        if let first = photos.first(where: { !$0.missing }) ?? photos.first { select(first.id) }
    }

    /// Pide la nueva ubicación de una foto que falta y, de paso, reencuentra en esa carpeta otras que falten.
    func locate(_ id: UUID) {
        guard let i = photos.firstIndex(where: { $0.id == id }) else { return }
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image, .rawImage]
        p.message = tr("¿Dónde está ahora %@?", photos[i].name)
        p.prompt = tr("Localizar")
        guard p.runModal() == .OK, let url = p.url else { return }
        relink(i, to: url)
        let dir = url.deletingLastPathComponent()
        var found = 0
        for j in photos.indices where photos[j].missing {
            let cand = dir.appendingPathComponent(photos[j].name)
            if FileManager.default.fileExists(atPath: cand.path) { relink(j, to: cand); found += 1 }
        }
        flash(found > 0 ? tr("Foto localizada y %@ más en la misma carpeta", "\(found)") : "Foto localizada")
        saveCatalogSoon()
        if id == selectedID { scheduleRender() }
    }

    private func relink(_ i: Int, to url: URL) {
        photos[i].url = url
        photos[i].missing = false
        photos[i].thumbnail = nil
        loadThumbnail(photos[i])
    }

    var missingCount: Int { photos.filter(\.missing).count }

    func saveCatalogSoon() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveCatalog() } }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: w)
    }

    func saveCatalog() {
        if let i = currentIndex { photos[i].settings = settings }
        let cat = Catalog(photos: photos.map { Catalog.Entry(path: $0.url.path, settings: $0.settings) }, presets: userPresets)
        if let data = try? JSONEncoder().encode(cat) { try? data.write(to: catalogURL, options: .atomic) }
    }
}

// MARK: - Controles

/// Estado local de vista. Equivale a @State, pero no depende del plugin de macros de SwiftUI
/// (que no viene con las Command Line Tools).
@propertyWrapper
struct Local<T>: DynamicProperty {
    final class Box: ObservableObject {
        @Published var value: T
        init(_ v: T) { value = v }
    }
    @StateObject private var box: Box
    init(wrappedValue: T) { _box = StateObject(wrappedValue: Box(wrappedValue)) }
    var wrappedValue: T {
        get { box.value }
        nonmutating set { box.value = newValue }
    }
    var projectedValue: Binding<T> { $box.value }
}

func formatValue(_ v: Double, _ decimals: Int, _ signed: Bool) -> String {
    let s = String(format: "%.\(decimals)f", v)
    return signed && v > 0 ? "+" + s : s
}

/// Fondo que reacciona al ratón con una transición suave.
struct HoverBackground: ViewModifier {
    var radius: CGFloat = 5
    var active = false
    @Local private var isHover = false
    func body(content: Content) -> some View {
        content
            .background(Rectangle().fill(active ? Theme.raised : (isHover ? Theme.fill : Color.clear)))
            .overlay(Rectangle().stroke(Theme.select.opacity(active ? 0.85 : 0), lineWidth: 1))
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { isHover = h } }
    }
}

extension View {
    func hoverBackground(radius: CGFloat = 5, active: Bool = false) -> some View {
        modifier(HoverBackground(radius: radius, active: active))
    }
}

/// Botón sobrio: gris translúcido o, si es principal, blanco con texto negro.
struct GhostButtonStyle: ButtonStyle {
    var prominent = false
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        GhostButtonBody(configuration: configuration, prominent: prominent, compact: compact)
    }
}

struct GhostButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    let compact: Bool
    @Local private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(.system(size: compact ? 10.5 : 11.5, weight: prominent ? .semibold : .medium))
            .foregroundColor(prominent ? Theme.onSelect : Theme.text)
            .padding(.horizontal, compact ? 8 : 12)
            .padding(.vertical, compact ? 3 : 5)
            .background(Rectangle().fill(prominent
                ? Theme.select.opacity(pressed ? 0.75 : (hover ? 1 : 0.92))
                : Color.white.opacity(pressed ? 0.12 : (hover ? 0.06 : 0))))
            .overlay(Rectangle().stroke(prominent ? Color.clear : (hover ? Theme.secondary.opacity(0.6) : Theme.border), lineWidth: 1))
            .opacity(enabled ? 1 : 0.35)
            .scaleEffect(pressed ? 0.97 : 1)
            .contentShape(Rectangle())
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
            .animation(.easeOut(duration: 0.08), value: pressed)
    }
}

struct IconButton: View {
    let icon: String
    let help: String
    var active = false
    var size: CGFloat = 13
    let action: () -> Void
    @Local private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: active ? .semibold : .regular))
                .foregroundColor(active ? Theme.onSelect : (hover ? Theme.text : Theme.secondary))
                .frame(width: 30, height: 26)
                .background(Rectangle().fill(active ? Theme.select : (hover ? Theme.fill : Color.clear)))
                .overlay(Rectangle().stroke(hover && !active ? Theme.border : Color.clear, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .help(tr(help))
    }
}

/// Control segmentado monocromo.
struct Segmented<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                let on = opt.0 == selection
                Text(tr(opt.1))
                    .font(.system(size: 10.5, weight: on ? .semibold : .regular))
                    .foregroundColor(on ? Theme.onSelect : Theme.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
                    .background(Rectangle().fill(on ? Theme.select : Color.clear))
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeOut(duration: 0.12)) { selection = opt.0 } }
            }
        }
        .overlay(Rectangle().stroke(Theme.border, lineWidth: 1))
    }
}

struct MonoCheckbox: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { withAnimation(.easeOut(duration: 0.12)) { configuration.isOn.toggle() } } label: {
            HStack(spacing: 7) {
                Rectangle()
                    .fill(configuration.isOn ? Theme.select : Color.clear)
                    .overlay(Rectangle().stroke(configuration.isOn ? Color.clear : Theme.secondary.opacity(0.6), lineWidth: 1))
                    .overlay(Image(systemName: "checkmark").font(.system(size: 7.5, weight: .heavy)).foregroundColor(Theme.onSelect)
                        .opacity(configuration.isOn ? 1 : 0))
                    .frame(width: 13, height: 13)
                configuration.label.font(.system(size: 11)).foregroundColor(Theme.text)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(tr(text).uppercased()).font(.system(size: 9.5, weight: .semibold)).tracking(0.7).foregroundColor(Theme.secondary)
            .lineLimit(1).minimumScaleFactor(0.8).frame(width: 82, alignment: .leading)
    }
}

struct SliderTrack: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var defaultValue: Double = 0
    var track: [Color]? = nil
    var onCommit: () -> Void
    @Local private var start: Double?
    @Local private var lastTap = Date.distantPast
    @Local private var hover = false

    var body: some View {
        GeometryReader { g in
            let w = max(g.size.width, 20)
            let span = range.upperBound - range.lowerBound
            let t = CGFloat((value - range.lowerBound) / span)
            let d = CGFloat((min(max(defaultValue, range.lowerBound), range.upperBound) - range.lowerBound) / span)
            let active = start != nil
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(track.map { AnyShapeStyle(LinearGradient(colors: $0, startPoint: .leading, endPoint: .trailing)) } ?? AnyShapeStyle(Theme.track))
                    .frame(height: track == nil ? 1 : 2)
                    .opacity(track == nil ? 1 : 0.75)
                    .padding(.horizontal, 5)
                if track == nil {
                    // Relleno desde el valor por defecto hasta el actual: se ve de un vistazo qué se ha tocado
                    Rectangle().fill(Theme.text.opacity(0.8))
                        .frame(width: abs(t - d) * (w - 10), height: 1)
                        .offset(x: 5 + min(t, d) * (w - 10))
                }
                if range.lowerBound < 0 && range.upperBound > 0 {
                    Rectangle().fill(Color.white.opacity(0.3)).frame(width: 1, height: 7).offset(x: 5 + d * (w - 10) - 0.5)
                }
                Rectangle()
                    .fill(Color(white: active || hover ? 1 : 0.92))
                    .frame(width: active ? 3 : 2, height: 11)
                    .offset(x: 5 + t * (w - 10) - (active ? 1.5 : 1))
                    .animation(.easeOut(duration: 0.1), value: active)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if start == nil {
                            let thumbX = t * (w - 10) + 5
                            start = abs(v.startLocation.x - thumbX) > 7 ? valueAt(v.startLocation.x, w) : value
                        }
                        let fine = NSEvent.modifierFlags.contains(.option) ? 0.15 : 1.0
                        value = snap((start ?? value) + Double(v.translation.width / (w - 10)) * span * fine)
                    }
                    .onEnded { v in
                        start = nil
                        if abs(v.translation.width) < 1 {
                            if Date().timeIntervalSince(lastTap) < 0.35 { withAnimation(.easeOut(duration: 0.15)) { value = defaultValue } }
                            lastTap = Date()
                        }
                        onCommit()
                    }
            )
        }
    }

    private func valueAt(_ x: CGFloat, _ w: CGFloat) -> Double {
        range.lowerBound + Double(min(max((x - 5) / (w - 10), 0), 1)) * (range.upperBound - range.lowerBound)
    }

    private func snap(_ v: Double) -> Double {
        let c = min(max(v, range.lowerBound), range.upperBound)
        return min(max((c / step).rounded() * step, range.lowerBound), range.upperBound)
    }
}

struct ValueField: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let decimals: Int
    let signed: Bool
    var isDefault = false
    var display: String?
    var onCommit: () -> Void
    @Local private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        if let display {
            Text(display).font(.system(size: 10.5, design: .monospaced)).foregroundColor(isDefault ? Theme.dim : Theme.text)
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 10.5, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .foregroundColor(focused ? .white : (isDefault ? Theme.dim : Theme.text))
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(Rectangle().fill(focused ? Color.white.opacity(0.08) : Color.clear))
                .overlay(Rectangle().stroke(focused ? Theme.select.opacity(0.7) : Color.clear, lineWidth: 1))
                .focused($focused)
                .onAppear { text = formatValue(value, decimals, signed) }
                .onChange(of: value) { _, v in if !focused { text = formatValue(v, decimals, signed) } }
                .onSubmit {
                    let clean = text.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "+", with: "")
                    if let v = Double(clean) {
                        value = min(max(v, range.lowerBound), range.upperBound)
                        onCommit()
                    }
                    text = formatValue(value, decimals, signed)
                    focused = false
                }
        }
    }
}

/// Deslizador con etiqueta y valor. Solo se redibuja si cambian sus datos (valor, rango, etiqueta…),
/// no con cada ajuste de otro deslizador: es lo que más pesaba al arrastrar.
struct LRSlider: View {
    let label: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let defaultValue: Double
    let step: Double
    let decimals: Int
    let track: [Color]?
    let display: String?

    init(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double> = -100...100, def: Double = 0,
         step: Double = 1, decimals: Int = 0, track: [Color]? = nil, display: String? = nil) {
        self.label = label
        self.value = value
        self.range = range
        self.defaultValue = def
        self.step = step
        self.decimals = decimals
        self.track = track
        self.display = display
    }

    var body: some View {
        LRSliderRow(label: label, value: value, current: value.wrappedValue, range: range, defaultValue: defaultValue,
                    step: step, decimals: decimals, track: track, display: display)
            .equatable()
    }
}

struct LRSliderRow: View, Equatable {
    @Environment(\.storeRef) private var store
    let label: String
    @Binding var value: Double
    /// Valor en el momento de construir la fila: es lo que se compara (el Binding no es comparable).
    let current: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    let step: Double
    let decimals: Int
    let track: [Color]?
    let display: String?
    @Local private var hover = false
    @Local private var token = UUID()

    var body: some View {
        let isDefault = abs(value - defaultValue) < step / 2
        HStack(spacing: 8) {
            Text(tr(label))
                .font(.system(size: 11))
                .foregroundColor(hover ? .white : (isDefault ? Theme.secondary : Theme.text))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: 82, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    withAnimation(.easeOut(duration: 0.15)) { value = defaultValue }
                    commit()
                }
                .help("Doble clic para restablecer · ⌥ + arrastrar para ajuste fino")
            SliderTrack(value: $value, range: range, step: step, defaultValue: defaultValue, track: track, onCommit: commit)
            ValueField(value: $value, range: range, decimals: decimals, signed: range.lowerBound < 0, isDefault: isDefault,
                       display: display, onCommit: commit)
                .frame(width: 42)
            Marker(on: !isDefault)
        }
        .frame(height: 19)
        .overlay(Rectangle().fill(Theme.rule).frame(height: 1), alignment: .top)
        .onHover { h in
            withAnimation(.easeOut(duration: 0.1)) { hover = h }
            if h {
                let b = $value
                store?.setHoverSlider(Store.HoverSlider(id: token, get: { b.wrappedValue }, set: { b.wrappedValue = $0 },
                                                       range: range, step: step, commit: commit))
            } else if store?.hoverSlider?.id == token {
                store?.setHoverSlider(nil)
            }
        }
    }

    static func == (a: LRSliderRow, b: LRSliderRow) -> Bool {
        a.label == b.label && a.current == b.current && a.range == b.range && a.defaultValue == b.defaultValue
            && a.step == b.step && a.decimals == b.decimals && a.track == b.track && a.display == b.display
    }

    private func commit() { store?.commit("\(tr(label)) \(formatValue(value, decimals, range.lowerBound < 0))") }
}

struct SubHeader: View {
    @EnvironmentObject var store: Store
    let title: String
    var trailing: AnyView? = nil
    var group: AdjustGroup? = nil
    @Local private var hover = false
    init(_ title: String, trailing: AnyView? = nil, reset group: AdjustGroup? = nil) {
        self.title = title
        self.trailing = trailing
        self.group = group
    }
    var body: some View {
        HStack(spacing: 6) {
            Text(tr(title).uppercased()).font(.system(size: 9.5, weight: .bold)).tracking(1)
                .foregroundColor(group != nil && hover ? .white : Theme.text)
                .contentShape(Rectangle())
                .onHover { hover = $0 }
                .onTapGesture(count: 2) { if let group { store.resetGroup(group, tr(title).lowercased()) } }
                .help(group != nil ? tr("Doble clic para restablecer %@", tr(title).lowercased()) : "")
            Spacer(minLength: 0)
            if let trailing { trailing }
        }
        .padding(.top, 5)
        .padding(.bottom, 2)
        .overlay(Rectangle().fill(Theme.separator).frame(height: 1), alignment: .top)
        .padding(.top, 4)
    }
}

struct PanelSection<Content: View>: View {
    @EnvironmentObject var store: Store
    let title: String
    let group: AdjustGroup?
    @AppStorage private var open: Bool
    @AppStorage("panels.solo") private var solo = false
    @Local private var hover = false
    let content: Content

    /// Paneles de revelado de la derecha (para el modo solo).
    static var developTitles: [String] {
        ["Básico", "Curva de tonos", "Mezcla de colores", "Mezcla B/N", "Gradación de color", "Detalle", "Óptica",
         "Geometría", "Efectos", "Calibración"]
    }

    init(_ title: String, open: Bool = true, group: AdjustGroup? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.group = group
        self._open = AppStorage(wrappedValue: open, "panel." + title)
        self.content = content()
    }

    var body: some View {
        let raw = store.current?.isRAW ?? false
        let modified = group.map { store.settings.isModified($0, raw: raw) } ?? false
        let disabled = group.map { store.disabledGroups.contains($0) } ?? false
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let n = Self.developTitles.firstIndex(of: title) {
                    // "Mezcla de colores" y "Mezcla B/N" son el mismo panel: comparten número
                    Text(String(format: "%02d", n >= 3 ? n : n + 1))
                        .font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.dim)
                }
                Text(tr(title))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(disabled ? Theme.dim : (open || hover ? Theme.text : Theme.secondary))
                    .strikethrough(disabled, color: Theme.dim)
                Spacer()
                if modified && !disabled && !hover { Marker() }
                if let group, modified || disabled {
                    headerIcon(disabled ? "eye.slash" : "eye", disabled ? "Activar el panel" : "Desactivar el panel para ver qué aporta",
                               on: disabled || hover) { store.toggleGroup(group) }
                }
                if let group, modified, hover {
                    headerIcon("arrow.counterclockwise", tr("Restablecer %@", tr(title).lowercased()), on: true) {
                        store.resetGroup(group, tr(title).lowercased())
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(hover ? Theme.secondary : Theme.dim)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.white.opacity(hover ? 0.04 : 0))
            .contentShape(Rectangle())
            .onTapGesture { toggleOpen() }
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
            .help(Self.developTitles.contains(title) ? tr("⌥-clic: abrir solo este panel") : "")
            .contextMenu {
                if Self.developTitles.contains(title) {
                    Toggle("Modo solo (un panel abierto)", isOn: $solo)
                    Divider()
                    Button("Expandir todos") { for t in Self.developTitles { UserDefaults.standard.set(true, forKey: "panel." + t) } }
                    Button("Contraer todos") { for t in Self.developTitles { UserDefaults.standard.set(false, forKey: "panel." + t) } }
                }
            }
            if open {
                VStack(alignment: .leading, spacing: 3) { content }
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                    .padding(.bottom, 9)
                    .transition(.opacity)
            }
            Rectangle().fill(Theme.separator).frame(height: 1)
        }
    }

    /// Clic: abre o cierra. ⌥-clic (o modo solo) deja abierto solo este panel.
    private func toggleOpen() {
        let only = NSEvent.modifierFlags.contains(.option) || (solo && !open)
        withAnimation(.easeInOut(duration: 0.22)) {
            if only && Self.developTitles.contains(title) {
                for t in Self.developTitles where t != title { UserDefaults.standard.set(false, forKey: "panel." + t) }
                open = true
            } else {
                open.toggle()
            }
        }
    }

    private func headerIcon(_ icon: String, _ help: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 10))
                .foregroundColor(on ? Theme.text : Theme.dim)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tr(help))
    }
}

struct SmallButton: View {
    let title: String
    var prominent = false
    let action: () -> Void
    init(_ title: String, prominent: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.prominent = prominent
        self.action = action
    }
    var body: some View {
        Button(tr(title), action: action).buttonStyle(GhostButtonStyle(prominent: prominent, compact: true))
    }
}

struct Separator: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(Color.black.opacity(0.55)).frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

struct HintText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(tr(text)).font(.system(size: 11)).foregroundColor(Theme.dim).fixedSize(horizontal: false, vertical: true)
    }
}


// MARK: - Histograma, herramientas y paneles

struct HistogramView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var pv: PreviewModel
    @Local private var zone: Int?
    @Local private var startValue = 0.0
    private static let zones: [(String, WritableKeyPath<EditSettings, Double>, Double, ClosedRange<Double>)] = [
        ("Negros", \.blacks, 200, -100...100), ("Sombras", \.shadows, 200, -100...100), ("Exposición", \.exposure, 4, -5...5),
        ("Iluminaciones", \.highlights, 200, -100...100), ("Blancos", \.whites, 200, -100...100),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { g in
                ZStack {
                    Canvas { ctx, size in draw(ctx, size) }
                    VStack {
                        HStack(alignment: .top) {
                            clipButton(low: true)
                            Spacer()
                            if let z = zone {
                                Text(Self.zones[z].0).font(.system(size: 10, weight: .semibold)).foregroundColor(.white)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Rectangle().fill(Color.black.opacity(0.6)))
                            }
                            Spacer()
                            clipButton(low: false)
                        }
                        Spacer()
                    }
                    .padding(5)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { v in
                            if zone == nil {
                                let x = v.startLocation.x / g.size.width
                                let z = x < 0.12 ? 0 : x < 0.35 ? 1 : x < 0.65 ? 2 : x < 0.88 ? 3 : 4
                                zone = z
                                startValue = store.settings[keyPath: Self.zones[z].1]
                            }
                            guard let z = zone else { return }
                            let (_, kp, k, range) = Self.zones[z]
                            var nv = startValue + Double(v.translation.width / g.size.width) * k
                            nv = z == 2 ? (nv * 100).rounded() / 100 : nv.rounded()
                            store.settings[keyPath: kp] = min(max(nv, range.lowerBound), range.upperBound)
                        }
                        .onEnded { _ in
                            if let z = zone { store.commit(Self.zones[z].0 + " (histograma)") }
                            zone = nil
                        }
                )
            }
            .frame(height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.separator, lineWidth: 1))
            Text(store.current?.exif.isEmpty == false ? store.current!.exif : " ")
                .font(.system(size: 10).monospacedDigit()).foregroundColor(Theme.dim).lineLimit(1)
                .padding(.horizontal, 2)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 9)
        .help("Arrastra sobre el histograma para ajustar negros, sombras, exposición, iluminaciones o blancos")
    }

    private func clipButton(low: Bool) -> some View {
        let clipped = low ? pv.histogram?.clipLow == true : pv.histogram?.clipHigh == true
        let on = low ? store.clipLow : store.clipHigh
        return Button {
            if low { store.clipLow.toggle() } else { store.clipHigh.toggle() }
        } label: {
            Image(systemName: on ? "triangle.fill" : "triangle")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundColor(on ? .white : (clipped ? Theme.text : Theme.dim))
                .padding(4)
                .background(Circle().fill(on ? Color.white.opacity(0.18) : Color.clear))
        }
        .buttonStyle(.plain)
        .help(low ? "Mostrar sombras empastadas en azul (J)" : "Mostrar luces quemadas en rojo (J)")
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.06)))
        if let z = zone {
            let bounds: [(CGFloat, CGFloat)] = [(0, 0.12), (0.12, 0.35), (0.35, 0.65), (0.65, 0.88), (0.88, 1)]
            let (a, b) = bounds[z]
            ctx.fill(Path(CGRect(x: a * size.width, y: 0, width: (b - a) * size.width, height: size.height)), with: .color(.white.opacity(0.06)))
        }
        for q in 1..<4 {
            let x = CGFloat(q) / 4 * size.width
            ctx.stroke(Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)) },
                       with: .color(.white.opacity(0.05)))
        }
        guard let h = pv.histogram else { return }
        var c = ctx
        c.blendMode = .plusLighter
        for (arr, col) in [(h.r, Color(red: 0.85, green: 0.22, blue: 0.22)), (h.g, Color(red: 0.25, green: 0.75, blue: 0.3)), (h.b, Color(red: 0.3, green: 0.45, blue: 0.95))] {
            var p = Path()
            p.move(to: CGPoint(x: 0, y: size.height))
            for i in 0..<256 {
                p.addLine(to: CGPoint(x: CGFloat(i) / 255 * size.width, y: size.height - CGFloat(arr[i]) * size.height * 0.9))
            }
            p.addLine(to: CGPoint(x: size.width, y: size.height))
            p.closeSubpath()
            c.fill(p, with: .color(col.opacity(0.55)))
        }
    }
}

struct ToolStrip: View {
    @EnvironmentObject var store: Store
    var body: some View {
        HStack(spacing: 0) {
            cell("crop", "Recortar", "Recortar y enderezar (R)", .crop)
            cell("bandage", "Manchas", "Eliminar manchas y objetos (Q)", .heal)
            cell("circle.dashed.inset.filled", "Máscaras", "Máscaras (M)", .mask)
            cell("eyedropper", "Balance", "Balance de blancos con cuentagotas (W)", .whiteBalance)
        }
        .frame(maxWidth: .infinity)
    }

    /// Celda de herramienta: la activa se invierte (gris claro) y lleva el marcador verde.
    private func cell(_ icon: String, _ label: String, _ help: String, _ t: Store.Tool) -> some View {
        let on = store.tool == t
        return Button { store.toggleTool(t) } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 13, weight: on ? .semibold : .regular))
                Text(tr(label).uppercased()).font(.system(size: 8.5, weight: on ? .bold : .medium)).tracking(0.6)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundColor(on ? Theme.onSelect : Theme.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(on ? Theme.select : Color.clear)
            .overlay(Marker(on: on).padding(5), alignment: .topTrailing)
            .overlay(Rectangle().fill(Theme.separator).frame(width: 1), alignment: .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tr(help))
    }
}

/// Bloque de la herramienta activa: continúa su celda invertida (línea clara arriba) y se separa de los ajustes globales.
struct ToolBlock<Content: View>: View {
    let title: String
    let icon: String
    let onDone: () -> Void
    let content: Content

    init(_ title: String, icon: String, onDone: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.onDone = onDone
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(tr(title)).font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
                Spacer()
                SmallButton("Hecho", prominent: true, action: onDone)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 4)
            content
        }
        .background(Theme.raised)
        .overlay(Rectangle().fill(Theme.select).frame(height: 3), alignment: .top)
        .overlay(Rectangle().fill(Theme.separator).frame(height: 1), alignment: .bottom)
    }
}

/// Rótulo que separa bloques del panel derecho.
struct SectionDivider: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        HStack(spacing: 8) {
            Text(tr(title).uppercased()).font(.system(size: 9.5, weight: .semibold)).tracking(1).foregroundColor(Theme.dim)
            Rectangle().fill(Theme.border).frame(height: 1)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }
}

struct CropPanel: View {
    @EnvironmentObject var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                FieldLabel("Aspecto")
                Picker("", selection: Binding(get: { store.cropAspect }, set: { store.setCropAspect($0) })) {
                    ForEach(CropAspect.allCases) { Text(tr($0.rawValue)).tag($0) }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 112)
                IconButton(icon: "rectangle.portrait.rotate", help: "Cambiar orientación del recorte (X)") { store.toggleCropOrientation() }
                    .disabled(store.cropAspect == .free)
                    .opacity(store.cropAspect == .free ? 0.4 : 1)
            }
            LRSlider("Ángulo", store.bind(\.cropAngle), -45...45, step: 0.1, decimals: 1)
            HStack(spacing: 4) {
                FieldLabel("Orientación")
                IconButton(icon: "rotate.left", help: "Girar a la izquierda (⌘[)") { store.rotate(-1) }
                IconButton(icon: "rotate.right", help: "Girar a la derecha (⌘])") { store.rotate(1) }
                IconButton(icon: "arrow.left.and.right.righttriangle.left.righttriangle.right", help: "Voltear horizontal",
                           active: store.settings.flipH) { store.flip() }
                Spacer()
            }
            HStack(spacing: 6) {
                SmallButton("Enderezar auto") { store.autoStraighten() }
                    .help("Nivela el horizonte o las líneas rectas de la foto")
                SmallButton("Restablecer recorte") { store.resetCrop() }
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }
}

struct RightPanel: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(spacing: 0) {
            HistogramView()
            Rectangle().fill(Theme.separator).frame(height: 1)
            ToolStrip()
            Rectangle().fill(Theme.separator).frame(height: 1)
            switch store.tool {
            case .crop:
                ToolBlock("Recortar y enderezar", icon: "crop", onDone: { store.tool = .none }) { CropPanel() }
                SectionDivider("Ajustes de la foto")
                ScrollView { globalPanels }
            case .mask:
                ToolBlock("Máscaras", icon: "circle.dashed.inset.filled", onDone: { store.tool = .none }) {
                    ScrollView { MaskPanel().padding(.top, 6) }
                }
                .transition(.opacity)
            case .heal:
                ToolBlock("Eliminar", icon: "bandage", onDone: { store.tool = .none }) {
                    ScrollView { HealPanel().padding(.top, 6) }
                }
                .transition(.opacity)
            default:
                ScrollView { globalPanels }.transition(.opacity)
            }
            HStack(spacing: 8) {
                Button("Anterior") { store.pastePrevious() }.help("Aplica los ajustes de la foto anterior (⌥⌘V)")
                Spacer()
                Button("Restablecer") { store.reset() }.help("Vuelve a los valores por defecto (⇧⌘R)")
            }
            .buttonStyle(GhostButtonStyle(compact: true))
            .padding(10)
            .overlay(Rectangle().fill(Theme.separator).frame(height: 1), alignment: .top)
        }
        .animation(.easeInOut(duration: 0.18), value: store.tool)
        .disabled(store.current == nil)
        .background(Theme.panel)
    }

    private var globalPanels: some View {
        VStack(spacing: 0) {
            BasicPanel()
            ToneCurvePanel()
            HSLPanel()
            ColorGradingPanel()
            DetailPanel()
            OpticsPanel()
            GeometryPanel()
            EffectsPanel()
            CalibrationPanel()
        }
    }
}

struct LuminanceRangeBar: View {
    let mask: Mask
    var body: some View {
        Canvas { ctx, size in
            let r = CGRect(origin: .zero, size: size)
            ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .linearGradient(Gradient(colors: [.black, .white]),
                     startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
            let lo = min(mask.lumLow, mask.lumHigh), hi = max(mask.lumLow, mask.lumHigh), f = max(0.5, mask.lumSmooth / 100 * 25)
            var p = Path()
            for i in 0...100 {
                let L = Double(i)
                let w = CMath.smoothstep(lo - f, lo, L) * (1 - CMath.smoothstep(hi, hi + f, L))
                let pt = CGPoint(x: CGFloat(i) / 100 * size.width, y: size.height - CGFloat(w) * (size.height - 2) - 1)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            ctx.stroke(p, with: .color(Color(red: 1, green: 0.3, blue: 0.3)), lineWidth: 1.5)
        }
        .frame(height: 22)
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.separator))
    }
}

struct MaskPanel: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                SubHeader("Crear nueva máscara")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(MaskKind.allCases, id: \.self) { kind in
                        createButton(kind)
                    }
                }
                if store.settings.masks.isEmpty {
                    HintText("Las máscaras aplican ajustes solo a una zona de la foto. Empieza eligiendo un tipo.")
                        .padding(.top, 2)
                } else {
                    SubHeader("En esta foto")
                    VStack(spacing: 2) {
                        ForEach(store.settings.masks) { m in maskRow(m) }
                    }
                }
                if let m = store.selectedMask { options(m) }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
            Rectangle().fill(Theme.separator).frame(height: 1)
            if store.selectedMask != nil { MaskAdjustPanel() }
        }
        .animation(.easeInOut(duration: 0.18), value: store.settings.masks.map(\.id))
        .animation(.easeInOut(duration: 0.18), value: store.selectedMaskID)
    }

    private func createButton(_ kind: MaskKind) -> some View {
        Button {
            if kind.isDetected { store.addDetectedMask(kind) } else { store.addMask(kind) }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: kind.icon).font(.system(size: 15, weight: .light))
                Text(tr(kind.shortLabel)).font(.system(size: 9.5))
            }
            .foregroundColor(Theme.text)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .hoverBackground(radius: 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.separator))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tr(createHelp(kind)))
    }

    private func createHelp(_ kind: MaskKind) -> String {
        switch kind {
        case .subject: return "Detecta automáticamente el sujeto principal"
        case .people: return "Detecta automáticamente a todas las personas"
        case .background: return "Selecciona todo lo que no es el sujeto principal"
        default: return kind.label
        }
    }

    private func maskRow(_ m: Mask) -> some View {
        let selected = m.id == store.selectedMaskID
        return HStack(spacing: 8) {
            Image(systemName: m.kind.icon).font(.system(size: 10)).foregroundColor(selected ? .white : Theme.secondary).frame(width: 14)
            Text(m.name).font(.system(size: 11, weight: selected ? .semibold : .regular)).foregroundColor(selected ? .white : Theme.text).lineLimit(1)
            if m.invert { Text("INV").font(.system(size: 8, weight: .bold)).foregroundColor(Theme.dim) }
            Spacer()
            Button {
                if let i = store.settings.masks.firstIndex(where: { $0.id == m.id }) {
                    store.settings.masks[i].enabled.toggle()
                    store.commit(m.enabled ? "Ocultar máscara" : "Mostrar máscara")
                }
            } label: {
                Image(systemName: m.enabled ? "eye" : "eye.slash").font(.system(size: 10))
                    .foregroundColor(m.enabled ? Theme.secondary : Theme.dim)
                    .frame(width: 20, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Activar / desactivar")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .hoverBackground(radius: 5, active: selected)
        .contentShape(Rectangle())
        .onTapGesture { store.selectedMaskID = m.id }
        .contextMenu {
            Button("Duplicar") { store.duplicateMask(m.id) }
            Button(m.invert ? "Quitar inversión" : "Invertir") {
                store.selectedMaskID = m.id
                store.bindMask(\.invert).wrappedValue.toggle()
                store.commit("Invertir máscara")
            }
            Divider()
            Button("Eliminar") { store.deleteMask(m.id) }
        }
    }

    @ViewBuilder
    private func options(_ m: Mask) -> some View {
        SubHeader(m.kind.label)
        HStack(spacing: 16) {
            Toggle("Invertir", isOn: Binding(get: { m.invert }, set: { store.bindMask(\.invert).wrappedValue = $0; store.commit("Invertir máscara") }))
            Toggle("Superposición (O)", isOn: $store.showMaskOverlay)
        }
        .toggleStyle(MonoCheckbox())
        .padding(.vertical, 2)
        switch m.kind {
        case .radial:
            LRSlider("Desvanecer", store.bindMask(\.feather), 0...100, def: 50)
            LRSlider("Ángulo", store.bindMask(\.angle), -90...90)
            HintText("Arrastra el centro para moverlo y los puntos del borde para cambiar su tamaño. Arrastra fuera para dibujar uno nuevo.")
        case .brush:
            LRSlider("Tamaño", $store.brushSize, 1...100, def: 20)
            LRSlider("Desvanecer", $store.brushFeather, 0...100, def: 50)
            LRSlider("Flujo", $store.brushFlow, 1...100, def: 100)
            HStack {
                Toggle("Borrar (o mantén ⌥)", isOn: $store.brushErase).toggleStyle(MonoCheckbox())
                Spacer()
                SmallButton("Borrar trazos") {
                    store.bindMask(\.strokes).wrappedValue = []
                    store.commit("Borrar trazos")
                }
            }
            HintText("Pinta sobre la foto para añadir zona a la máscara.")
        case .linear:
            HintText("Arrastra sobre la foto para trazar el degradado. El punto central lo mueve; los extremos ajustan la transición.")
        case .subject, .people, .background:
            HStack(alignment: .top) {
                HintText("Si cambias la geometría o el enderezado, vuelve a detectar.")
                Spacer()
                SmallButton("Volver a detectar") { store.addDetectedMask(m.kind, replacing: m.id) }
            }
        case .color:
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(m.rangeColor.count == 3 ? Color(red: m.rangeColor[0], green: m.rangeColor[1], blue: m.rangeColor[2]) : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.3)))
                    .overlay(Image(systemName: "eyedropper").font(.system(size: 10)).foregroundColor(Theme.dim).opacity(m.rangeColor.count == 3 ? 0 : 1))
                    .frame(width: 34, height: 22)
                HintText(m.rangeColor.count == 3 ? "Haz clic en la foto para elegir otro color." : "Haz clic en la foto sobre el color que quieres seleccionar.")
            }
            LRSlider("Ajustar", store.bindMask(\.rangeTolerance), 0...100, def: 30)
        case .luminance:
            LuminanceRangeBar(mask: m).padding(.leading, 92).padding(.trailing, 50)
            LRSlider("Desde", store.bindMask(\.lumLow), 0...100, def: 60)
            LRSlider("Hasta", store.bindMask(\.lumHigh), 0...100, def: 100)
            LRSlider("Suavizado", store.bindMask(\.lumSmooth), 0...100, def: 30)
            HintText("Haz clic en la foto para centrar el rango en ese tono.")
        }
        HStack {
            SmallButton("Duplicar") { store.duplicateMask(m.id) }
            Spacer()
            SmallButton("Eliminar máscara") { store.deleteMask(m.id) }
        }
        .padding(.top, 6)
    }
}

struct HealPanel: View {
    @EnvironmentObject var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SubHeader(store.selectedHealID == nil ? "Nuevas correcciones" : "Corrección seleccionada")
            Segmented(selection: store.healModeBinding, options: [(HealMode.heal, "Corregir"), (HealMode.clone, "Clonar")])
            LRSlider("Tamaño", store.healBinding(\.size, \.healSize, scale: 1000), 1...100, def: 20)
            LRSlider("Desvanecer", store.healBinding(\.feather, \.healFeather), 0...100, def: 50)
            LRSlider("Opacidad", store.healBinding(\.opacity, \.healOpacity), 0...100, def: 100)
            Toggle("Mostrar puntos (H)", isOn: $store.showHealSpots).toggleStyle(MonoCheckbox()).padding(.top, 2)
            HintText("Haz clic sobre una mancha para eliminarla: el origen se elige solo. Arrastra el círculo discontinuo para usar otro origen. ⌫ borra la seleccionada.")
                .padding(.top, 2)
            HStack {
                Text(store.settings.heals.isEmpty ? tr("Sin correcciones") : tr("%@ correcciones", "\(store.settings.heals.count)"))
                    .font(.system(size: 10.5)).foregroundColor(Theme.secondary)
                Spacer()
                if let id = store.selectedHealID { SmallButton("Eliminar") { store.deleteHeal(id) } }
                SmallButton("Borrar todas") { store.clearHeals() }.disabled(store.settings.heals.isEmpty)
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
    }
}

/// Superposición de la herramienta Eliminar: puntos de destino (continuos) y de origen (discontinuos).
struct HealOverlay: View {
    @EnvironmentObject var store: Store
    @Local private var mode: Mode?
    @Local private var start: HealSpot?
    @Local private var hover: CGPoint?

    enum Mode: Equatable { case dest, source, create }

    var body: some View {
        GeometryReader { g in
            let size = g.size
            let s = store.settings
            let preLong = max(size.width / s.cropW, size.height / s.cropH)
            ZStack {
                Canvas { ctx, sz in
                    guard store.showHealSpots else { return }
                    for h in s.heals { draw(ctx, h, selected: h.id == store.selectedHealID, s, sz, preLong) }
                }
                if let h = hover, mode == nil || mode == .create {
                    let r = store.healSize / 1000 * preLong
                    Circle().stroke(Color.white, lineWidth: 1).frame(width: r * 2, height: r * 2).position(h)
                        .shadow(color: .black.opacity(0.6), radius: 1)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let p) = phase { hover = p } else { hover = nil }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in drag(v, size, preLong) }
                    .onEnded { v in
                        if mode == .create {
                            let p = imagePoint(v.location, store.settings, size)
                            store.addHeal(at: p.0, p.1)
                        } else if mode != nil {
                            store.commit("Mover corrección")
                        }
                        mode = nil
                        start = nil
                    }
            )
        }
    }

    private func draw(_ ctx: GraphicsContext, _ h: HealSpot, selected: Bool, _ s: EditSettings, _ size: CGSize, _ preLong: CGFloat) {
        let r = h.size * preLong
        let d = viewPoint(h.x, h.y, s, size), src = viewPoint(h.sx, h.sy, s, size)
        let dest = Path(ellipseIn: CGRect(x: d.x - r, y: d.y - r, width: r * 2, height: r * 2))
        let shadow = GraphicsContext.Shading.color(.black.opacity(0.5))
        if selected {
            let source = Path(ellipseIn: CGRect(x: src.x - r, y: src.y - r, width: r * 2, height: r * 2))
            let dx = d.x - src.x, dy = d.y - src.y, len = max(1, hypot(dx, dy))
            if len > r * 2 {
                let a = CGPoint(x: src.x + dx / len * r, y: src.y + dy / len * r), b = CGPoint(x: d.x - dx / len * r, y: d.y - dy / len * r)
                ctx.stroke(Path { p in p.move(to: a); p.addLine(to: b) }, with: .color(.white.opacity(0.7)), lineWidth: 1)
            }
            ctx.stroke(source, with: shadow, style: StrokeStyle(lineWidth: 3))
            ctx.stroke(source, with: .color(.white), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
            ctx.stroke(dest, with: shadow, lineWidth: 3)
            ctx.stroke(dest, with: .color(.white), lineWidth: 1.6)
        } else {
            ctx.stroke(dest, with: shadow, lineWidth: 2.5)
            ctx.stroke(dest, with: .color(.white.opacity(0.75)), lineWidth: 1)
        }
    }

    private func drag(_ v: DragGesture.Value, _ size: CGSize, _ preLong: CGFloat) {
        let s = store.settings
        hover = v.location
        if mode == nil {
            mode = .create
            let p = v.startLocation
            func inside(_ x: Double, _ y: Double, _ r: CGFloat) -> Bool {
                let c = viewPoint(x, y, s, size)
                return hypot(c.x - p.x, c.y - p.y) <= max(r, 8)
            }
            if store.showHealSpots {
                if let sel = s.heals.first(where: { $0.id == store.selectedHealID }), inside(sel.sx, sel.sy, sel.size * preLong) {
                    mode = .source; start = sel
                } else if let hit = s.heals.last(where: { inside($0.x, $0.y, $0.size * preLong) }) {
                    store.selectedHealID = hit.id
                    mode = .dest; start = hit
                }
            }
        }
        guard let mode, mode != .create, var h = start else { return }
        let p = imagePoint(v.location, s, size), p0 = imagePoint(v.startLocation, s, size)
        if mode == .dest { h.x += p.0 - p0.0; h.y += p.1 - p0.1 } else { h.sx += p.0 - p0.0; h.sy += p.1 - p0.1 }
        store.updateHeal(h)
    }
}

/// Coordenadas normalizadas de la imagen sin recortar → puntos de la vista (que muestra la imagen recortada).
func viewPoint(_ x: Double, _ y: Double, _ s: EditSettings, _ size: CGSize) -> CGPoint {
    CGPoint(x: (x - s.cropX) / s.cropW * size.width, y: (y - s.cropY) / s.cropH * size.height)
}

func imagePoint(_ p: CGPoint, _ s: EditSettings, _ size: CGSize) -> (Double, Double) {
    (s.cropX + p.x / size.width * s.cropW, s.cropY + p.y / size.height * s.cropH)
}



// MARK: - Curvas

func drawCurveBackground(_ ctx: GraphicsContext, _ size: CGSize, histogram: Histogram?) {
    ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.11)))
    if let h = histogram {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: size.height))
        for i in 0..<256 {
            let v = CGFloat(max(h.r[i], h.g[i], h.b[i]))
            p.addLine(to: CGPoint(x: CGFloat(i) / 255 * size.width, y: size.height - v * size.height * 0.9))
        }
        p.addLine(to: CGPoint(x: size.width, y: size.height))
        p.closeSubpath()
        ctx.fill(p, with: .color(Color(white: 0.22)))
    }
    for q in 1..<4 {
        let f = CGFloat(q) / 4
        ctx.stroke(Path { p in
            p.move(to: CGPoint(x: f * size.width, y: 0)); p.addLine(to: CGPoint(x: f * size.width, y: size.height))
            p.move(to: CGPoint(x: 0, y: f * size.height)); p.addLine(to: CGPoint(x: size.width, y: f * size.height))
        }, with: .color(.white.opacity(0.08)))
    }
    ctx.stroke(Path { p in p.move(to: CGPoint(x: 0, y: size.height)); p.addLine(to: CGPoint(x: size.width, y: 0)) },
               with: .color(.white.opacity(0.15)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
}

struct CurveEditor: View {
    @Binding var points: [CurvePoint]
    var color: Color
    var histogram: Histogram?
    var onCommit: () -> Void
    @Local private var dragIndex: Int?

    var body: some View {
        GeometryReader { g in
            let size = g.size
            Canvas { ctx, sz in
                drawCurveBackground(ctx, sz, histogram: histogram)
                let table = Spline.table(points, n: 160)
                var p = Path()
                for (i, y) in table.enumerated() {
                    let pt = CGPoint(x: CGFloat(i) / 159 * sz.width, y: (1 - CGFloat(y)) * sz.height)
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                ctx.stroke(p, with: .color(color), lineWidth: 1.6)
                for pt in points {
                    let c = CGPoint(x: pt.x * sz.width, y: (1 - pt.y) * sz.height)
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(.white))
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(.black.opacity(0.6)))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in drag(v, size) }
                    .onEnded { _ in dragIndex = nil; onCommit() }
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .help("Clic para añadir un punto · arrastra fuera del gráfico para eliminarlo")
    }

    private func drag(_ v: DragGesture.Value, _ size: CGSize) {
        let nx = Double(v.location.x / size.width), ny = Double(1 - v.location.y / size.height)
        if dragIndex == nil {
            let sx = Double(v.startLocation.x / size.width), sy = Double(1 - v.startLocation.y / size.height)
            func dist(_ p: CurvePoint) -> Double { hypot(p.x - sx, p.y - sy) }
            if let i = points.indices.min(by: { dist(points[$0]) < dist(points[$1]) }), dist(points[i]) < 0.06 {
                dragIndex = i
            } else {
                var pts = points
                let np = CurvePoint(x: CMath.clamp(sx), y: CMath.clamp(sy))
                pts.append(np)
                pts.sort { $0.x < $1.x }
                dragIndex = pts.firstIndex(of: np)
                points = pts
            }
        }
        guard let i = dragIndex, i >= 0, i < points.count else { return }
        var pts = points
        let isEnd = i == 0 || i == pts.count - 1
        if !isEnd && (ny < -0.15 || ny > 1.15 || nx < -0.1 || nx > 1.1) {
            pts.remove(at: i)
            points = pts
            dragIndex = -1
            return
        }
        let lo = i > 0 ? pts[i - 1].x + 0.01 : 0
        let hi = i < pts.count - 1 ? pts[i + 1].x - 0.01 : 1
        pts[i] = CurvePoint(x: min(max(nx, lo), hi), y: CMath.clamp(ny))
        points = pts
    }
}

struct ParametricCurveView: View {
    let settings: EditSettings
    var histogram: Histogram?
    var body: some View {
        Canvas { ctx, sz in
            drawCurveBackground(ctx, sz, histogram: histogram)
            for (i, x) in [0.25, 0.5, 0.75].enumerated() {
                _ = i
                ctx.stroke(Path { p in p.move(to: CGPoint(x: x * sz.width, y: sz.height - 6)); p.addLine(to: CGPoint(x: x * sz.width, y: sz.height)) },
                           with: .color(.white.opacity(0.4)))
            }
            var p = Path()
            for i in 0...160 {
                let x = Double(i) / 160
                let pt = CGPoint(x: x * sz.width, y: (1 - CMath.clamp(Tone.parametric(x, settings))) * sz.height)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            ctx.stroke(p, with: .color(Color(white: 0.9)), lineWidth: 1.6)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - Rueda de color

struct ColorWheel: View {
    @Binding var hue: Double
    @Binding var sat: Double
    let size: CGFloat
    var onCommit: () -> Void

    var body: some View {
        let ang = hue * .pi / 180
        let r = sat / 100 * Double(size) / 2
        ZStack {
            Circle().fill(AngularGradient(
                colors: stride(from: 0.0, through: 360.0, by: 30.0).map { Color(hue: $0 / 360, saturation: 0.75, brightness: 0.85) },
                center: .center))
            Circle().fill(RadialGradient(colors: [Color(white: 0.5), Color(white: 0.5).opacity(0)], center: .center, startRadius: 0, endRadius: size / 2))
            Circle().stroke(Color.black.opacity(0.5), lineWidth: 1)
            Path { p in
                p.move(to: CGPoint(x: size / 2 - 4, y: size / 2)); p.addLine(to: CGPoint(x: size / 2 + 4, y: size / 2))
                p.move(to: CGPoint(x: size / 2, y: size / 2 - 4)); p.addLine(to: CGPoint(x: size / 2, y: size / 2 + 4))
            }.stroke(Color.black.opacity(0.4))
            Circle()
                .fill(Color(hue: hue / 360, saturation: sat / 100, brightness: 1))
                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                .frame(width: 11, height: 11)
                .shadow(radius: 1)
                .offset(x: cos(ang) * r, y: sin(ang) * r)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let dx = Double(v.location.x - size / 2), dy = Double(v.location.y - size / 2)
                    var a = atan2(dy, dx) * 180 / .pi
                    if a < 0 { a += 360 }
                    let fine = NSEvent.modifierFlags.contains(.shift)
                    hue = a.rounded()
                    sat = min(100, (hypot(dx, dy) / Double(size / 2) * 100 * (fine ? 0.25 : 1)).rounded())
                }
                .onEnded { _ in onCommit() }
        )
    }
}

// MARK: - Paneles de la derecha



struct BasicPanel: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let s = store.settings
        let raw = store.current?.isRAW ?? false
        let shot = store.current?.asShot
        PanelSection("Básico", group: .basic) {
            HStack {
                FieldLabel("Tratamiento")
                Segmented(selection: Binding(get: { store.settings.profile == .mono }, set: { mono in
                    store.settings.profile = mono ? .mono : .color
                    store.commit(mono ? "Blanco y negro" : "Color")
                }), options: [(false, "Color"), (true, "Blanco y negro")])
            }
            HStack {
                FieldLabel("Perfil")
                Picker("", selection: Binding(get: { store.settings.profile }, set: {
                    store.settings.profile = $0
                    store.commit(tr("Perfil %@", tr($0.rawValue)))
                })) {
                    ForEach(Profile.allCases) { Text(tr($0.rawValue)).tag($0) }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 130)
                Spacer()
            }
            HStack {
                FieldLabel("HDR")
                Toggle("Edición HDR", isOn: store.toggle(\.hdr, "HDR")).toggleStyle(MonoCheckbox())
                Spacer()
            }
            if s.hdr {
                LRSlider("Rango HDR", store.bind(\.hdrHeadroom), 1...4, def: 2, step: 0.1, decimals: 1, track: Tracks.gray)
                HintText((NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1
                    ? tr("Las luces pueden superar el blanco hasta %@ pasos. Exporta en HEIC para conservar el HDR; en JPEG, TIFF o PNG se comprimen las luces.", formatValue(s.hdrHeadroom, 1, false))
                    : "Esta pantalla no muestra HDR: verás las luces recortadas, pero el HEIC exportado sí las conserva.")
            }
            HStack {
                FieldLabel("Balance")
                Menu {
                    Button("Como se tomó") { store.asShotWhiteBalance() }
                    Button("Automático") { store.autoWhiteBalance() }
                    if raw {
                        Divider()
                        ForEach(wbPresets, id: \.name) { p in Button(tr(p.name)) { store.applyWB(p) } }
                    }
                } label: {
                    Text(s.temp == 0 && s.tint == 0 ? "Como se tomó" : "Personalizado").font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .fixedSize()
                Spacer()
                IconButton(icon: "eyedropper", help: "Selector de balance de blancos (W): haz clic en algo neutro",
                           active: store.tool == .whiteBalance, size: 12) { store.toggleTool(.whiteBalance) }
            }
            LRSlider("Temp.", store.bind(\.temp), track: Tracks.temp,
                     display: raw && shot != nil ? "\(Int((shot!.temp * pow(2, s.temp / 60) / 50).rounded() * 50))" : nil)
            LRSlider("Matiz", store.bind(\.tint), track: Tracks.tint,
                     display: raw && shot != nil ? formatValue((shot!.tint + s.tint * 1.5).rounded(), 0, true) : nil)

            SubHeader("Tono (básico)", trailing: AnyView(SmallButton("Auto") { store.autoTone() }), reset: .tone)
            LRSlider("Exposición", store.bind(\.exposure), -5...5, step: 0.01, decimals: 2, track: Tracks.gray)
            LRSlider("Contraste", store.bind(\.contrast), track: Tracks.gray)
            LRSlider("Iluminaciones", store.bind(\.highlights), track: Tracks.gray)
            LRSlider("Sombras", store.bind(\.shadows), track: Tracks.gray)
            LRSlider("Blancos", store.bind(\.whites), track: Tracks.gray)
            LRSlider("Negros", store.bind(\.blacks), track: Tracks.gray)

            SubHeader("Presencia", reset: .presence)
            LRSlider("Textura", store.bind(\.texture))
            LRSlider("Claridad", store.bind(\.clarity))
            LRSlider("Neblina", store.bind(\.dehaze))
            LRSlider("Intensidad", store.bind(\.vibrance), track: Tracks.color)
            LRSlider("Saturación", store.bind(\.saturation), track: Tracks.color)
        }
    }
}

struct ToneCurvePanel: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var pv: PreviewModel
    @AppStorage("curveChannel") private var channel = 0

    var body: some View {
        PanelSection("Curva de tonos", group: .curve) {
            Segmented(selection: $channel, options: [(0, "Param."), (1, "RGB"), (2, "R"), (3, "G"), (4, "B")])
            if channel == 0 {
                ParametricCurveView(settings: store.settings, histogram: pv.histogram).padding(.horizontal, 20)
                SubHeader("Región")
                LRSlider("Iluminaciones", store.bind(\.pcHighlights))
                LRSlider("Claros", store.bind(\.pcLights))
                LRSlider("Oscuros", store.bind(\.pcDarks))
                LRSlider("Sombras", store.bind(\.pcShadows))
            } else {
                CurveEditor(points: curveBinding, color: [Color.white, .white, .red, .green, Color(red: 0.4, green: 0.55, blue: 1)][channel],
                            histogram: pv.histogram) { store.commit("Curva de tonos") }
                    .padding(.horizontal, 20)
                HStack {
                    Spacer()
                    SmallButton("Restablecer canal") {
                        curveBinding.wrappedValue = identityCurve
                        store.commit("Restablecer curva")
                    }
                }
            }
        }
    }

    private var curveBinding: Binding<[CurvePoint]> {
        switch channel {
        case 2: return store.bind(\.curveR)
        case 3: return store.bind(\.curveG)
        case 4: return store.bind(\.curveB)
        default: return store.bind(\.curveRGB)
        }
    }
}

struct HSLPanel: View {
    @EnvironmentObject var store: Store
    @AppStorage("hslMode") private var mode = 0
    @AppStorage("hslPointTab") private var pointTab = false

    var body: some View {
        let mono = store.settings.profile == .mono
        PanelSection(mono ? "Mezcla B/N" : "Mezcla de colores", group: .color) {
            if mono {
                ForEach(0..<8, id: \.self) { i in
                    LRSlider(hslNames[i], store.bindIndex(\.bwMix, i), track: [Color(white: 0.15), bandColor(i)])
                }
            } else {
                Segmented(selection: $pointTab, options: [(false, "Mezcla"), (true, "Punto de color")])
                if pointTab {
                    PointColorEditor()
                } else {
                    Segmented(selection: $mode, options: [(0, "Tono"), (1, "Saturación"), (2, "Luminancia"), (3, "Todo")])
                    if mode == 0 || mode == 3 { group("Tono", \.hslHue, hueTrack) }
                    if mode == 1 || mode == 3 { group("Saturación", \.hslSat) { [Color(white: 0.5), bandColor($0)] } }
                    if mode == 2 || mode == 3 { group("Luminancia", \.hslLum) { [Color(white: 0.08), bandColor($0), Color(white: 0.95)] } }
                }
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ kp: WritableKeyPath<EditSettings, [Double]>, _ track: @escaping (Int) -> [Color]) -> some View {
        if mode == 3 { SubHeader(title) }
        ForEach(0..<8, id: \.self) { i in
            LRSlider(hslNames[i], store.bindIndex(kp, i), track: track(i))
        }
    }

    private func bandColor(_ i: Int) -> Color { Color(hue: CMath.bandHues[i] / 360, saturation: 0.8, brightness: 0.9) }

    private func hueTrack(_ i: Int) -> [Color] {
        let h = CMath.bandHues[i]
        return [Color(hue: ((h - 30 + 360).truncatingRemainder(dividingBy: 360)) / 360, saturation: 0.8, brightness: 0.9),
                bandColor(i),
                Color(hue: ((h + 30).truncatingRemainder(dividingBy: 360)) / 360, saturation: 0.8, brightness: 0.9)]
    }
}

/// Punto de color: muestras elegidas con el cuentagotas, cada una con sus desplazamientos.
struct PointColorEditor: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let pts = store.settings.pointColors
        HStack(spacing: 6) {
            IconButton(icon: "eyedropper", help: "Elegir un color de la foto", active: store.tool == .pointColor, size: 12) {
                store.toggleTool(.pointColor)
            }
            ForEach(pts) { p in
                let on = p.id == store.selectedPointID
                RoundedRectangle(cornerRadius: 4)
                    .fill(swatch(p.color))
                    .frame(width: 22, height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(on ? Color.white : Color.white.opacity(0.2), lineWidth: on ? 2 : 1))
                    .contentShape(Rectangle())
                    .onTapGesture { store.selectedPointID = p.id }
                    .contextMenu { Button("Eliminar") { store.deletePointColor(p.id) } }
            }
            Spacer()
        }
        .padding(.top, 4)
        if let i = store.pointIndex {
            let p = pts[i]
            let t = LUTBuilder.pointTargets([p])[0]
            let res = LUTBuilder.pointColor(p.color[0], p.color[1], p.color[2], [p], [t])
            HStack(spacing: 8) {
                FieldLabel("Color")
                RoundedRectangle(cornerRadius: 3).fill(swatch(p.color)).frame(width: 40, height: 14)
                Image(systemName: "arrow.right").font(.system(size: 9)).foregroundColor(Theme.dim)
                RoundedRectangle(cornerRadius: 3).fill(Color(red: res.0, green: res.1, blue: res.2)).frame(width: 40, height: 14)
                Spacer()
            }
            LRSlider("Tono", store.bindPoint(\.hue), track: [hueColor(t.0 - 40), hueColor(t.0), hueColor(t.0 + 40)])
            LRSlider("Saturación", store.bindPoint(\.sat), track: [Color(white: 0.5), hueColor(t.0)])
            LRSlider("Luminancia", store.bindPoint(\.lum), track: [Color(white: 0.08), hueColor(t.0), Color(white: 0.95)])
            LRSlider("Variación", store.bindPoint(\.variance))
            LRSlider("Rango", store.bindPoint(\.range), 0...100, def: 50)
            HStack {
                Toggle("Visualizar rango", isOn: $store.showPointRange).toggleStyle(MonoCheckbox())
                Spacer()
                SmallButton("Eliminar") { store.deletePointColor(p.id) }
            }
            .padding(.top, 2)
        } else {
            HintText(pts.isEmpty
                ? "Pulsa el cuentagotas y haz clic en la foto para ajustar solo ese color (hasta 8)."
                : "Selecciona una muestra para ajustarla.")
        }
    }

    private func swatch(_ c: [Double]) -> Color { c.count == 3 ? Color(red: c[0], green: c[1], blue: c[2]) : .gray }

    private func hueColor(_ h: Double) -> Color {
        Color(hue: ((h.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360) / 360, saturation: 0.8, brightness: 0.9)
    }
}

struct ColorGradingPanel: View {
    @EnvironmentObject var store: Store
    @AppStorage("gradeMode") private var mode = 0
    private static let paths: [WritableKeyPath<EditSettings, GradeWheel>] = [\.gradeShadows, \.gradeMidtones, \.gradeHighlights, \.gradeGlobal]
    private static let names = ["Sombras", "Medios tonos", "Iluminaciones", "Global"]

    var body: some View {
        PanelSection("Gradación de color", group: .grading) {
            Segmented(selection: $mode, options: [(0, "3 vías"), (1, "Sombras"), (2, "Medios"), (3, "Ilum."), (4, "Global")])
            if mode == 0 {
                VStack(spacing: 8) {
                    wheelBlock(1, size: 104)
                    HStack(spacing: 20) {
                        wheelBlock(0, size: 104)
                        wheelBlock(2, size: 104)
                    }
                }
                .frame(maxWidth: .infinity)
            } else {
                let kp = Self.paths[mode - 1]
                ColorWheel(hue: store.bind(kp.appending(path: \.hue)), sat: store.bind(kp.appending(path: \.sat)), size: 170) {
                    store.commit(tr("Gradación: %@", tr(Self.names[mode - 1])))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                LRSlider("Tono", store.bind(kp.appending(path: \.hue)), 0...360, track: stride(from: 0.0, through: 360, by: 60).map { Color(hue: $0 / 360, saturation: 0.8, brightness: 0.9) })
                LRSlider("Saturación", store.bind(kp.appending(path: \.sat)), 0...100)
                LRSlider("Luminancia", store.bind(kp.appending(path: \.lum)), track: Tracks.gray)
            }
            LRSlider("Fusión", store.bind(\.gradeBlending), 0...100, def: 50)
            LRSlider("Equilibrio", store.bind(\.gradeBalance))
        }
    }

    private func wheelBlock(_ i: Int, size: CGFloat) -> some View {
        let kp = Self.paths[i]
        return VStack(spacing: 4) {
            Text(tr(Self.names[i])).font(.system(size: 10)).foregroundColor(Theme.dim)
            ColorWheel(hue: store.bind(kp.appending(path: \.hue)), sat: store.bind(kp.appending(path: \.sat)), size: size) {
                store.commit(tr("Gradación: %@", tr(Self.names[i])))
            }
            SliderTrack(value: store.bind(kp.appending(path: \.lum)), range: -100...100, track: Tracks.gray) {
                store.commit(tr("Luminancia %@", tr(Self.names[i])))
            }
            .frame(width: size, height: 14)
        }
    }
}

struct DetailPanel: View {
    @EnvironmentObject var store: Store
    var body: some View {
        PanelSection("Detalle", group: .detail) {
            SubHeader("Enfoque", reset: .sharpening)
            LRSlider("Cantidad", store.bind(\.sharpAmount), 0...150)
            LRSlider("Radio", store.bind(\.sharpRadius), 0.5...3, def: 1, step: 0.1, decimals: 1)
            LRSlider("Detalle", store.bind(\.sharpDetail), 0...100, def: 25)
            LRSlider("Máscara", store.bind(\.sharpMasking), 0...100)
            SubHeader("Reducción de ruido", reset: .noise)
            LRSlider("Luminancia", store.bind(\.nrLuminance), 0...100)
            LRSlider("Detalle", store.bind(\.nrDetail), 0...100, def: 50)
            LRSlider("Contraste", store.bind(\.nrContrast), 0...100)
            LRSlider("Color", store.bind(\.nrColor), 0...100, def: store.current?.isRAW == true ? 25 : 0)
            LRSlider("Detalle", store.bind(\.nrColorDetail), 0...100, def: 50)
            LRSlider("Suavidad", store.bind(\.nrColorSmooth), 0...100, def: 50)
        }
    }
}

struct OpticsPanel: View {
    @EnvironmentObject var store: Store
    var body: some View {
        let raw = store.current?.isRAW ?? false
        PanelSection("Óptica", group: .optics) {
            Toggle("Eliminar aberración cromática", isOn: store.toggle(\.removeCA, "Eliminar aberración cromática"))
                .toggleStyle(MonoCheckbox())
            Toggle("Usar correcciones de perfil (RAW)", isOn: store.toggle(\.lensProfile, "Correcciones de perfil"))
                .toggleStyle(MonoCheckbox()).opacity(raw ? 1 : 0.4)
                .disabled(!raw)
            SubHeader("Manual")
            LRSlider("Distorsión", store.bind(\.distortion))
            LRSlider("Viñeta", store.bind(\.lensVignette))
            LRSlider("Punto medio", store.bind(\.lensVignetteMid), 0...100, def: 50)
            SubHeader("Desflecar")
            LRSlider("Púrpura", store.bind(\.defringePurple), 0...20, track: [Color(white: 0.3), .purple])
            LRSlider("Verde", store.bind(\.defringeGreen), 0...20, track: [Color(white: 0.3), .green])
        }
    }
}

struct GeometryPanel: View {
    @EnvironmentObject var store: Store
    var body: some View {
        PanelSection("Geometría", open: false, group: .geometry) {
            HStack(spacing: 6) {
                SmallButton("Auto", prominent: true) { store.autoGeometry() }
                    .help("Nivela la foto y corrige las verticales que convergen (edificios)")
                SmallButton("Nivelar") { store.autoStraighten() }
                    .help("Solo endereza el horizonte o las líneas rectas")
                Spacer()
            }
            .padding(.vertical, 2)
            LRSlider("Vertical", store.bind(\.vertical))
            LRSlider("Horizontal", store.bind(\.horizontal))
            LRSlider("Girar", store.bind(\.rotate), -10...10, step: 0.1, decimals: 1)
            LRSlider("Aspecto", store.bind(\.aspect))
            LRSlider("Escala", store.bind(\.scale), 50...150, def: 100)
            LRSlider("Desplaz. X", store.bind(\.offsetX))
            LRSlider("Desplaz. Y", store.bind(\.offsetY))
            HStack {
                Spacer()
                SmallButton("Restablecer geometría") {
                    var s = store.settings
                    s.vertical = 0; s.horizontal = 0; s.rotate = 0; s.aspect = 0; s.scale = 100; s.offsetX = 0; s.offsetY = 0
                    store.settings = s
                    store.commit("Restablecer geometría")
                }
            }
        }
    }
}

struct EffectsPanel: View {
    @EnvironmentObject var store: Store
    var body: some View {
        PanelSection("Efectos", group: .effects) {
            SubHeader("Viñeta tras recorte", reset: .vignette)
            LRSlider("Cantidad", store.bind(\.vigAmount), track: Tracks.gray)
            LRSlider("Punto medio", store.bind(\.vigMidpoint), 0...100, def: 50)
            LRSlider("Redondez", store.bind(\.vigRoundness))
            LRSlider("Desvanecer", store.bind(\.vigFeather), 0...100, def: 50)
            LRSlider("Iluminaciones", store.bind(\.vigHighlights), 0...100)
            SubHeader("Granulado", reset: .grain)
            LRSlider("Cantidad", store.bind(\.grainAmount), 0...100)
            LRSlider("Tamaño", store.bind(\.grainSize), 0...100, def: 25)
            LRSlider("Aspereza", store.bind(\.grainRoughness), 0...100, def: 50)
        }
    }
}

struct CalibrationPanel: View {
    @EnvironmentObject var store: Store
    var body: some View {
        PanelSection("Calibración", open: false, group: .calibration) {
            SubHeader("Sombras")
            LRSlider("Matiz", store.bind(\.calShadowTint), track: Tracks.shadowTint)
            SubHeader("Primario rojo")
            LRSlider("Tono", store.bind(\.calRedHue), track: [Color(red: 0.9, green: 0.1, blue: 0.5), .red, .orange])
            LRSlider("Saturación", store.bind(\.calRedSat), track: [Color(white: 0.5), .red])
            SubHeader("Primario verde")
            LRSlider("Tono", store.bind(\.calGreenHue), track: [.yellow, .green, .cyan])
            LRSlider("Saturación", store.bind(\.calGreenSat), track: [Color(white: 0.5), .green])
            SubHeader("Primario azul")
            LRSlider("Tono", store.bind(\.calBlueHue), track: [.cyan, .blue, .purple])
            LRSlider("Saturación", store.bind(\.calBlueSat), track: [Color(white: 0.5), .blue])
        }
    }
}


// MARK: - Panel de máscaras


struct MaskAdjustPanel: View {
    @EnvironmentObject var store: Store

    var body: some View {
        PanelSection("Ajustes de máscara") {
            LRSlider("Temp.", store.bindMask(\.adjust.temp), track: Tracks.temp)
            LRSlider("Matiz", store.bindMask(\.adjust.tint), track: Tracks.tint)
            SubHeader("Luz")
            LRSlider("Exposición", store.bindMask(\.adjust.exposure), -4...4, step: 0.01, decimals: 2, track: Tracks.gray)
            LRSlider("Contraste", store.bindMask(\.adjust.contrast), track: Tracks.gray)
            LRSlider("Iluminaciones", store.bindMask(\.adjust.highlights), track: Tracks.gray)
            LRSlider("Sombras", store.bindMask(\.adjust.shadows), track: Tracks.gray)
            LRSlider("Blancos", store.bindMask(\.adjust.whites), track: Tracks.gray)
            LRSlider("Negros", store.bindMask(\.adjust.blacks), track: Tracks.gray)
            SubHeader("Presencia")
            LRSlider("Textura", store.bindMask(\.adjust.texture))
            LRSlider("Claridad", store.bindMask(\.adjust.clarity))
            LRSlider("Neblina", store.bindMask(\.adjust.dehaze))
            LRSlider("Saturación", store.bindMask(\.adjust.saturation), track: Tracks.color)
            SubHeader("Detalle")
            LRSlider("Nitidez", store.bindMask(\.adjust.sharpness))
            LRSlider("Ruido", store.bindMask(\.adjust.noise), 0...100)
            SubHeader("Color")
            HStack(alignment: .center, spacing: 12) {
                ColorWheel(hue: store.bindMask(\.adjust.colorHue), sat: store.bindMask(\.adjust.colorSat), size: 80) {
                    store.commit("Color de máscara")
                }
                VStack(spacing: 5) {
                    LRSlider("Tono", store.bindMask(\.adjust.colorHue), 0...360,
                             track: stride(from: 0.0, through: 360, by: 60).map { Color(hue: $0 / 360, saturation: 0.8, brightness: 0.9) })
                    LRSlider("Intensidad", store.bindMask(\.adjust.colorSat), 0...100)
                }
            }
            HStack {
                Spacer()
                SmallButton("Restablecer ajustes") {
                    store.bindMask(\.adjust).wrappedValue = MaskAdjust()
                    store.commit("Restablecer ajustes de máscara")
                }
            }
        }
    }
}

/// Superposición sobre la foto para editar la máscara seleccionada (puntos de control y pincel).
struct MaskOverlay: View {
    @EnvironmentObject var store: Store
    @Local private var mode: Mode?
    @Local private var start: Mask?
    @Local private var hover: CGPoint?

    enum Mode: Equatable { case linMove, linP0, linP1, linNew, radMove, radRX, radRY, radNew, paint, pick }

    var body: some View {
        GeometryReader { g in
            let size = g.size
            let s = store.settings
            let m = store.selectedMask
            let brushRadius = store.brushSize / 400 * max(size.width / s.cropW, size.height / s.cropH)
            ZStack {
                Canvas { ctx, sz in
                    guard let m else { return }
                    draw(ctx, m, s, sz)
                }
                if m?.kind == .brush, let h = hover {
                    Circle().stroke(Color.white, lineWidth: 1).frame(width: brushRadius * 2, height: brushRadius * 2).position(h)
                    Circle().stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        .frame(width: brushRadius * 2 * (1 - store.brushFeather / 100), height: brushRadius * 2 * (1 - store.brushFeather / 100))
                        .position(h)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let p) = phase {
                    hover = p
                    if m?.kind == .color || m?.kind == .luminance { NSCursor.crosshair.set() }
                } else {
                    hover = nil
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in drag(v, size) }
                    .onEnded { _ in
                        if let mode, mode != .pick { store.commit(mode == .paint ? "Pincel" : "Editar máscara") }
                        mode = nil
                        start = nil
                    }
            )
        }
    }

    // Conversión vista ↔ coordenadas normalizadas de la imagen sin recortar
    private func toView(_ x: Double, _ y: Double, _ s: EditSettings, _ size: CGSize) -> CGPoint {
        CGPoint(x: (x - s.cropX) / s.cropW * size.width, y: (y - s.cropY) / s.cropH * size.height)
    }

    private func fromView(_ p: CGPoint, _ s: EditSettings, _ size: CGSize) -> (Double, Double) {
        (s.cropX + p.x / size.width * s.cropW, s.cropY + p.y / size.height * s.cropH)
    }

    private struct RadialGeom { var c: CGPoint; var rx: CGFloat; var ry: CGFloat; var ux: CGPoint; var uy: CGPoint }

    private func radial(_ m: Mask, _ s: EditSettings, _ size: CGSize) -> RadialGeom {
        let a = m.angle * .pi / 180
        return RadialGeom(c: toView(m.cx, m.cy, s, size), rx: m.rx / s.cropW * size.width, ry: m.ry / s.cropH * size.height,
                          ux: CGPoint(x: cos(a), y: sin(a)), uy: CGPoint(x: -sin(a), y: cos(a)))
    }

    private func handle(_ ctx: GraphicsContext, _ p: CGPoint, filled: Bool = false) {
        let r = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
        ctx.fill(Path(ellipseIn: r), with: .color(filled ? Color(white: 0.1) : .white))
        ctx.stroke(Path(ellipseIn: r), with: .color(filled ? .white : .black.opacity(0.6)), lineWidth: filled ? 1.5 : 1)
    }

    private func draw(_ ctx: GraphicsContext, _ m: Mask, _ s: EditSettings, _ size: CGSize) {
        switch m.kind {
        case .linear:
            let p0 = toView(m.x0, m.y0, s, size), p1 = toView(m.x1, m.y1, s, size)
            var dx = p1.x - p0.x, dy = p1.y - p0.y
            let len = max(0.001, hypot(dx, dy))
            if len < 1 { dx = 0; dy = 1 } else { dx /= len; dy /= len }
            let n = CGPoint(x: -dy, y: dx), L = (size.width + size.height) * 2
            func line(_ c: CGPoint) -> Path {
                Path { p in p.move(to: CGPoint(x: c.x - n.x * L, y: c.y - n.y * L)); p.addLine(to: CGPoint(x: c.x + n.x * L, y: c.y + n.y * L)) }
            }
            let mid = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
            ctx.stroke(line(p0), with: .color(.white), lineWidth: 1.2)
            ctx.stroke(line(p1), with: .color(.white.opacity(0.7)), lineWidth: 1)
            ctx.stroke(line(mid), with: .color(.white.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            handle(ctx, p0); handle(ctx, p1); handle(ctx, mid, filled: true)
        case .radial:
            let r = radial(m, s, size)
            let t = CGAffineTransform(rotationAngle: m.angle * .pi / 180).concatenating(CGAffineTransform(translationX: r.c.x, y: r.c.y))
            ctx.stroke(Path(ellipseIn: CGRect(x: -r.rx, y: -r.ry, width: r.rx * 2, height: r.ry * 2)).applying(t), with: .color(.white), lineWidth: 1.2)
            let k = 1 - CMath.clamp(m.feather / 100) * 0.95
            ctx.stroke(Path(ellipseIn: CGRect(x: -r.rx * k, y: -r.ry * k, width: r.rx * 2 * k, height: r.ry * 2 * k)).applying(t),
                       with: .color(.white.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            for (u, d) in [(r.ux, r.rx), (r.uy, r.ry)] {
                handle(ctx, CGPoint(x: r.c.x + u.x * d, y: r.c.y + u.y * d))
                handle(ctx, CGPoint(x: r.c.x - u.x * d, y: r.c.y - u.y * d))
            }
            handle(ctx, r.c, filled: true)
        case .brush, .subject, .people, .background, .color, .luminance:
            break
        }
    }

    private func hitTest(_ m: Mask, _ p: CGPoint, _ s: EditSettings, _ size: CGSize) -> Mode? {
        func near(_ a: CGPoint, _ d: CGFloat = 12) -> Bool { hypot(a.x - p.x, a.y - p.y) < d }
        switch m.kind {
        case .brush: return .paint
        case .subject, .people, .background: return nil
        case .color, .luminance: return .pick
        case .linear:
            let p0 = toView(m.x0, m.y0, s, size), p1 = toView(m.x1, m.y1, s, size)
            if near(CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)) { return .linMove }
            if near(p0) { return .linP0 }
            if near(p1) { return .linP1 }
            return .linNew
        case .radial:
            let r = radial(m, s, size)
            if near(r.c) { return .radMove }
            for sign in [1.0, -1.0] {
                if near(CGPoint(x: r.c.x + sign * r.ux.x * r.rx, y: r.c.y + sign * r.ux.y * r.rx))
                    || near(CGPoint(x: r.c.x + sign * r.uy.x * r.ry, y: r.c.y + sign * r.uy.y * r.ry)) {
                    let onX = near(CGPoint(x: r.c.x + sign * r.ux.x * r.rx, y: r.c.y + sign * r.ux.y * r.rx))
                    return onX ? .radRX : .radRY
                }
            }
            let v = CGPoint(x: p.x - r.c.x, y: p.y - r.c.y)
            let lx = (v.x * r.ux.x + v.y * r.ux.y) / max(1, r.rx), ly = (v.x * r.uy.x + v.y * r.uy.y) / max(1, r.ry)
            return lx * lx + ly * ly <= 1 ? .radMove : .radNew
        }
    }

    private func drag(_ v: DragGesture.Value, _ size: CGSize) {
        guard let m = store.selectedMask else { return }
        let s = store.settings
        hover = v.location
        if mode == nil {
            start = m
            mode = hitTest(m, v.startLocation, s, size)
            if mode == .paint {
                let p = fromView(v.startLocation, s, size)
                store.brushBegin(p.0, p.1, erase: NSEvent.modifierFlags.contains(.option))
            } else if mode == .pick {
                store.pickRange(at: CGPoint(x: v.startLocation.x / size.width, y: v.startLocation.y / size.height))
            }
        }
        guard let mode, var sm = start else { return }
        let p = fromView(v.location, s, size), p0 = fromView(v.startLocation, s, size)
        let dx = p.0 - p0.0, dy = p.1 - p0.1
        switch mode {
        case .paint: store.brushMove(p.0, p.1); return
        case .pick: return
        case .linMove: sm.x0 += dx; sm.y0 += dy; sm.x1 += dx; sm.y1 += dy
        case .linP0: sm.x0 = p.0; sm.y0 = p.1
        case .linP1: sm.x1 = p.0; sm.y1 = p.1
        case .linNew: sm.x0 = p0.0; sm.y0 = p0.1; sm.x1 = p.0; sm.y1 = p.1
        case .radMove: sm.cx += dx; sm.cy += dy
        case .radRX, .radRY:
            let r = radial(sm, s, size)
            let vec = CGPoint(x: v.location.x - r.c.x, y: v.location.y - r.c.y)
            if mode == .radRX {
                sm.rx = max(0.005, Double(abs(vec.x * r.ux.x + vec.y * r.ux.y) / size.width) * s.cropW)
            } else {
                sm.ry = max(0.005, Double(abs(vec.x * r.uy.x + vec.y * r.uy.y) / size.height) * s.cropH)
            }
        case .radNew:
            let d = max(4, hypot(v.location.x - v.startLocation.x, v.location.y - v.startLocation.y))
            sm.cx = p0.0; sm.cy = p0.1; sm.angle = 0
            sm.rx = Double(d / size.width) * s.cropW
            sm.ry = Double(d / size.height) * s.cropH
        }
        store.updateSelectedMask(sm)
    }
}

// MARK: - Panel izquierdo


// MARK: - Lienzo central

struct CropOverlay: View {
    @Binding var rect: CGRect
    var ratio: Double?
    var onCommit: () -> Void
    @Local private var mode: Mode?
    @Local private var startRect = CGRect.zero

    enum Mode: Equatable { case move, corner(Int), edge(Int) }

    var body: some View {
        GeometryReader { g in
            let size = g.size
            let r = CGRect(x: rect.minX * size.width, y: rect.minY * size.height, width: rect.width * size.width, height: rect.height * size.height)
            ZStack {
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: size))
                    p.addRect(r)
                }
                .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                Path { p in
                    for f in [1.0 / 3.0, 2.0 / 3.0] {
                        p.move(to: CGPoint(x: r.minX + r.width * f, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + r.width * f, y: r.maxY))
                        p.move(to: CGPoint(x: r.minX, y: r.minY + r.height * f)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * f))
                    }
                }
                .stroke(Color.white.opacity(0.45), lineWidth: 0.5)
                Path { p in p.addRect(r) }.stroke(Color.white, lineWidth: 1)
                Path { p in
                    let l: CGFloat = 16
                    for c in [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)] {
                        let sx: CGFloat = c.x == r.minX ? 1 : -1, sy: CGFloat = c.y == r.minY ? 1 : -1
                        p.move(to: CGPoint(x: c.x + sx * l, y: c.y)); p.addLine(to: c); p.addLine(to: CGPoint(x: c.x, y: c.y + sy * l))
                    }
                    for m in [CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.midX, y: r.maxY)] {
                        p.move(to: CGPoint(x: m.x - 8, y: m.y)); p.addLine(to: CGPoint(x: m.x + 8, y: m.y))
                    }
                    for m in [CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY)] {
                        p.move(to: CGPoint(x: m.x, y: m.y - 8)); p.addLine(to: CGPoint(x: m.x, y: m.y + 8))
                    }
                }
                .stroke(Color.white, lineWidth: 3)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        if mode == nil { startRect = rect; mode = hitTest(v.startLocation, r) }
                        guard let mode else { return }
                        let dx = v.translation.width / size.width, dy = v.translation.height / size.height
                        rect = update(mode, startRect, dx, dy)
                    }
                    .onEnded { _ in
                        if mode != nil { onCommit() }
                        mode = nil
                    }
            )
        }
    }

    private func hitTest(_ p: CGPoint, _ r: CGRect) -> Mode? {
        let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        for (i, c) in corners.enumerated() where hypot(p.x - c.x, p.y - c.y) < 18 { return .corner(i) }
        if ratio == nil {
            if abs(p.y - r.minY) < 10 && p.x > r.minX && p.x < r.maxX { return .edge(0) }
            if abs(p.x - r.maxX) < 10 && p.y > r.minY && p.y < r.maxY { return .edge(1) }
            if abs(p.y - r.maxY) < 10 && p.x > r.minX && p.x < r.maxX { return .edge(2) }
            if abs(p.x - r.minX) < 10 && p.y > r.minY && p.y < r.maxY { return .edge(3) }
        }
        return r.contains(p) ? .move : nil
    }

    private func update(_ mode: Mode, _ s: CGRect, _ dx: CGFloat, _ dy: CGFloat) -> CGRect {
        let minS: CGFloat = 0.03
        switch mode {
        case .move:
            return CGRect(x: min(max(s.minX + dx, 0), 1 - s.width), y: min(max(s.minY + dy, 0), 1 - s.height), width: s.width, height: s.height)
        case .edge(let e):
            var r = s
            switch e {
            case 0: let y = min(max(s.minY + dy, 0), s.maxY - minS); r = CGRect(x: s.minX, y: y, width: s.width, height: s.maxY - y)
            case 1: r.size.width = min(max(s.width + dx, minS), 1 - s.minX)
            case 2: r.size.height = min(max(s.height + dy, minS), 1 - s.minY)
            default: let x = min(max(s.minX + dx, 0), s.maxX - minS); r = CGRect(x: x, y: s.minY, width: s.maxX - x, height: s.height)
            }
            return r
        case .corner(let c):
            let anchors = [CGPoint(x: s.maxX, y: s.maxY), CGPoint(x: s.minX, y: s.maxY), CGPoint(x: s.minX, y: s.minY), CGPoint(x: s.maxX, y: s.minY)]
            let moving = [CGPoint(x: s.minX, y: s.minY), CGPoint(x: s.maxX, y: s.minY), CGPoint(x: s.maxX, y: s.maxY), CGPoint(x: s.minX, y: s.maxY)]
            let a = anchors[c]
            let sx: CGFloat = (c == 1 || c == 2) ? 1 : -1, sy: CGFloat = (c == 2 || c == 3) ? 1 : -1
            let p = CGPoint(x: min(max(moving[c].x + dx, 0), 1), y: min(max(moving[c].y + dy, 0), 1))
            var w = max(minS, (p.x - a.x) * sx), h = max(minS, (p.y - a.y) * sy)
            let maxW = sx > 0 ? 1 - a.x : a.x, maxH = sy > 0 ? 1 - a.y : a.y
            if let ratio {
                let rr = CGFloat(ratio)
                if w / h > rr { w = h * rr } else { h = w / rr }
                if w > maxW { w = maxW; h = w / rr }
                if h > maxH { h = maxH; w = h * rr }
            } else {
                w = min(w, maxW); h = min(h, maxH)
            }
            return CGRect(x: sx > 0 ? a.x : a.x - w, y: sy > 0 ? a.y : a.y - h, width: w, height: h)
        }
    }
}




// MARK: - Biblioteca, tira de película y barras







struct ExportSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    // Todo se recuerda entre exportaciones
    @AppStorage("export.format") private var format = ExportFormat.jpeg.rawValue
    @AppStorage("export.quality") private var quality = 90.0
    @AppStorage("export.sizing") private var sizing = ExportSizing.original.rawValue
    @AppStorage("export.sizeValue") private var sizeValue = 2048.0
    @AppStorage("export.noEnlarge") private var noEnlarge = true
    @AppStorage("export.ppi") private var ppi = 300
    @AppStorage("export.metadata") private var metadata = ExportMetadata.all.rawValue
    @AppStorage("export.scope") private var scope = Store.ExportScope.selected.rawValue
    @AppStorage("export.sameFolder") private var sameFolder = false
    @AppStorage("export.folder") private var folderPath = ""
    @AppStorage("export.subfolder") private var subfolder = ""
    @AppStorage("export.naming") private var naming = ExportNaming.original.rawValue
    @AppStorage("export.namingText") private var namingText = ""

    var body: some View {
        let fmt = ExportFormat(rawValue: format) ?? .jpeg
        let sz = ExportSizing(rawValue: sizing) ?? .original
        let nm = ExportNaming(rawValue: naming) ?? .original
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Exportar").font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                Spacer()
                Menu("Ajustes rápidos") {
                    Button("Web · JPEG 2048 px, sin ubicación") { apply(.jpeg, 85, .longEdge, 2048, 72, .noLocation) }
                    Button("Redes sociales · JPEG 1080 px de ancho, sin metadatos") { apply(.jpeg, 90, .width, 1080, 72, .none) }
                    Button("Impresión · TIFF 16 bits, tamaño original") { apply(.tiff, 100, .original, 0, 300, .all) }
                    Button("Archivo · HEIC calidad 95") { apply(.heic, 95, .original, 0, 300, .all) }
                }
                .fixedSize()
            }
            Form {
                Section("Fotos") {
                    Picker("Exportar", selection: $scope) {
                        Text("Foto seleccionada").tag(Store.ExportScope.selected.rawValue)
                        Text(tr("Marcadas (%@)", "\(store.exportItems(.marked).count)")).tag(Store.ExportScope.marked.rawValue)
                        Text(tr("Todas (%@)", "\(store.photos.count)")).tag(Store.ExportScope.all.rawValue)
                    }
                }
                Section("Destino") {
                    Picker("Carpeta", selection: $sameFolder) {
                        Text("Carpeta elegida").tag(false)
                        Text("Junto a cada original").tag(true)
                    }
                    if !sameFolder {
                        HStack {
                            Text(folderPath.isEmpty ? tr("Se preguntará al exportar") : folderPath)
                                .font(.system(size: 11)).foregroundColor(folderPath.isEmpty ? Theme.dim : Theme.text)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Elegir…") { chooseFolder() }
                        }
                    }
                    TextField("Subcarpeta (opcional)", text: $subfolder)
                }
                Section("Nombre de archivo") {
                    Picker("Nombre", selection: $naming) {
                        ForEach(ExportNaming.allCases) { Text(tr($0.rawValue)).tag($0.rawValue) }
                    }
                    if nm != .original {
                        TextField(tr(nm == .suffix ? "Sufijo (p. ej. -editada)" : "Nombre base (p. ej. Viaje)"), text: $namingText)
                    }
                    Text(tr("Ejemplo: %@", example(nm, fmt))).font(.system(size: 10.5)).foregroundColor(Theme.dim)
                }
                Section("Formato") {
                    Picker("Formato", selection: $format) {
                        ForEach(ExportFormat.allCases) { Text(tr($0.rawValue)).tag($0.rawValue) }
                    }
                    if fmt.lossy {
                        HStack {
                            Slider(value: $quality, in: 10...100, step: 1) { Text("Calidad") }
                            Text("\(Int(quality))").monospacedDigit().frame(width: 30)
                        }
                    }
                }
                Section("Tamaño de imagen") {
                    Picker("Ajustar", selection: $sizing) {
                        ForEach(ExportSizing.allCases) { Text(tr($0.rawValue)).tag($0.rawValue) }
                    }
                    if sz != .original {
                        HStack {
                            TextField("Valor", value: $sizeValue, format: .number).frame(width: 90)
                            Text(sz.unit).foregroundColor(Theme.secondary)
                            Spacer()
                            Toggle("No ampliar", isOn: $noEnlarge)
                        }
                    }
                    Picker("Resolución", selection: $ppi) {
                        ForEach([72, 150, 240, 300, 360], id: \.self) { Text(tr("%@ ppp", "\($0)")).tag($0) }
                    }
                    if let p = store.current, p.pixelSize.width > 0 {
                        let s = min(noEnlarge ? 1 : .infinity, sz.scale(p.pixelSize.width * store.settings.cropW,
                                                                         p.pixelSize.height * store.settings.cropH, value: sizeValue))
                        Text(tr("Foto actual: %@ × %@ px", "\(Int((p.pixelSize.width * store.settings.cropW * s).rounded()))", "\(Int((p.pixelSize.height * store.settings.cropH * s).rounded()))"))
                            .font(.system(size: 10.5)).foregroundColor(Theme.dim)
                    }
                }
                Section("Metadatos") {
                    Picker("Incluir", selection: $metadata) {
                        ForEach(ExportMetadata.allCases) { Text(tr($0.rawValue)).tag($0.rawValue) }
                    }
                    Text(tr(metadataHint)).font(.system(size: 10.5)).foregroundColor(Theme.dim)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.buttonStyle(GhostButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Exportar") { start() }
                    .buttonStyle(GhostButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500, height: 640)
        .background(Theme.panel)
        .tint(Theme.select)
    }

    private var metadataHint: String {
        switch ExportMetadata(rawValue: metadata) ?? .all {
        case .all: return "Cámara, objetivo, ajustes de toma, fecha, ubicación GPS y copyright."
        case .noLocation: return "Se eliminan las coordenadas GPS y el lugar; se conserva el resto."
        case .none: return "La copia no lleva datos de cámara, fecha, ubicación ni autor."
        }
    }

    private func example(_ nm: ExportNaming, _ fmt: ExportFormat) -> String {
        let orig = store.current.map { $0.url.deletingPathExtension().lastPathComponent } ?? "IMG_0001"
        switch nm {
        case .original: return "\(orig).\(fmt.ext)"
        case .suffix: return "\(orig)\(namingText).\(fmt.ext)"
        case .custom: return "\(namingText.isEmpty ? "Foto" : namingText)-001.\(fmt.ext)"
        }
    }

    private func apply(_ f: ExportFormat, _ q: Double, _ s: ExportSizing, _ v: Double, _ p: Int, _ m: ExportMetadata) {
        format = f.rawValue; quality = q; sizing = s.rawValue; ppi = p; metadata = m.rawValue
        if v > 0 { sizeValue = v }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = tr("Elegir")
        if !folderPath.isEmpty { panel.directoryURL = URL(fileURLWithPath: folderPath) }
        if panel.runModal() == .OK, let url = panel.url { folderPath = url.path }
    }

    private func start() {
        var o = ExportOptions()
        o.format = ExportFormat(rawValue: format) ?? .jpeg
        o.quality = quality / 100
        o.sizing = ExportSizing(rawValue: sizing) ?? .original
        o.sizeValue = max(1, sizeValue)
        o.noEnlarge = noEnlarge
        o.ppi = ppi
        o.metadata = ExportMetadata(rawValue: metadata) ?? .all
        var d = Store.ExportDestination()
        d.sameFolder = sameFolder
        d.folder = folderPath.isEmpty || !FileManager.default.fileExists(atPath: folderPath) ? nil : URL(fileURLWithPath: folderPath)
        d.subfolder = subfolder
        d.naming = ExportNaming(rawValue: naming) ?? .original
        d.text = namingText
        let sc = Store.ExportScope(rawValue: scope) ?? .selected
        dismiss()
        DispatchQueue.main.async { store.export(sc, options: o, destination: d) }
    }
}

// MARK: - Ventana principal


struct LeftPanel: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var pv: PreviewModel
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                PanelSection("Navegador") {
                    ZStack(alignment: .bottomLeading) {
                        RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.06))
                        if let cg = pv.navigatorPreview ?? pv.preview {
                            NavigatorImage(image: cg, interactive: pv.navigatorPreview == nil)
                        }
                        if let label = pv.navigatorLabel {
                            Text(label).font(.system(size: 9.5, weight: .medium)).foregroundColor(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Rectangle().fill(Color.black.opacity(0.7)))
                                .padding(6)
                                .transition(.opacity)
                        }
                    }
                    .frame(height: 140)
                    .animation(.easeOut(duration: 0.15), value: pv.navigatorLabel)
                    HStack(spacing: 2) {
                        zoomChip("Encajar", active: !store.zoomed) { store.zoomed = false }
                        ForEach([0.5, 1.0, 2.0], id: \.self) { l in
                            zoomChip("\(Int(l * 100)) %", active: store.zoomed && abs(store.zoomLevel - l) < 0.01) { store.zoom(to: l) }
                        }
                        Spacer()
                        Text("\(store.zoomPercent) %").font(.system(size: 10).monospacedDigit()).foregroundColor(Theme.dim)
                    }
                }
                PanelSection("Ajustes preestablecidos") {
                    SubHeader("Integrados")
                    VStack(spacing: 1) {
                        ForEach(BuiltinPreset.all) { p in
                            row(p.name) { store.apply(p) }
                                .onHover { h in
                                    store.hoverPreview(h ? p.name : nil, h ? { var s = $0; p.apply(&s); return s } : nil)
                                }
                        }
                    }
                    SubHeader("Del usuario", trailing: AnyView(
                        IconButton(icon: "plus", help: "Guardar los ajustes actuales como preestablecido (⇧⌘N)", size: 10) { store.saveUserPreset() }
                            .frame(height: 16)))
                    if store.userPresets.isEmpty {
                        HintText("Pulsa + para guardar los ajustes actuales.")
                    }
                    VStack(spacing: 1) {
                        ForEach(store.userPresets) { p in
                            row(p.name) { store.apply(p) }
                                .onHover { h in store.hoverPreview(h ? p.name : nil, h ? { $0.withLook(from: p.settings) } : nil) }
                                .contextMenu { Button("Eliminar") { store.deleteUserPreset(p) } }
                        }
                    }
                }
                PanelSection("Historial") {
                    if let h = store.history { HistoryList(state: h).equatable() }
                }
            }
        }
        .disabled(store.current == nil)
        .background(Theme.panel)
    }

    private func zoomChip(_ t: String, active: Bool, action: @escaping () -> Void) -> some View {
        Text(t).font(.system(size: 10, weight: active ? .semibold : .regular).monospacedDigit())
            .foregroundColor(active ? Theme.onSelect : Theme.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Rectangle().fill(active ? Theme.select : Theme.fill))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }

    private func row(_ name: String, action: @escaping () -> Void) -> some View {
        Text(tr(name))
            .font(.system(size: 11))
            .foregroundColor(Theme.text)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .hoverBackground(radius: 4)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }
}

/// Historial de la foto abierta. Equatable: solo se redibuja cuando cambia el historial, no con cada
/// movimiento de un deslizador (con historiales largos llegaba a pesar).
struct HistoryList: View, Equatable {
    @Environment(\.storeRef) private var store
    let state: HistoryState

    static func == (a: HistoryList, b: HistoryList) -> Bool {
        a.state.index == b.state.index && a.state.entries.map(\.id) == b.state.entries.map(\.id)
    }

    var body: some View {
        VStack(spacing: 1) {
            ForEach(Array(state.entries.enumerated()).reversed(), id: \.element.id) { i, e in
                Text(tr(e.name))
                    .font(.system(size: 11, weight: i == state.index ? .semibold : .regular))
                    .foregroundColor(i == state.index ? .white : (i > state.index ? Theme.dim : Theme.text))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .hoverBackground(radius: 4, active: i == state.index)
                    .contentShape(Rectangle())
                    .onTapGesture { store?.jumpHistory(i) }
            }
        }
    }
}

/// Miniatura del Navegador: marca la zona ampliada; clic o arrastre para desplazarse por la foto.
struct NavigatorImage: View {
    @EnvironmentObject var store: Store
    let image: CGImage
    let interactive: Bool

    var body: some View {
        GeometryReader { g in
            let box = CGSize(width: g.size.width - 8, height: g.size.height - 8)
            let a = CGFloat(image.width) / CGFloat(max(1, image.height))
            let w = min(box.width, box.height * a), h = w / a
            let r = CGRect(x: (g.size.width - w) / 2, y: (g.size.height - h) / 2, width: w, height: h)
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1).resizable().interpolation(.high)
                    .frame(width: w, height: h).offset(x: r.minX, y: r.minY)
                if interactive && store.zoomed {
                    let d = store.displaySize(store.zoomLevel)
                    let vw = min(1, store.viewport.width / max(1, d.width)), vh = min(1, store.viewport.height / max(1, d.height))
                    let c = store.zoomCenter
                    Rectangle()
                        .stroke(Theme.select, lineWidth: 1.5)
                        .background(Rectangle().fill(Theme.select.opacity(0.06)))
                        .frame(width: vw * w, height: vh * h)
                        .offset(x: r.minX + (c.x - vw / 2) * w, y: r.minY + (c.y - vh / 2) * h)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                guard interactive else { return }
                let p = CGPoint(x: (v.location.x - r.minX) / w, y: (v.location.y - r.minY) / h)
                if store.zoomed {
                    store.zoomCenter = store.clampedCenter(p, store.zoomLevel)
                } else {
                    store.zoom(to: max(1, store.fitLevel * 2), at: p)
                }
            })
            .help("Clic para ampliar ahí · arrastra para desplazarte")
        }
    }
}

struct ImageOverlay: View {
    @EnvironmentObject var store: Store
    var body: some View {
        GeometryReader { g in
            switch store.tool {
            case .crop:
                CropOverlay(rect: store.cropRect, ratio: store.normalizedCropRatio) { store.commit("Recortar") }
            case .whiteBalance, .pointColor:
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { loc in
                        let p = CGPoint(x: loc.x / g.size.width, y: loc.y / g.size.height)
                        if store.tool == .pointColor { store.pickPointColor(at: p) } else { store.sampleWhiteBalance(at: p) }
                    }
                    .onContinuousHover { phase in
                        if case .active = phase { NSCursor.crosshair.set() } else { NSCursor.arrow.set() }
                    }
            case .mask:
                MaskOverlay()
            case .heal:
                HealOverlay()
            case .none:
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { loc in
                        store.endEditing()
                        store.zoom(to: max(1, store.fitLevel * 2), at: CGPoint(x: loc.x / g.size.width, y: loc.y / g.size.height))
                    }
            }
        }
    }
}

/// Vista ampliada que se arrastra para desplazarse. Mientras llega el revelado a resolución completa
/// muestra la vista previa ampliada, así el cambio de zoom es inmediato.
struct ZoomedImage: View {
    @EnvironmentObject var store: Store
    let image: CGImage
    @Local private var dragStart: CGPoint?

    var body: some View {
        GeometryReader { g in
            let d = store.displaySize(store.zoomLevel)
            let c = store.zoomCenter
            Group {
                if store.settings.hdr {
                    EDRImage(image: image, nearest: store.zoomLevel >= 2)
                } else {
                    Image(decorative: image, scale: 1).resizable().interpolation(store.zoomLevel >= 2 ? .none : .high)
                }
            }
                .frame(width: d.width, height: d.height)
                .offset(x: (0.5 - c.x) * d.width, y: (0.5 - c.y) * d.height)
                .frame(width: g.size.width, height: g.size.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { v in
                            if dragStart == nil { dragStart = c }
                            let st = dragStart ?? c
                            store.zoomCenter = store.clampedCenter(CGPoint(x: st.x - v.translation.width / d.width,
                                                                           y: st.y - v.translation.height / d.height), store.zoomLevel)
                            NSCursor.closedHand.set()
                        }
                        .onEnded { _ in dragStart = nil; NSCursor.openHand.set() }
                )
                .onTapGesture { store.zoomed = false }
                .onContinuousHover { phase in
                    if case .active = phase { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
                }
        }
        .clipped()
    }
}

/// Imagen en una capa con EDR: muestra las luces HDR por encima del blanco (la Image de SwiftUI las recorta).
struct EDRImage: NSViewRepresentable {
    let image: CGImage
    var nearest = false

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.wantsExtendedDynamicRangeContent = true
        v.layer?.contentsGravity = .resize
        update(v)
        return v
    }

    func updateNSView(_ v: NSView, context: Context) { update(v) }

    private func update(_ v: NSView) {
        v.layer?.contents = image
        v.layer?.magnificationFilter = nearest ? .nearest : .linear
    }
}

/// Foto del lienzo: en HDR va en una capa EDR, si no en una Image normal.
struct PhotoImage: View {
    @EnvironmentObject var store: Store
    let image: CGImage
    var body: some View {
        if store.settings.hdr && !store.showBefore {
            EDRImage(image: image).aspectRatio(CGFloat(image.width) / CGFloat(max(1, image.height)), contentMode: .fit)
        } else {
            Image(decorative: image, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        }
    }
}

/// Antes / después (o referencia / actual) uno junto al otro.
struct SideBySide: View {
    @EnvironmentObject var store: Store
    let after: CGImage
    let before: CGImage?
    let leftLabel: String
    let rightLabel: String

    var body: some View {
        HStack(spacing: 12) {
            pane(before, leftLabel)
            pane(after, rightLabel)
        }
    }

    private func pane(_ img: CGImage?, _ label: String) -> some View {
        ZStack(alignment: .topLeading) {
            if let img {
                Image(decorative: img, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .background(Color.black.shadow(color: .black.opacity(0.55), radius: 12, y: 3))
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            CanvasBadge(text: label).padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Antes / después con cortinilla arrastrable.
struct SplitCompare: View {
    @EnvironmentObject var store: Store
    let after: CGImage
    let before: CGImage

    var body: some View {
        Image(decorative: after, scale: 1)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .background(Color.black.shadow(color: .black.opacity(0.55), radius: 18, y: 4))
            .overlay(
                GeometryReader { g in
                    let x = g.size.width * store.splitPosition
                    ZStack(alignment: .topLeading) {
                        Image(decorative: before, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: g.size.width, height: g.size.height)
                            .mask(HStack(spacing: 0) { Rectangle().frame(width: x); Spacer(minLength: 0) })
                        Rectangle().fill(Color.white).frame(width: 1.5, height: g.size.height).offset(x: x - 0.75)
                            .shadow(color: .black.opacity(0.5), radius: 2)
                        Circle().fill(Color.white).frame(width: 26, height: 26)
                            .overlay(Image(systemName: "arrow.left.and.right").font(.system(size: 10, weight: .bold)).foregroundColor(.black))
                            .shadow(color: .black.opacity(0.4), radius: 4)
                            .offset(x: x - 13, y: g.size.height / 2 - 13)
                        HStack {
                            CanvasBadge(text: "Antes")
                            Spacer()
                            CanvasBadge(text: "Después")
                        }
                        .padding(10)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        store.splitPosition = min(max(v.location.x / g.size.width, 0.02), 0.98)
                    })
                    .onContinuousHover { phase in
                        if case .active = phase { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
                    }
                }
            )
    }
}

struct CanvasBadge: View {
    let text: String
    var body: some View {
        Text(tr(text)).font(.system(size: 10.5, weight: .medium)).foregroundColor(.white)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Rectangle().fill(Color.black.opacity(0.72)))
            .overlay(Rectangle().stroke(Theme.border, lineWidth: 1))
    }
}

struct Toast: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundColor(.white)
            Text(tr(text)).font(.system(size: 12, weight: .medium)).foregroundColor(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Rectangle().fill(Theme.raised.opacity(0.97)))
        .overlay(Rectangle().stroke(Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 14, y: 4)
    }
}

struct CanvasView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var pv: PreviewModel
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Theme.canvas
                if store.current?.missing != true, let cg = pv.preview ?? store.current?.thumbnail {
                    if store.zoomed && store.tool == .none {
                        ZoomedImage(image: cg)
                    } else if store.sideBySideActive {
                        if store.compareReference {
                            let ref = store.photos.first { $0.id == store.referenceID }
                            SideBySide(after: cg, before: ref == nil ? nil : pv.referencePreview,
                                       leftLabel: ref.map { tr("Referencia · %@", $0.name) } ?? "Elige una referencia (clic derecho en la tira)",
                                       rightLabel: "Actual").padding(20)
                        } else {
                            SideBySide(after: cg, before: pv.beforePreview, leftLabel: "Antes", rightLabel: "Después").padding(20)
                        }
                    } else if store.splitActive, let before = pv.beforePreview {
                        SplitCompare(after: cg, before: before).padding(28)
                    } else {
                        PhotoImage(image: cg)
                            .background(Color.black.shadow(color: .black.opacity(0.55), radius: 18, y: 4))
                            .overlay(ImageOverlay())
                            .padding(store.tool == .crop ? 40 : 28)
                    }
                } else if let p = store.current, p.missing {
                    VStack(spacing: 12) {
                        Image(systemName: "questionmark.folder").font(.system(size: 38, weight: .light)).foregroundColor(Color.orange)
                        Text(tr("No se encuentra «%@»", p.name)).font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                        Text(p.url.deletingLastPathComponent().path).font(.system(size: 11)).foregroundColor(Theme.dim)
                            .lineLimit(1).truncationMode(.middle).frame(maxWidth: 420)
                        Text("Se ha movido, renombrado o el disco no está conectado. Tus ajustes se conservan.")
                            .font(.system(size: 11.5)).foregroundColor(Theme.secondary)
                        Button("Localizar…") { store.locate(p.id) }.buttonStyle(GhostButtonStyle(prominent: true))
                    }
                } else if store.photos.isEmpty {
                    EmptyState()
                }
                VStack {
                    HStack(alignment: .top, spacing: 6) {
                        ForEach(badges, id: \.self) { CanvasBadge(text: $0) }
                        Spacer()
                        if store.busy {
                            ProgressView().controlSize(.small).scaleEffect(0.8)
                                .padding(6).background(Circle().fill(Color.black.opacity(0.55)))
                                .transition(.opacity)
                        }
                    }
                    Spacer()
                    if let st = store.status {
                        Toast(text: st).transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(14)
            }
            .animation(.easeInOut(duration: 0.2), value: store.busy)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.status)
            .animation(.easeInOut(duration: 0.2), value: store.zoomed)
            .onAppear { store.viewport = geo.size; store.canvasFrame = geo.frame(in: .global) }
            .onChange(of: geo.size) { _, s in store.viewport = s; store.canvasFrame = geo.frame(in: .global) }
            .onChange(of: geo.frame(in: .global)) { _, f in store.canvasFrame = f }
        }
    }

    private var badges: [String] {
        var b: [String] = []
        if store.showBefore { b.append("Antes") }
        if store.settings.hdr && !store.showBefore { b.append("HDR") }
        if store.activePointOverlay != nil { b.append("Rango del punto de color") }
        if store.zoomed && store.tool == .none { b.append("\(store.zoomPercent) %") }
        if !store.disabledGroups.isEmpty { b.append("Paneles desactivados: vista previa parcial") }
        if store.clipHigh || store.clipLow { b.append("Aviso de recorte") }
        switch store.tool {
        case .whiteBalance: b.append("Haz clic en una zona neutra (gris o blanca)")
        case .pointColor: b.append("Haz clic en el color que quieres ajustar")
        case .mask where store.settings.masks.isEmpty: b.append("Crea una máscara en el panel derecho")
        case .heal where store.settings.heals.isEmpty: b.append("Haz clic sobre una mancha para eliminarla")
        default: break
        }
        return b
    }
}

struct EmptyState: View {
    @EnvironmentObject var store: Store
    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Color.white.opacity(0.04)).frame(width: 96, height: 96)
                Image(systemName: "camera.aperture").font(.system(size: 40, weight: .ultraLight)).foregroundColor(Theme.secondary)
            }
            VStack(spacing: 6) {
                Text("Empieza importando tus fotos").font(.system(size: 17, weight: .semibold)).foregroundColor(.white)
                Text("RAW, JPEG, HEIC, TIFF o PNG. Tus originales nunca se modifican.")
                    .font(.system(size: 12)).foregroundColor(Theme.secondary)
            }
            Button("Importar fotos") { store.importPanel() }.buttonStyle(GhostButtonStyle(prominent: true))
            Text("⇧⌘I  ·  o arrástralas a la ventana").font(.system(size: 10.5)).foregroundColor(Theme.dim)
        }
    }
}

/// Miniatura de la tira y la biblioteca. Equatable: no se redibuja con cada ajuste de la foto abierta.
struct ThumbCell: View, Equatable {
    let photo: Photo
    let selected: Bool
    var marked = false
    @Local private var hover = false

    static func == (a: ThumbCell, b: ThumbCell) -> Bool {
        a.photo == b.photo && a.selected == b.selected && a.marked == b.marked
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color(white: 0.1)
            if photo.missing {
                VStack(spacing: 3) {
                    Image(systemName: "questionmark.folder").font(.system(size: 16)).foregroundColor(Color.orange)
                    Text("No encontrada").font(.system(size: 8.5, weight: .semibold)).foregroundColor(Color.orange)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let t = photo.thumbnail {
                Image(decorative: t, scale: 1).resizable().interpolation(.medium).aspectRatio(contentMode: .fit).padding(3)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 3) {
                if photo.isRAW { tag("RAW") }
                Spacer()
                if photo.isEdited { Marker().padding(2) }
            }
            .padding(4)
        }
        .clipShape(Rectangle())
        .overlay(Rectangle().stroke(selected ? Theme.select : Color.white.opacity(marked ? 0.6 : (hover ? 0.2 : 0.05)),
                                                          lineWidth: selected ? 2 : (marked ? 1.5 : 1)))
        .opacity(selected || marked || hover ? 1 : 0.72)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }

    private func tag(_ t: String) -> some View {
        Text(t).font(.system(size: 7, weight: .bold)).foregroundColor(.white)
            .padding(.horizontal, 3).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.65)))
    }
}

struct PhotoContextMenu: View {
    @EnvironmentObject var store: Store
    let photo: Photo
    var body: some View {
        if photo.missing {
            Button("Localizar…") { store.locate(photo.id) }
        } else {
            Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([photo.url]) }
        }
        Button("Pegar ajustes copiados") {
            store.select(photo.id)
            store.pasteSettings()
        }
        Button(store.referenceID == photo.id ? "Quitar como referencia" : "Usar como referencia para comparar") {
            store.setReference(store.referenceID == photo.id ? nil : photo.id)
        }
        Divider()
        Button("Quitar del catálogo") { store.remove(photo.id) }
    }
}

struct Filmstrip: View {
    @EnvironmentObject var store: Store
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(store.photos) { p in
                        ThumbCell(photo: p, selected: p.id == store.selectedID, marked: store.multiSelection.contains(p.id)).equatable()
                            .frame(width: 92, height: 66)
                            .id(p.id)
                            .onTapGesture { store.click(p.id) }
                            .contextMenu { PhotoContextMenu(photo: p) }
                    }
                }
                .padding(.horizontal, 10)
            }
            .onChange(of: store.selectedID) { _, id in
                if let id { withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) } }
            }
        }
        .frame(height: 82)
        .background(Color(white: 0.06))
    }
}

struct LibraryGrid: View {
    @EnvironmentObject var store: Store
    var body: some View {
        if store.photos.isEmpty {
            ZStack { Theme.canvas; EmptyState() }
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) {
                    ForEach(store.photos) { p in
                        VStack(alignment: .leading, spacing: 6) {
                            ThumbCell(photo: p, selected: p.id == store.selectedID, marked: store.multiSelection.contains(p.id)).equatable()
                                .frame(height: 150)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).font(.system(size: 11, weight: .medium)).foregroundColor(Theme.text).lineLimit(1)
                                Text(p.exif.isEmpty ? " " : p.exif).font(.system(size: 9.5)).foregroundColor(Theme.dim).lineLimit(1)
                            }
                            .padding(.horizontal, 2)
                        }
                        .padding(8)
                        .hoverBackground(radius: 8, active: p.id == store.selectedID || store.multiSelection.contains(p.id))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            store.select(p.id)
                            store.module = .develop
                            store.scheduleRender()
                        }
                        .onTapGesture { store.click(p.id) }
                        .contextMenu { PhotoContextMenu(photo: p) }
                    }
                }
                .padding(20)
            }
            .background(Theme.canvas)
        }
    }
}

/// Fondo de la barra superior que actúa como la barra de título de macOS (la ventana la oculta y Revela
/// dibuja la suya): doble clic hace lo que diga Ajustes del Sistema (ampliar por defecto) y arrastrar mueve la ventana.
struct TitleBarArea: NSViewRepresentable {
    final class AreaView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with e: NSEvent) {
            guard let w = window else { return }
            if e.clickCount == 2 { Self.doubleClick(w) } else { w.performDrag(with: e) }
        }

        static func doubleClick(_ w: NSWindow) {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": w.miniaturize(nil)
            case "None", "Do Nothing": break
            case "Fill": if let f = w.screen?.visibleFrame { w.setFrame(f, display: true, animate: true) }
            default: w.zoom(nil)
            }
        }
    }

    func makeNSView(context: Context) -> NSView { AreaView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct TopBar: View {
    @EnvironmentObject var store: Store
    @AppStorage("showLeftPanel") private var showLeft = true

    var body: some View {
        HStack(spacing: 10) {
            Text("Revela").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
            if store.module == .develop {
                IconButton(icon: "sidebar.left", help: "Mostrar u ocultar el panel izquierdo", active: false, size: 12) {
                    withAnimation(.easeInOut(duration: 0.22)) { showLeft.toggle() }
                }
            }
            Spacer()
            HStack(spacing: 0) {
                moduleButton("Biblioteca", .library, key: "G")
                moduleButton("Revelar", .develop, key: "D")
            }
            Spacer().frame(width: 18)
            Menu {
                ForEach(AppLanguage.allCases) { l in
                    Button((l == AppLanguage.current ? "✓  " : "     ") + l.name) { AppLanguage.choose(l) }
                }
            } label: {
                Text(AppLanguage.current.rawValue.uppercased()).font(.system(size: 10.5, weight: .semibold).monospaced())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Idioma de la interfaz")
            IconButton(icon: "keyboard", help: "Atajos de teclado (?)", size: 12) { store.showShortcuts = true }
        }
        .padding(.leading, 82)
        .padding(.trailing, 12)
        .frame(height: 40)
        .background(ZStack { Theme.window; TitleBarArea() })
    }

    private func moduleButton(_ t: String, _ m: Store.Module, key: String) -> some View {
        let on = store.module == m
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { store.module = m }
            if m == .develop { store.scheduleRender() }
        } label: {
            Text(tr(t)).font(.system(size: 12, weight: on ? .semibold : .medium))
                .foregroundColor(on ? Theme.onSelect : Theme.secondary)
                .padding(.horizontal, 18)
                .frame(height: 40)
                .background(on ? Theme.select : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(tr(t)) (\(key))")
    }
}

struct BottomBar: View {
    @EnvironmentObject var store: Store
    var body: some View {
        HStack(spacing: 12) {
            if store.module == .develop {
                Segmented(selection: Binding(get: { store.compareMode }, set: { store.compareMode = $0 }),
                          options: [(0, "Después"), (1, "Antes"), (2, "Dividido"), (3, "Lado a lado"), (4, "Referencia")])
                    .frame(width: 330)
                    .help("Antes (\\) · Dividido (Y) · Referencia: clic derecho en una miniatura")
                Menu {
                    Button("Encajar") { store.zoomed = false }
                    Divider()
                    ForEach(Store.zoomPresets, id: \.self) { l in
                        Button("\(Int(l * 100)) %") { store.zoom(to: l) }
                    }
                } label: {
                    Text(store.zoomed ? "\(store.zoomPercent) %" : tr("Encajar")).font(.system(size: 11).monospacedDigit())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Zoom: pellizca, usa la rueda o ⌘ + desplazar · Z alterna")
                IconButton(icon: "triangle.lefthalf.filled", help: "Aviso de recorte de luces y sombras (J)",
                           active: store.clipHigh || store.clipLow, size: 11) {
                    let on = !(store.clipHigh || store.clipLow)
                    store.clipHigh = on
                    store.clipLow = on
                }
            }
            Spacer()
            if let p = store.current, let i = store.currentIndex {
                HStack(spacing: 8) {
                    Text(p.name).font(.system(size: 11, weight: .medium)).foregroundColor(Theme.text).lineLimit(1)
                    if p.pixelSize.width > 0 {
                        Text("\(Int(p.pixelSize.width)) × \(Int(p.pixelSize.height))").font(.system(size: 10.5).monospacedDigit()).foregroundColor(Theme.dim)
                    }
                    Text(tr("%@ de %@", "\(i + 1)", "\(store.photos.count)")).font(.system(size: 10.5).monospacedDigit()).foregroundColor(Theme.dim)
                }
            }
            Spacer()
            if let p = store.exportProgress {
                HStack(spacing: 6) {
                    Text(store.exportLabel).font(.system(size: 10.5).monospacedDigit()).foregroundColor(Theme.text)
                    ProgressView(value: p).progressViewStyle(.linear).tint(Theme.select).frame(width: 120)
                    IconButton(icon: "xmark", help: "Cancelar la exportación", size: 9) { store.cancelExport() }
                }
            }
            if store.missingCount > 0 {
                Text(tr("%@ no encontradas", "\(store.missingCount)")).font(.system(size: 10.5)).foregroundColor(.orange)
                    .help("Clic derecho en la miniatura ▸ Localizar…")
            }
            if !store.multiSelection.isEmpty {
                Text(tr("%@ marcadas", "\(store.multiSelection.count + 1)")).font(.system(size: 10.5)).foregroundColor(Theme.secondary)
                Button("Igualar exposición") { store.matchExposure() }.buttonStyle(GhostButtonStyle(compact: true))
                    .help("Iguala el brillo de las fotos marcadas al de la actual (⌥⇧⌘M)")
            }
            Button("Importar…") { store.importPanel() }.buttonStyle(GhostButtonStyle(compact: true))
            Button("Exportar…") { store.showExport = true }.buttonStyle(GhostButtonStyle(prominent: true, compact: true))
                .disabled(store.photos.isEmpty)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Theme.panel)
    }
}

struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let groups: [(String, [(String, String)])] = [
        ("Herramientas", [("R", "Recortar y enderezar"), ("Q", "Eliminar manchas"), ("M", "Máscaras"), ("W", "Balance de blancos"),
                          ("O", "Superposición de máscara"), ("H", "Mostrar puntos de corrección"), ("X", "Orientación del recorte"),
                          ("↩ / Esc", "Cerrar herramienta"), ("⌫", "Borrar máscara o corrección")]),
        ("Vista", [("Z / espacio", "Zoom 1:1"), ("\\", "Antes"), ("Y", "Antes / después dividido"), ("J", "Aviso de recorte"),
                   ("Tab", "Ocultar paneles"), ("G / D", "Biblioteca / Revelar"), ("← →", "Foto anterior / siguiente"),
                   ("⌘ / ⇧ + clic", "Marcar varias fotos")]),
        ("Edición", [("⌘Z / ⇧⌘Z", "Deshacer / rehacer"), ("⇧⌘C / ⇧⌘V", "Copiar / pegar ajustes"), ("⌥⌘V", "Ajustes anteriores"),
                     ("⇧⌘R", "Restablecer"), ("⌘U", "Tono automático"), ("⌥⇧⌘M", "Igualar exposición"), ("⌘[ / ⌘]", "Girar"),
                     ("Doble clic", "Restablecer un deslizador"), ("⌥ + arrastrar", "Ajuste fino")]),
        ("Archivo", [("⇧⌘I", "Importar"), ("⇧⌘E", "Exportar"), ("⇧⌘N", "Nuevo ajuste preestablecido")]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Atajos de teclado").font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                Spacer()
                Button("Cerrar") { dismiss() }.buttonStyle(GhostButtonStyle(compact: true)).keyboardShortcut(.cancelAction)
            }
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 18) { group(0); group(3) }
                VStack(alignment: .leading, spacing: 18) { group(1); group(2) }
            }
        }
        .padding(24)
        .frame(width: 640)
        .background(Theme.panel)
    }

    private func group(_ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            SubHeader(groups[i].0)
            ForEach(groups[i].1, id: \.0) { k, d in
                HStack(spacing: 10) {
                    Text(tr(k)).font(.system(size: 10.5, weight: .medium).monospaced()).foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.1)))
                        .frame(minWidth: 96, alignment: .leading)
                    Text(tr(d)).font(.system(size: 11.5)).foregroundColor(Theme.text)
                }
            }
        }
        .frame(width: 280, alignment: .leading)
    }
}

/// Separador vertical que se arrastra para cambiar el ancho de un panel.
struct PanelResizer: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    /// +1 si el panel está a la izquierda del separador, −1 si está a la derecha.
    let direction: Double
    @Local private var start: Double?
    @Local private var hover = false

    var body: some View {
        Rectangle()
            .fill(hover || start != nil ? Theme.select.opacity(0.6) : Theme.separator)
            .frame(width: hover || start != nil ? 2 : 1)
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
            .padding(.horizontal, -3)
            .onHover { h in
                hover = h
                if h { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    if start == nil { start = width }
                    width = min(max((start ?? width) + direction * Double(v.translation.width), range.lowerBound), range.upperBound)
                }
                .onEnded { _ in start = nil })
            .onTapGesture(count: 2) { width = direction > 0 ? 236 : 330 }
            .help("Arrastra para cambiar el ancho · doble clic para restablecer")
    }
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @AppStorage("showLeftPanel") private var showLeft = true
    @AppStorage("leftPanelWidth") private var leftWidth = 236.0
    @AppStorage("rightPanelWidth") private var rightWidth = 330.0

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            Separator()
            HStack(spacing: 0) {
                if store.module == .develop {
                    if showLeft && !store.panelsHidden {
                        LeftPanel().frame(width: leftWidth).transition(.move(edge: .leading).combined(with: .opacity))
                        PanelResizer(width: $leftWidth, range: 190...420, direction: 1)
                    }
                    CanvasView()
                    if !store.panelsHidden {
                        PanelResizer(width: $rightWidth, range: 290...560, direction: -1)
                        RightPanel().frame(width: rightWidth).transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                } else {
                    LibraryGrid()
                }
            }
            Separator()
            BottomBar()
            if !store.panelsHidden {
                Separator()
                Filmstrip().transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Theme.window)
        .ignoresSafeArea(.container, edges: .top)
        .tint(.white)
        .preferredColorScheme(.dark)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { store.add(urls: [url]) } }
                }
            }
            return true
        }
        .sheet(isPresented: $store.showExport) { ExportSheet() }
        .sheet(isPresented: $store.showShortcuts) { ShortcutsSheet() }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { store.endEditing() } }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct RevelaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup("Revela") {
            ContentView()
                .environmentObject(store)
                .environmentObject(store.previews)
                .environment(\.storeRef, store)
                .frame(minWidth: 1150, minHeight: 720)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Importar fotos…") { store.importPanel() }.keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Exportar…") { store.showExport = true }.keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(store.photos.isEmpty)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Deshacer") { store.undo() }.keyboardShortcut("z")
                Button("Rehacer") { store.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandMenu("Ajustes") {
                Button("Copiar ajustes") { store.copySettings() }.keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Pegar ajustes") { store.pasteSettings() }.keyboardShortcut("v", modifiers: [.command, .shift])
                Button("Ajustes anteriores") { store.pastePrevious() }.keyboardShortcut("v", modifiers: [.command, .option])
                Button("Restablecer") { store.reset() }.keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Tono automático") { store.autoTone() }.keyboardShortcut("u")
                Button("Balance de blancos automático") { store.autoWhiteBalance() }.keyboardShortcut("u", modifiers: [.command, .shift])
                Button("Igualar exposición") { store.matchExposure() }.keyboardShortcut("m", modifiers: [.command, .option, .shift])
                    .disabled(store.photos.count < 2)
                Divider()
                Button("Girar a la izquierda") { store.rotate(-1) }.keyboardShortcut("[")
                Button("Girar a la derecha") { store.rotate(1) }.keyboardShortcut("]")
                Button("Voltear horizontal") { store.flip() }
                Divider()
                Button("Nuevo ajuste preestablecido…") { store.saveUserPreset() }.keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("Atajos de teclado") { store.showShortcuts = true }.keyboardShortcut("/", modifiers: [.command])
            }
            CommandMenu("Foto") {
                Button("Biblioteca  (G)") { store.module = .library }
                Button("Revelar  (D)") { store.module = .develop; store.scheduleRender() }
                Divider()
                Button("Recortar  (R)") { store.toggleTool(.crop) }
                Button("Eliminar manchas  (Q)") { store.toggleTool(.heal) }
                Button("Balance de blancos  (W)") { store.toggleTool(.whiteBalance) }
                Button("Máscaras  (M)") { store.toggleTool(.mask) }
                Button("Seleccionar sujeto") { store.addDetectedMask(.subject) }.disabled(store.current == nil)
                Button("Seleccionar personas") { store.addDetectedMask(.people) }.disabled(store.current == nil)
                Button("Seleccionar fondo") { store.addDetectedMask(.background) }.disabled(store.current == nil)
                Button("Enderezar automáticamente") { store.autoStraighten() }.disabled(store.current == nil)
                Button("Antes  (\\)") { store.showBefore.toggle() }
                Button("Antes / después dividido  (Y)") { store.splitView.toggle() }
                Button("Aviso de recorte  (J)") { let on = !(store.clipHigh || store.clipLow); store.clipHigh = on; store.clipLow = on }
                Button("Ocultar paneles  (Tab)") { withAnimation { store.panelsHidden.toggle() } }
                Button("Acercar") { store.zoomStep(1) }.keyboardShortcut("=", modifiers: [.command])
                Button("Alejar") { store.zoomStep(-1) }.keyboardShortcut("-", modifiers: [.command])
                Button("Encajar en la ventana") { store.zoomed = false }.keyboardShortcut("0", modifiers: [.command])
                Button("Antes / después lado a lado") { store.compareMode = store.compareMode == 3 ? 0 : 3 }
                Divider()
                Button("Foto anterior  (←)") { store.step(-1) }
                Button("Foto siguiente  (→)") { store.step(1) }
                Divider()
                Button("Quitar del catálogo") { if let id = store.selectedID { store.remove(id) } }.disabled(store.selectedID == nil)
            }
        }
    }
}
