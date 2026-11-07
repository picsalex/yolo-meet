import AppKit
import CoreText
import YoloMeetCore

/// Each vendor's annotation style, so YOLO and RF-DETR stay visually distinct:
/// - Ultralytics (https://www.ultralytics.com/brand): annotation palette, Arial labels, brand-color skeletons.
/// - Roboflow (https://roboflow.com/brand, supervision defaults): supervision palette and 2 px boxes, Geist Mono labels,
///   purple/lavender skeletons.
struct Theme {
    let classes: [NSColor]
    let labelFont: String
    /// Box stroke at 720 px of stage height.
    let lineWidth: CGFloat
    /// Label text on light chips (white otherwise).
    let darkText: NSColor
    let leftLimb: NSColor
    let rightLimb: NSColor
    let centerLimb: NSColor
    let joint: NSColor
    let jointOutline: NSColor
    /// Skeleton line width and joint radius at 720 px of stage height.
    var limbWidth: CGFloat = 4
    var jointRadius: CGFloat = 4.5

    static let ultralytics = Theme(
        classes: Palette.ultralytics.map { NSColor($0) }, labelFont: "ArialMT", lineWidth: 3, darkText: .hex("111F68"),
        leftLimb: .hex("00FFFF"), rightLimb: .hex("FF64DA"), centerLimb: .hex("ACF9FF"),
        joint: .hex("E1FF25"), jointOutline: .hex("111F68"))

    static let roboflow = Theme(
        classes: Palette.roboflow.map { NSColor($0) }, labelFont: "GeistMono-Medium", lineWidth: 2, darkText: .hex("161026"),
        leftLimb: .hex("C29AF6"), rightLimb: .hex("8033EB"), centerLimb: .hex("E8DAF7"),
        joint: .hex("F4F2EC"), jointOutline: .hex("161026"))

    /// MediaPipe's drawing_utils defaults: light gray connections, red landmarks.
    static let mediapipe = Theme(
        classes: [.hex("FF0000"), .hex("00FF00")], labelFont: "ArialMT", lineWidth: 2, darkText: .black,
        leftLimb: .hex("E0E0E0"), rightLimb: .hex("E0E0E0"), centerLimb: .hex("E0E0E0"),
        joint: .hex("FF0000"), jointOutline: .hex("FF0000"), limbWidth: 2, jointRadius: 3)

    /// Apple Vision: white lines, system blue joints.
    static let vision = Theme(
        classes: [.systemBlue, .systemOrange], labelFont: "ArialMT", lineWidth: 2, darkText: .black,
        leftLimb: .white, rightLimb: .white, centerLimb: .white, joint: .systemBlue, jointOutline: .white,
        limbWidth: 2.5, jointRadius: 4)

    /// Ultralytics' corporate typeface, for captions and titles.
    static let titleFont = "ArchivoRoman-Bold"
    static let darkBlue = NSColor.hex("111F68")

    static func of(_ output: ModelOutput?) -> Theme {
        switch output?.info.family {
        case "RF-DETR": .roboflow
        case "MediaPipe": .mediapipe
        case "Apple Vision": .vision
        default: .ultralytics
        }
    }

    func color(_ classIndex: Int) -> NSColor { classes[abs(classIndex) % classes.count] }

    /// White text, or the brand's dark text when the chip is light.
    func textColor(on chip: NSColor) -> NSColor {
        guard let rgb = chip.usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance > 0.6 ? darkText : .white
    }

    /// Makes the bundled brand fonts (Archivo, Geist Mono; SIL OFL) available to this process. Arial ships with macOS.
    static func registerFonts() {
        for url in Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? [] {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

extension NSColor {
    convenience init(_ rgb: (UInt8, UInt8, UInt8)) {
        self.init(srgbRed: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255, blue: CGFloat(rgb.2) / 255, alpha: 1)
    }

    static func hex(_ hex: String) -> NSColor { NSColor(Palette.rgb(hex)) }
}
