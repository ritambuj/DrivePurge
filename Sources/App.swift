//
//  DrivePurge — native macOS disk-space visualiser
//
//  A one-file SwiftUI/AppKit translation of the "DissectMac Visualizer" HTML
//  prototype: dark chrome, 292pt sidebar, squarified proportional treemap,
//  background scanner and a safe move-to-Trash clean routine.
//
//  Build & run:  swift run
//

import SwiftUI
import AppKit
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Colour primitives (ported from the prototype's hexToRgb / mix / rgba)
// ─────────────────────────────────────────────────────────────────────────────

struct RGB: Equatable {
    var r: Double
    var g: Double
    var b: Double

    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

    init(_ hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Foundation.Scanner(string: s).scanHexInt64(&v)
        r = Double((v >> 16) & 0xFF) / 255.0
        g = Double((v >> 8) & 0xFF) / 255.0
        b = Double(v & 0xFF) / 255.0
    }

    /// Linear interpolation towards `other` — the prototype's `mix(a, b, t)`.
    func mixed(_ other: RGB, _ t: Double) -> RGB {
        let k = min(max(t, 0), 1)
        return RGB(r: r + (other.r - r) * k,
                   g: g + (other.g - g) * k,
                   b: b + (other.b - b) * k)
    }

    var color: Color { Color(red: r, green: g, blue: b) }
    func color(_ alpha: Double) -> Color { Color(red: r, green: g, blue: b, opacity: alpha) }
}

extension Color {
    init(hex: String) { self = RGB(hex).color }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Theme
//
//  DrivePurge ships two skins of the same app:
//
//    .apple      the original macOS-native look — dark chrome, rounded
//                controls, gradients, Apple's system accent hues.
//    .modernist  the "Modernist" design system behind drivepurge.com —
//                paper ground, ink type, one vermilion accent, 2pt rules
//                and nothing rounded.
//
//  Every colour, radius and rule width the views draw comes from `Theme`,
//  which forwards to whichever `Palette` is current. Switching themes swaps
//  the palette and rebuilds the view tree; no view knows which skin it is in.
// ─────────────────────────────────────────────────────────────────────────────

enum AppTheme: String, CaseIterable, Identifiable {
    case apple
    case modernist

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple:     return "Apple Default"
        case .modernist: return "Modernist"
        }
    }

    /// Label for the compact title-bar toggle.
    var shortTitle: String {
        switch self {
        case .apple:     return "Apple"
        case .modernist: return "Modernist"
        }
    }

    var symbol: String {
        switch self {
        case .apple:     return "moon.stars"
        case .modernist: return "square.grid.2x2"
        }
    }

    var next: AppTheme { self == .apple ? .modernist : .apple }

    var colorScheme: ColorScheme { self == .apple ? .dark : .light }

    var palette: Palette { self == .apple ? .apple : .modernist }
}

extension Notification.Name {
    static let drivePurgeThemeChanged = Notification.Name("DrivePurgeThemeChanged")
}

/// The user's choice, persisted across launches.
@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()
    private static let defaultsKey = "DrivePurge.appTheme"

    @Published var theme: AppTheme {
        didSet {
            guard oldValue != theme else { return }
            UserDefaults.standard.set(theme.rawValue, forKey: Self.defaultsKey)
            Theme.palette = theme.palette
            NotificationCenter.default.post(name: .drivePurgeThemeChanged, object: theme)
        }
    }

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.defaultsKey)
            .flatMap(AppTheme.init(rawValue:)) ?? .apple
        theme = stored
        Theme.palette = stored.palette
    }

    func select(_ theme: AppTheme) { self.theme = theme }
    func toggle() { theme = theme.next }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Palette

struct Palette {
    // Surfaces
    var windowBG: RGB
    var sidebarBG: RGB
    var canvasBG: RGB
    var statusBarBG: RGB
    var chipBG: RGB
    var chipHoverBG: RGB
    var controlBG: RGB
    var controlHoverBG: RGB
    var inputBG: RGB
    var railBG: RGB
    var trackBG: RGB
    var rowHoverBG: RGB
    var rowSelectedBG: RGB
    var gaugeTrack: RGB

    // Title bar
    var titleBarTop: RGB
    var titleBarBottom: RGB

    // Rules
    var border: RGB
    var borderSoft: RGB
    var borderSidebar: RGB
    var borderControl: RGB
    var borderControlHover: RGB
    var borderChip: RGB
    var borderInput: RGB
    var borderCanvas: RGB
    var borderRow: RGB
    var borderSelected: RGB
    /// Hairlines are 1pt on Apple, 2pt rules on Modernist.
    var ruleWidth: CGFloat

    // Type
    var textPrimary: RGB
    var textStrong: RGB
    var textBody: RGB
    var textMuted: RGB
    var textDim: RGB
    var textFaint: RGB
    var textLabel: RGB
    var textControl: RGB
    var textControlHover: RGB
    var textSeparator: RGB
    /// Ink for anything drawn on top of a filled accent surface.
    var onAccent: RGB

    // Accents
    var accent: RGB
    var accentTop: RGB
    var accentBottom: RGB
    var accentSoft: RGB
    var tabTop: RGB
    var tabBottom: RGB
    var onTab: RGB
    var promoTop: RGB
    var promoBottom: RGB
    var promoInk: RGB
    var danger: RGB
    var dangerSoft: RGB
    var success: RGB
    var successSoft: RGB
    var warning: RGB
    var amber: RGB
    /// Barber-pole fill marking space queued for reclaim.
    var stripeBase: RGB
    var stripeInk: RGB

    // Shape
    /// Multiplier applied to every corner radius — 0 flattens the whole app.
    var radiusScale: CGFloat
    /// Treemap rectangles are shaded translucently on Apple, solid on Modernist.
    var solidTreemapFills: Bool
    /// Gap and border colour around each treemap rectangle.
    var treemapGridline: RGB
    var elevated: Bool

    // Type family
    var headingFontName: String?
    var bodyFontName: String?
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - The two palettes

extension Palette {

    /// The original design: dark chrome and Apple's system accents.
    static let apple = Palette(
        windowBG:          RGB("#0b0b0d"),
        sidebarBG:         RGB("#101013"),
        canvasBG:          RGB("#0e0e12"),
        statusBarBG:       RGB("#0e0e11"),
        chipBG:            RGB("#16161b"),
        chipHoverBG:       RGB("#1d1d23"),
        controlBG:         RGB("#17171c"),
        controlHoverBG:    RGB("#1d1d23"),
        inputBG:           RGB("#101013"),
        railBG:            RGB("#1e1e24"),
        trackBG:           RGB("#202027"),
        rowHoverBG:        RGB("#15151a"),
        rowSelectedBG:     RGB("#1d1d24"),
        gaugeTrack:        RGB("#212128"),

        titleBarTop:       RGB("#1b1b1f"),
        titleBarBottom:    RGB("#16161a"),

        border:            RGB("#26262b"),
        borderSoft:        RGB("#1e1e24"),
        borderSidebar:     RGB("#23232a"),
        borderControl:     RGB("#2b2b33"),
        borderControlHover: RGB("#3a3a44"),
        borderChip:        RGB("#2a2a32"),
        borderInput:       RGB("#2c2c32"),
        borderCanvas:      RGB("#1f1f26"),
        borderRow:         RGB("#17171c"),
        borderSelected:    RGB("#32323c"),
        ruleWidth:         1,

        textPrimary:       RGB("#f5f5f7"),
        textStrong:        RGB("#f0f0f4"),
        textBody:          RGB("#e4e4ea"),
        textMuted:         RGB("#8b8b94"),
        textDim:           RGB("#6e6e77"),
        textFaint:         RGB("#64646c"),
        textLabel:         RGB("#7b7b84"),
        textControl:       RGB("#b9b9c0"),
        textControlHover:  RGB("#ffffff"),
        textSeparator:     RGB("#3c3c44"),
        onAccent:          RGB("#ffffff"),

        accent:            RGB("#0a84ff"),
        accentTop:         RGB("#1e90ff"),
        accentBottom:      RGB("#0a6fe0"),
        accentSoft:        RGB("#6fb6ff"),
        tabTop:            RGB("#2a6fdb"),
        tabBottom:         RGB("#1a5cc4"),
        onTab:             RGB("#ffffff"),
        promoTop:          RGB("#ffc531"),
        promoBottom:       RGB("#f5a623"),
        promoInk:          RGB("#2a1c00"),
        danger:            RGB("#ff453a"),
        dangerSoft:        RGB("#ff6b6b"),
        success:           RGB("#30d158"),
        successSoft:       RGB("#41d96a"),
        warning:           RGB("#ffb340"),
        amber:             RGB("#febc2e"),
        stripeBase:        RGB("#1f8f3c"),
        stripeInk:         RGB("#30d158"),

        radiusScale:       1,
        solidTreemapFills: false,
        treemapGridline:   RGB("#0b0b0d"),
        elevated:          true,

        headingFontName:   nil,
        bodyFontName:      nil
    )

    /// The Modernist system that drivepurge.com is built from: paper, ink,
    /// one vermilion accent, 2pt rules and square corners.
    static let modernist = Palette(
        windowBG:          RGB("#f3f2f2"),   // --color-bg
        sidebarBG:         RGB("#f8f4f4"),   // --color-neutral-100
        canvasBG:          RGB("#f3f2f2"),
        statusBarBG:       RGB("#f8f4f4"),
        chipBG:            RGB("#f3f2f2"),
        chipHoverBG:       RGB("#eae7e7"),   // --color-neutral-200
        controlBG:         RGB("#f3f2f2"),
        controlHoverBG:    RGB("#eae7e7"),
        inputBG:           RGB("#eae9e9"),   // --color-surface
        railBG:            RGB("#d7d3d3"),   // --color-neutral-300
        trackBG:           RGB("#d7d3d3"),
        rowHoverBG:        RGB("#f8f4f4"),
        rowSelectedBG:     RGB("#fff2ef"),   // --color-accent-100
        gaugeTrack:        RGB("#d7d3d3"),

        titleBarTop:       RGB("#f3f2f2"),
        titleBarBottom:    RGB("#f3f2f2"),

        border:            RGB("#201e1d"),   // --color-text
        borderSoft:        RGB("#bab6b6"),   // --color-neutral-400 ≈ --color-divider
        borderSidebar:     RGB("#201e1d"),
        borderControl:     RGB("#201e1d"),
        borderControlHover: RGB("#ec3013"),
        borderChip:        RGB("#bab6b6"),
        borderInput:       RGB("#bab6b6"),
        borderCanvas:      RGB("#201e1d"),
        borderRow:         RGB("#eae7e7"),
        borderSelected:    RGB("#ec3013"),
        ruleWidth:         2,

        textPrimary:       RGB("#201e1d"),
        textStrong:        RGB("#201e1d"),
        textBody:          RGB("#444141"),   // --color-neutral-800
        textMuted:         RGB("#605d5d"),   // --color-neutral-700
        textDim:           RGB("#7d7979"),   // --color-neutral-600
        textFaint:         RGB("#7d7979"),
        textLabel:         RGB("#ae1800"),   // --color-accent-700
        textControl:       RGB("#444141"),
        textControlHover:  RGB("#201e1d"),
        textSeparator:     RGB("#bab6b6"),
        onAccent:          RGB("#f3f2f2"),

        accent:            RGB("#ec3013"),   // --color-accent
        accentTop:         RGB("#ec3013"),
        accentBottom:      RGB("#ec3013"),
        accentSoft:        RGB("#7c1405"),   // --color-accent-800
        tabTop:            RGB("#201e1d"),   // the active tab is ink on paper
        tabBottom:         RGB("#201e1d"),
        onTab:             RGB("#f3f2f2"),
        promoTop:          RGB("#ec3013"),
        promoBottom:       RGB("#ec3013"),
        promoInk:          RGB("#f3f2f2"),
        danger:            RGB("#ec3013"),
        dangerSoft:        RGB("#ae1800"),
        success:           RGB("#ae1800"),
        successSoft:       RGB("#7c1405"),
        warning:           RGB("#444141"),
        amber:             RGB("#ae1800"),
        stripeBase:        RGB("#ffc4b8"),   // --color-accent-300
        stripeInk:         RGB("#ec3013"),

        radiusScale:       0,
        solidTreemapFills: true,
        treemapGridline:   RGB("#f3f2f2"),
        elevated:          false,

        headingFontName:   "Archivo",
        bodyFontName:      "Archivo"
    )
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Theme — what the views actually read

enum Theme {
    /// Kept in step with `ThemeStore.shared.theme`.
    static var palette: Palette = .apple

    // Surfaces
    static var windowBG: Color        { palette.windowBG.color }
    static var sidebarBG: Color       { palette.sidebarBG.color }
    static var canvasBG: Color        { palette.canvasBG.color }
    static var statusBarBG: Color     { palette.statusBarBG.color }
    static var chipBG: Color          { palette.chipBG.color }
    static var chipHoverBG: Color     { palette.chipHoverBG.color }
    static var controlBG: Color       { palette.controlBG.color }
    static var controlHoverBG: Color  { palette.controlHoverBG.color }
    static var inputBG: Color         { palette.inputBG.color }
    static var railBG: Color          { palette.railBG.color }
    static var trackBG: Color         { palette.trackBG.color }
    static var rowHoverBG: Color      { palette.rowHoverBG.color }
    static var rowSelectedBG: Color   { palette.rowSelectedBG.color }
    static var gaugeTrack: Color      { palette.gaugeTrack.color }

    // Title bar
    static var titleBarTop: Color     { palette.titleBarTop.color }
    static var titleBarBottom: Color  { palette.titleBarBottom.color }

    // Rules
    static var border: Color             { palette.border.color }
    static var borderSoft: Color         { palette.borderSoft.color }
    static var borderSidebar: Color      { palette.borderSidebar.color }
    static var borderControl: Color      { palette.borderControl.color }
    static var borderControlHover: Color { palette.borderControlHover.color }
    static var borderChip: Color         { palette.borderChip.color }
    static var borderInput: Color        { palette.borderInput.color }
    static var borderCanvas: Color       { palette.borderCanvas.color }
    static var borderRow: Color          { palette.borderRow.color }
    static var borderSelected: Color     { palette.borderSelected.color }
    static var ruleWidth: CGFloat        { palette.ruleWidth }

    // Type
    static var textPrimary: Color      { palette.textPrimary.color }
    static var textStrong: Color       { palette.textStrong.color }
    static var textBody: Color         { palette.textBody.color }
    static var textMuted: Color        { palette.textMuted.color }
    static var textDim: Color          { palette.textDim.color }
    static var textFaint: Color        { palette.textFaint.color }
    static var textLabel: Color        { palette.textLabel.color }
    static var textControl: Color      { palette.textControl.color }
    static var textControlHover: Color { palette.textControlHover.color }
    static var textSeparator: Color    { palette.textSeparator.color }
    static var onAccent: Color         { palette.onAccent.color }

    // Accents
    static var accent: Color        { palette.accent.color }
    static var accentTop: Color     { palette.accentTop.color }
    static var accentBottom: Color  { palette.accentBottom.color }
    static var accentSoft: Color    { palette.accentSoft.color }
    static var tabTop: Color        { palette.tabTop.color }
    static var tabBottom: Color     { palette.tabBottom.color }
    static var onTab: Color         { palette.onTab.color }
    static var promoTop: Color      { palette.promoTop.color }
    static var promoBottom: Color   { palette.promoBottom.color }
    static var promoInk: Color      { palette.promoInk.color }
    static var danger: Color        { palette.danger.color }
    static var dangerSoft: Color    { palette.dangerSoft.color }
    static var success: Color       { palette.success.color }
    static var successSoft: Color   { palette.successSoft.color }
    static var warning: Color       { palette.warning.color }
    static var amber: Color         { palette.amber.color }
    static var stripeBase: Color    { palette.stripeBase.color }
    static var stripeInk: Color     { palette.stripeInk.color }

    // Shape
    /// Every corner radius in the app goes through here, so Modernist can
    /// square the whole interface off with one token.
    static func radius(_ value: CGFloat) -> CGFloat { value * palette.radiusScale }
    static var isFlat: Bool { palette.radiusScale == 0 }
    static var elevated: Bool { palette.elevated }

    // Traffic-light dots (drawn by AppKit, kept here for reference/spacing)
    static let trafficLightInset: CGFloat = 78

    /// Modernist is set in Archivo where it is installed; both themes fall
    /// back to the system face, which keeps the layout identical either way.
    private static func resolved(_ name: String?, _ size: CGFloat, _ weight: Font.Weight) -> Font {
        if let name, NSFont(name: name, size: size) != nil {
            return .custom(name, fixedSize: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: .default)
    }

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        resolved(palette.bodyFontName, size, weight)
    }
    static func heading(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        resolved(palette.headingFontName, size, weight)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default).monospacedDigit()
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Categories (PAL / CAT_NAMES from the prototype)
// ─────────────────────────────────────────────────────────────────────────────

enum Category: String, CaseIterable, Identifiable, Sendable {
    case system, dev, media, docs, cache, downloads, apps, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:    return "System & Library"
        case .dev:       return "Developer"
        case .media:     return "Media"
        case .docs:      return "Documents"
        case .cache:     return "Caches & Junk"
        case .downloads: return "Downloads"
        case .apps:      return "Applications"
        case .other:     return "Other"
        }
    }

    /// Apple's system hues — one distinct colour per category.
    private var appleRGB: RGB {
        switch self {
        case .system:    return RGB("#0a84ff")
        case .dev:       return RGB("#30d158")
        case .media:     return RGB("#ff375f")
        case .docs:      return RGB("#bf5af2")
        case .cache:     return RGB("#64d2ff")
        case .downloads: return RGB("#ffd60a")
        case .apps:      return RGB("#ff9f0a")
        case .other:     return RGB("#8e8e93")
        }
    }

    /// Modernist has no colour to spend on taxonomy: everything sits on one
    /// ink ramp, and the accent is reserved for what is safe to remove.
    private var modernistRGB: RGB {
        isSafeToClean ? Theme.palette.accent : Category.inkRamp[modernistStep]
    }

    /// Position on the neutral ramp — the design's `CAT_STEP`.
    var modernistStep: Int {
        switch self {
        case .apps:      return 0
        case .system:    return 1
        case .media:     return 2
        case .docs:      return 3
        case .downloads: return 4
        case .other:     return 5
        case .dev, .cache: return 2
        }
    }

    /// `--color-neutral-900` down to `--color-neutral-400`.
    static let inkRamp: [RGB] = ["#2d2b2b", "#444141", "#605d5d",
                                 "#7d7979", "#9b9797", "#bab6b6"].map(RGB.init)

    var rgb: RGB { Theme.palette.solidTreemapFills ? modernistRGB : appleRGB }

    var color: Color { rgb.color }

    /// The prototype tags cache + dev material as "Safe" to remove.
    var isSafeToClean: Bool { self == .cache || self == .dev }
}

/// Heat ramp — `HEAT` + `heatColor(f)` from the prototype.
enum Heat {
    /// Apple: a full blue→red spectrum. Modernist: one accent, stepped from
    /// `--color-accent-300` to `--color-accent-700` (the design's `accStep`).
    private static let appleRamp: [RGB] =
        ["#3a7bd5", "#00c2a8", "#30d158", "#ffd60a", "#ff9f0a", "#ff453a"].map(RGB.init)
    private static let modernistRamp: [RGB] =
        ["#ffc4b8", "#ff9783", "#ff563c", "#ec3013", "#dd2b0f", "#ae1800"].map(RGB.init)

    static var ramp: [RGB] { Theme.palette.solidTreemapFills ? modernistRamp : appleRamp }

    static func color(_ fraction: Double) -> RGB {
        let ramp = Heat.ramp
        let t = min(1.0, pow(max(fraction, 0), 0.42)) * Double(ramp.count - 1)
        let i = min(ramp.count - 2, Int(floor(t)))
        return ramp[i].mixed(ramp[i + 1], t - Double(i))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Byte formatting  (fmt() in the prototype, decimal units like Finder)
// ─────────────────────────────────────────────────────────────────────────────

enum Bytes {
    static let KB: Int64 = 1_000
    static let MB: Int64 = 1_000_000
    static let GB: Int64 = 1_000_000_000
    static let TB: Int64 = 1_000_000_000_000

    static func format(_ value: Int64) -> String {
        let v = max(0, value)
        if v >= TB { return String(format: "%.2f TB", Double(v) / Double(TB)) }
        if v >= GB { return String(format: "%.2f GB", Double(v) / Double(GB)) }
        if v >= MB { return String(format: "%.0f MB", Double(v) / Double(MB)) }
        if v >= KB { return String(format: "%.0f KB", Double(v) / Double(KB)) }
        return "\(v) B"
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Model
// ─────────────────────────────────────────────────────────────────────────────

final class FileNode: Identifiable, Hashable, @unchecked Sendable {
    let url: URL
    let name: String
    var size: Int64
    let isDirectory: Bool
    let isPackage: Bool
    /// A stand-in block for the pruned tail of small files, so the treemap stays
    /// proportionally honest. Synthetic nodes are never trashable.
    let isSynthetic: Bool
    var category: Category
    var categoryIsExplicit: Bool
    var children: [FileNode]?
    weak var parent: FileNode?

    init(url: URL,
         name: String,
         size: Int64 = 0,
         isDirectory: Bool,
         isPackage: Bool = false,
         isSynthetic: Bool = false,
         category: Category = .other,
         categoryIsExplicit: Bool = false,
         parent: FileNode? = nil) {
        self.url = url
        self.name = name
        self.size = size
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isSynthetic = isSynthetic
        self.category = category
        self.categoryIsExplicit = categoryIsExplicit
        self.parent = parent
    }

    var id: ObjectIdentifier { ObjectIdentifier(self) }
    var isDrillable: Bool { (children?.isEmpty == false) }

    /// "Macintosh HD / Library / Caches" — the prototype's fullPath().
    var displayPath: String {
        var parts: [String] = []
        var cursor: FileNode? = self
        while let n = cursor { parts.insert(n.name, at: 0); cursor = n.parent }
        return parts.joined(separator: " / ")
    }

    func isDescendant(of other: FileNode) -> Bool {
        var cursor = parent
        while let n = cursor { if n === other { return true }; cursor = n.parent }
        return false
    }

    static func == (lhs: FileNode, rhs: FileNode) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Category classification
// ─────────────────────────────────────────────────────────────────────────────

enum Classifier {
    private static let devDirs: Set<String> = [
        "node_modules", "deriveddata", "coresimulator", "docker", ".docker",
        ".cargo", ".rustup", ".cocoapods", "pods", ".venv", "venv", "__pycache__",
        ".android", ".cursor", ".vscode", ".expo", ".next", ".angular", ".gem",
        ".pub-cache", ".pnpm-store", ".bundle", ".sdkman", ".rbenv", ".pyenv",
        "developer", "xcode", ".ollama", ".swiftpm", ".build", ".m2", ".stack"
    ]
    private static let cacheDirs: Set<String> = [
        ".npm", ".gradle", ".nvm", ".yarn", ".local", "_cacache", "caches", "cache",
        "logs", "tmp", "temp", "cachedata", "code cache", "gpucache", "crashpad"
    ]
    private static let mediaExts: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "webm", "flv", "wmv", "mpg", "mpeg",
        "jpg", "jpeg", "png", "heic", "heif", "gif", "tiff", "tif", "bmp", "webp",
        "raw", "cr2", "nef", "dng", "psd", "ai", "sketch",
        "mp3", "m4a", "wav", "aac", "flac", "aiff", "ogg",
        "photoslibrary", "imovielibrary", "fcpbundle", "aplibrary", "tvlibrary"
    ]
    private static let docExts: Set<String> = [
        "pdf", "doc", "docx", "pages", "key", "numbers", "xls", "xlsx", "ppt",
        "pptx", "txt", "md", "rtf", "csv", "epub", "json", "xml", "yaml", "yml"
    ]
    private static let archiveExts: Set<String> = [
        "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "iso", "pkg",
        "xip", "sparsebundle", "sparseimage", "img", "cdr"
    ]

    static func classify(url: URL, name: String, isDirectory: Bool, isPackage: Bool, parent: FileNode?) -> (Category, Bool) {
        let lower = name.lowercased()
        let ext = url.pathExtension.lowercased()
        let path = url.path
        let pathLower = path.lowercased()

        if ext == "app" || ext == "framework" || path.hasPrefix("/Applications") || path.hasPrefix("/System/Applications") {
            return (.apps, true)
        }
        if lower == "downloads" || pathLower.contains("/downloads/") {
            return (.downloads, true)
        }
        if devDirs.contains(lower) || pathLower.contains("/node_modules") || pathLower.contains("/deriveddata") || pathLower.contains("/coresimulator") {
            return (.dev, true)
        }
        if cacheDirs.contains(lower) || lower.hasSuffix(".cache") || lower.contains("cache") {
            return (.cache, true)
        }
        if mediaExts.contains(ext) { return (.media, true) }
        if archiveExts.contains(ext) { return (.other, true) }
        if docExts.contains(ext) { return (.docs, true) }
        if lower == "movies" || lower == "music" || lower == "pictures" {
            return (.media, true)
        }
        if lower == "documents" || lower == "desktop" || lower == "mobile documents" {
            return (.docs, true)
        }
        if path.hasPrefix("/System") || path.hasPrefix("/usr") || path.hasPrefix("/bin")
            || path.hasPrefix("/sbin") || path.hasPrefix("/private") || path.hasPrefix("/opt")
            || path == "/Library" || pathLower.hasSuffix("/library") {
            return (.system, true)
        }
        if let p = parent, p.categoryIsExplicit { return (p.category, false) }
        return (isDirectory ? (parent?.category ?? .other) : .other, false)
    }

    /// Post-order pass: a folder with no explicit marker inherits the category
    /// that dominates its contents, which is what makes the treemap read well.
    static func settleCategories(_ node: FileNode) {
        guard let kids = node.children, !kids.isEmpty else { return }
        for k in kids { settleCategories(k) }
        guard !node.categoryIsExplicit else { return }
        var totals: [Category: Int64] = [:]
        for k in kids { totals[k.category, default: 0] += k.size }
        if let winner = totals.max(by: { $0.value < $1.value })?.key {
            node.category = winner
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Background scanner
// ─────────────────────────────────────────────────────────────────────────────

/// Mutable state shared with the walker while it runs off the main thread.
final class ScanContext: @unchecked Sendable {
    private let onProgress: @Sendable (Int, String) -> Void
    private(set) var count = 0
    private var lastEmit = Date.distantPast

    init(onProgress: @escaping @Sendable (Int, String) -> Void) {
        self.onProgress = onProgress
    }

    func tick(_ path: String) {
        count &+= 1
        let now = Date()
        if now.timeIntervalSince(lastEmit) > 0.1 {
            lastEmit = now
            onProgress(count, path)
        }
    }
}

enum DiskScanner {

    static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isRegularFileKey,
        .nameKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey
    ]
    private static let sizeKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .isSymbolicLinkKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey
    ]

    /// Volume plumbing and firmlink shadows that would hang or double-count a "/" scan.
    static let skipPaths: Set<String> = [
        "/System/Volumes", "/Volumes", "/dev", "/net", "/home", "/cores",
        "/private/var/vm", "/private/var/folders", "/private/var/db/lockdown",
        "/.Spotlight-V100", "/.fseventsd", "/.DocumentRevisions-V100", "/.TemporaryItems"
    ]

    /// Nodes are materialised down to this depth; deeper bytes are still summed.
    static let treeDepth = 7
    /// Leaf files below this size are folded into a synthetic "other items" block.
    static let leafKeepThreshold: Int64 = 2 * Bytes.MB
    /// Hard ceiling on children per folder — keeps huge directories from exploding.
    static let maxChildren = 400

    static func fileSize(_ values: URLResourceValues?) -> Int64 {
        if let v = values?.totalFileAllocatedSize { return Int64(v) }
        if let v = values?.fileAllocatedSize { return Int64(v) }
        if let v = values?.fileSize { return Int64(v) }
        return 0
    }

    /// Fast byte sum with no node allocation, used below `treeDepth`.
    static func directoryBytes(_ url: URL, _ ctx: ScanContext) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(sizeKeys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        for case let child as URL in enumerator {
            if Task.isCancelled { break }
            let values = try? child.resourceValues(forKeys: sizeKeys)
            if values?.isSymbolicLink == true { continue }
            if values?.isRegularFile == true { total += fileSize(values) }
            ctx.tick(child.path)
        }
        return total
    }

    static func scan(url: URL, parent: FileNode?, depth: Int, ctx: ScanContext) -> FileNode? {
        if Task.isCancelled { return nil }

        let values = try? url.resourceValues(forKeys: Set(resourceKeys))
        if values?.isSymbolicLink == true { return nil }

        let isDirectory = values?.isDirectory ?? false
        let isPackage = values?.isPackage ?? false
        let name = values?.name ?? url.lastPathComponent
        let (category, explicit) = Classifier.classify(url: url, name: name,
                                                       isDirectory: isDirectory,
                                                       isPackage: isPackage,
                                                       parent: parent)

        let node = FileNode(url: url, name: name, isDirectory: isDirectory,
                            isPackage: isPackage, category: category,
                            categoryIsExplicit: explicit, parent: parent)

        // Plain files, and bundles (.app / .photoslibrary) which read as one item.
        if !isDirectory || isPackage {
            node.size = isDirectory ? directoryBytes(url, ctx) : fileSize(values)
            ctx.tick(url.path)
            return node
        }

        if skipPaths.contains(url.path) { return nil }

        if depth >= treeDepth {
            node.size = directoryBytes(url, ctx)
            return node
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: resourceKeys, options: []
        ) else {
            return node    // unreadable (permissions) — counts as zero, not a failure
        }

        var kept: [FileNode] = []
        var total: Int64 = 0
        for entry in entries {
            if Task.isCancelled { break }
            guard let child = scan(url: entry, parent: node, depth: depth + 1, ctx: ctx) else { continue }
            total += child.size
            if child.isDirectory || child.size >= leafKeepThreshold {
                kept.append(child)
            }
        }
        node.size = total

        kept.sort { $0.size > $1.size }
        if kept.count > maxChildren { kept = Array(kept.prefix(maxChildren)) }
        kept.removeAll { $0.size <= 0 }

        // Fold everything we pruned into one honest remainder block.
        let accounted = kept.reduce(Int64(0)) { $0 + $1.size }
        let remainder = total - accounted
        if remainder > max(leafKeepThreshold, total / 200) {
            let filler = FileNode(url: url, name: "… other items", size: remainder,
                                  isDirectory: false, isSynthetic: true,
                                  category: node.category, parent: node)
            kept.append(filler)
            kept.sort { $0.size > $1.size }
        }

        node.children = kept.isEmpty ? nil : kept
        return node
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Squarified treemap (direct port of squarify / buildBlocks)
// ─────────────────────────────────────────────────────────────────────────────

struct TreemapBlock: Identifiable {
    let id: ObjectIdentifier
    let node: FileNode
    let rect: CGRect
    let depth: Int
    let fraction: Double
    let isLeaf: Bool
    let accent: RGB
    let fill: Color
    /// The fill as components, so a view can choose legible ink for it.
    let blockRGB: RGB
}

enum Treemap {
    private struct Item { let node: FileNode; let value: Double }
    private struct Placed { let node: FileNode; let rect: CGRect }

    /// Shade ladder from the prototype — deeper rectangles sit further back.
    private static let shades: [Double] = [0.82, 0.72, 0.60, 0.48, 0.36, 0.28]
    private static let headerHeight: CGFloat = 19
    static let maxBlocks = 700

    private static func squarify(_ items: [Item], in rect: CGRect) -> [Placed] {
        var out: [Placed] = []
        var x = rect.minX, y = rect.minY, w = rect.width, h = rect.height
        var remaining = items.reduce(0.0) { $0 + $1.value }
        var i = 0

        func worst(_ row: [Item], _ sum: Double, _ rem: Double) -> Double {
            guard sum > 0, rem > 0 else { return .infinity }
            let frac = sum / rem
            let len = Double(w >= h ? w : h) * frac
            let other = Double(w >= h ? h : w)
            guard len > 0, other > 0 else { return .infinity }
            var ratio = 1.0
            for it in row {
                let seg = other * (it.value / sum)
                guard seg > 0 else { return .infinity }
                ratio = max(ratio, max(len / seg, seg / len))
            }
            return ratio
        }

        while i < items.count && remaining > 0 {
            var row: [Item] = []
            var sum = 0.0
            var best = Double.infinity
            var j = i

            while j < items.count {
                let candidateSum = sum + items[j].value
                let ratio = worst(row + [items[j]], candidateSum, remaining)
                if row.isEmpty || ratio <= best {
                    best = ratio
                    row.append(items[j])
                    sum = candidateSum
                    j += 1
                } else {
                    break
                }
            }
            guard sum > 0 else { break }

            let frac = sum / remaining
            if w >= h {
                let rw = w * CGFloat(frac)
                var ry = y
                for it in row {
                    let rh = h * CGFloat(it.value / sum)
                    out.append(Placed(node: it.node, rect: CGRect(x: x, y: ry, width: rw, height: rh)))
                    ry += rh
                }
                x += rw; w -= rw
            } else {
                let rh = h * CGFloat(frac)
                var rx = x
                for it in row {
                    let rw = w * CGFloat(it.value / sum)
                    out.append(Placed(node: it.node, rect: CGRect(x: rx, y: y, width: rw, height: rh)))
                    rx += rw
                }
                y += rh; h -= rh
            }
            remaining -= sum
            i = j
        }
        return out
    }

    static func layout(root: FileNode,
                       size: CGSize,
                       maxDepth: Int,
                       gap: CGFloat,
                       heat: Bool) -> [TreemapBlock] {
        guard size.width > 8, size.height > 8 else { return [] }
        let total = max(1.0, Double(root.size))
        let base = Theme.palette.windowBG
        let solid = Theme.palette.solidTreemapFills
        var out: [TreemapBlock] = []

        func walk(_ node: FileNode, _ rect: CGRect, _ depth: Int) {
            guard out.count < maxBlocks else { return }
            guard let children = node.children else { return }

            // Anything under ~0.05% of the frame is invisible noise; drop it.
            let floorValue = max(Double(root.size) * 0.0004, Double(Bytes.MB))
            let items = children
                .map { Item(node: $0, value: Double($0.size)) }
                .filter { $0.value > floorValue }
                .sorted { $0.value > $1.value }
            guard !items.isEmpty else { return }

            let header: CGFloat = (rect.height > 46 && rect.width > 64 && depth > 0) ? headerHeight : 0
            let inner = CGRect(x: rect.minX + gap,
                               y: rect.minY + header + gap,
                               width: max(1, rect.width - gap * 2),
                               height: max(1, rect.height - header - gap * 2))
            guard inner.width >= 8, inner.height >= 8 else { return }

            for placed in squarify(items, in: inner) {
                guard out.count < maxBlocks else { return }
                let n = placed.node
                let fraction = Double(n.size) / total
                let isLeaf = (n.children == nil) || (depth + 1 >= maxDepth) || n.isSynthetic
                let accent = heat ? Heat.color(fraction) : n.category.rgb
                let shade = shades[min(shades.count - 1, depth)]
                let fillRGB: RGB
                if solid {
                    // Modernist paints flat blocks: safe-to-clean material in
                    // the accent, everything else stepped down the ink ramp so
                    // depth reads without a second hue.
                    fillRGB = heat ? accent : Treemap.modernistFill(n.category, depth: depth, isLeaf: isLeaf)
                } else {
                    fillRGB = heat
                        ? base.mixed(accent, isLeaf ? 0.72 : 0.34)
                        : base.mixed(accent, isLeaf ? (1 - shade + 0.12) : (1 - shade))
                }

                out.append(TreemapBlock(id: n.id, node: n, rect: placed.rect, depth: depth,
                                        fraction: fraction, isLeaf: isLeaf,
                                        accent: accent, fill: fillRGB.color, blockRGB: fillRGB))
                if !isLeaf { walk(n, placed.rect, depth + 1) }
            }
        }

        walk(root, CGRect(origin: .zero, size: size), 0)
        return out
    }
}

extension Treemap {
    /// The design's `buildBlocks` colouring, ported: junk climbs the accent
    /// ramp with depth, everything else the neutral ramp.
    static let accentLadder: [RGB] = ["#ae1800", "#dd2b0f", "#ec3013",
                                      "#ff563c", "#ff9783", "#ffc4b8"].map(RGB.init)

    static func modernistFill(_ category: Category, depth: Int, isLeaf: Bool) -> RGB {
        if category.isSafeToClean {
            return isLeaf
                ? Theme.palette.accent
                : accentLadder[min(accentLadder.count - 1, depth)]
        }
        let step = category.modernistStep + (isLeaf ? 1 : 0) + depth / 2
        return Category.inkRamp[min(Category.inkRamp.count - 1, step)]
    }

    /// Ink that stays legible on a given block fill.
    static func ink(on fill: RGB) -> Color {
        let luminance = 0.2126 * fill.r + 0.7152 * fill.g + 0.0722 * fill.b
        return luminance > 0.59 ? Theme.palette.textPrimary.color : Theme.palette.windowBG.color
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Volume statistics
// ─────────────────────────────────────────────────────────────────────────────

struct VolumeStats: Equatable {
    var total: Int64 = 0
    var free: Int64 = 0
    var used: Int64 { max(0, total - free) }
    var usedPercent: Int { total > 0 ? Int((Double(used) / Double(total) * 100).rounded()) : 0 }

    static func current() -> VolumeStats {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return VolumeStats() }
        let total = Int64(v.volumeTotalCapacity ?? 0)
        let free = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
        return VolumeStats(total: total, free: free)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Dev-bloat filters (the sidebar chips)
// ─────────────────────────────────────────────────────────────────────────────

struct BloatFilter: Identifiable, Hashable {
    let id: String
    let name: String
    let matches: @Sendable (FileNode) -> Bool

    static func == (lhs: BloatFilter, rhs: BloatFilter) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    static let all: [BloatFilter] = [
        BloatFilter(id: "node_modules", name: "node_modules") { $0.name == "node_modules" },
        BloatFilter(id: "xcode", name: "Xcode") {
            let p = $0.url.path
            return p.contains("DerivedData") || $0.name == "Archives" || p.contains("Xcode/iOS DeviceSupport")
        },
        BloatFilter(id: "gradle", name: "Gradle") { $0.name == ".gradle" || $0.url.path.contains("/.gradle/") },
        BloatFilter(id: "docker", name: "Docker") { $0.name.lowercased().contains("docker") },
        BloatFilter(id: "simulators", name: "Simulators") { $0.url.path.contains("CoreSimulator") },
        BloatFilter(id: "images", name: "Disk Images") {
            ["dmg", "iso", "img", "xip", "sparsebundle", "sparseimage"].contains($0.url.pathExtension.lowercased())
        },
        BloatFilter(id: "archives", name: "Archives") {
            ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar"].contains($0.url.pathExtension.lowercased())
        }
    ]
}

struct TrashRecord: Identifiable {
    let id = UUID()
    let node: FileNode
    let parent: FileNode
    let index: Int
    let originalURL: URL
    let trashURL: URL?
    let size: Int64
    let date = Date()
}

struct CategoryTotal: Identifiable {
    var id: String { category.rawValue }
    let category: Category
    let bytes: Int64
}

enum ViewMode: String { case treemap, list }

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Scan engine
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class ScanEngine: ObservableObject {

    // Tree + navigation
    @Published private(set) var root: FileNode?
    @Published private(set) var path: [FileNode] = []
    @Published private(set) var blocks: [TreemapBlock] = []
    @Published private(set) var categoryTotals: [CategoryTotal] = []

    // Scan state
    @Published private(set) var isScanning = false
    @Published private(set) var scannedItems = 0
    @Published private(set) var currentScanPath = ""
    @Published private(set) var lastScanDuration: TimeInterval = 0
    @Published var errorMessage: String?

    // Presentation state
    @Published var viewMode: ViewMode = .treemap
    @Published var heatMode = false
    @Published var selectedCategory: Category?
    @Published var activeFilters: Set<String> = []
    @Published var searchText = ""
    @Published var maxDepth: Int = 3
    @Published var gap: CGFloat = 2
    @Published var showSizes = true

    // Cleaning
    @Published private(set) var trashRecords: [TrashRecord] = []
    @Published private(set) var reclaimed: Int64 = 0

    // Volume
    @Published private(set) var volume = VolumeStats.current()

    // Hover (drives the status bar)
    @Published var hoveredNode: FileNode?

    private var canvasSize: CGSize = .zero
    private var scanTask: Task<Void, Never>?

    // MARK: Derived

    var currentNode: FileNode? { path.last ?? root }

    var breadcrumbs: [FileNode] {
        guard let root else { return [] }
        return [root] + path
    }

    var canGoUp: Bool { !path.isEmpty }

    var nodeCountLabel: String {
        guard let node = currentNode else { return "No scan yet" }
        let n = node.children?.count ?? 0
        return "\(n) items · \(Bytes.format(node.size))"
    }

    var statusText: String {
        if isScanning {
            return "Scanning… \(scannedItems.formatted()) items · \(currentScanPath)"
        }
        if let hovered = hoveredNode {
            return "\(hovered.displayPath)  —  \(Bytes.format(hovered.size))"
        }
        if let node = currentNode {
            let secs = String(format: "%.1fs", lastScanDuration)
            return "Ready · \(Bytes.format(node.size)) mapped in \(node.name) · \(scannedItems.formatted()) items in \(secs)"
        }
        return "Ready · choose a scan to begin"
    }

    var statusColor: Color {
        if isScanning { return Theme.accent }
        if let hovered = hoveredNode { return hovered.category.color }
        return Theme.textSeparator
    }

    var reclaimedLabel: String { Bytes.format(reclaimed) }

    /// Rows for the list view: children of the current node, or bloat hits /
    /// search hits gathered across the whole tree.
    var listRows: [FileNode] {
        if !activeFilters.isEmpty { return bloatMatches() }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty { return searchMatches(query) }
        return (currentNode?.children ?? []).sorted { $0.size > $1.size }
    }

    var listRowsMaxSize: Int64 { max(1, listRows.first?.size ?? 1) }

    var listHeading: String? {
        if !activeFilters.isEmpty {
            let names = BloatFilter.all.filter { activeFilters.contains($0.id) }.map(\.name)
            let total = listRows.reduce(Int64(0)) { $0 + $1.size }
            return "Bloat matches · \(names.joined(separator: ", ")) · \(Bytes.format(total))"
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty { return "Search “\(query)” · \(listRows.count) results" }
        return nil
    }

    // MARK: Scanning

    func chooseFolderAndScan() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder to analyse"
        panel.message = "DrivePurge will map every file inside this folder."
        panel.prompt = "Scan"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, let url = panel.url else { return }
        startScan(url)
    }

    func scanHome() { startScan(FileManager.default.homeDirectoryForCurrentUser) }
    func scanRoot() { startScan(URL(fileURLWithPath: "/")) }
    func scanApplications() { startScan(URL(fileURLWithPath: "/Applications")) }

    func startScan(_ url: URL) {
        scanTask?.cancel()
        isScanning = true
        scannedItems = 0
        currentScanPath = url.path
        errorMessage = nil
        hoveredNode = nil
        path = []
        blocks = []
        volume = VolumeStats.current()
        let started = Date()

        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let engine = self else { return }
            let context = ScanContext { count, scanning in
                Task { @MainActor in engine.applyProgress(count: count, path: scanning) }
            }
            let tree = DiskScanner.scan(url: url, parent: nil, depth: 0, ctx: context)
            if Task.isCancelled {
                await MainActor.run { engine.isScanning = false }
                return
            }
            if let tree {
                Classifier.settleCategories(tree)
            }
            let items = context.count
            let elapsed = Date().timeIntervalSince(started)
            await MainActor.run { engine.finishScan(tree: tree, items: items, elapsed: elapsed) }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    private func applyProgress(count: Int, path: String) {
        guard isScanning else { return }
        scannedItems = count
        currentScanPath = path
    }

    private func finishScan(tree: FileNode?, items: Int, elapsed: TimeInterval) {
        isScanning = false
        scannedItems = items
        lastScanDuration = elapsed
        currentScanPath = ""
        guard let tree else {
            errorMessage = "That location could not be read. Grant Full Disk Access in System Settings › Privacy & Security to scan protected folders."
            return
        }
        root = tree
        path = []
        recomputeCategories()
        rebuildBlocks()
    }

    // MARK: Layout

    func setCanvasSize(_ size: CGSize) {
        guard abs(size.width - canvasSize.width) > 1 || abs(size.height - canvasSize.height) > 1 else { return }
        canvasSize = size
        rebuildBlocks()
    }

    func rebuildBlocks() {
        guard let node = currentNode, canvasSize.width > 8, canvasSize.height > 8 else {
            blocks = []
            return
        }
        blocks = Treemap.layout(root: node, size: canvasSize,
                                maxDepth: maxDepth, gap: gap, heat: heatMode)
    }

    func isDimmed(_ node: FileNode) -> Bool {
        if let selectedCategory, node.category != selectedCategory { return true }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty, !node.name.localizedCaseInsensitiveContains(query) { return true }
        return false
    }

    // MARK: Navigation

    func drill(into node: FileNode) {
        guard node.isDrillable, !node.isSynthetic else { return }
        guard let root else { return }
        var chain: [FileNode] = []
        var cursor: FileNode? = node
        while let n = cursor, n !== root { chain.insert(n, at: 0); cursor = n.parent }
        path = chain
        hoveredNode = nil
        rebuildBlocks()
    }

    func goUp() {
        guard !path.isEmpty else { return }
        path.removeLast()
        hoveredNode = nil
        rebuildBlocks()
    }

    func goTo(breadcrumbIndex index: Int) {
        path = Array(path.prefix(max(0, index)))
        hoveredNode = nil
        rebuildBlocks()
    }

    func toggleCategory(_ category: Category) {
        selectedCategory = (selectedCategory == category) ? nil : category
        rebuildBlocks()
    }

    func toggleHeat() {
        heatMode.toggle()
        rebuildBlocks()
    }

    func toggleFilter(_ filter: BloatFilter) {
        if activeFilters.contains(filter.id) {
            activeFilters.remove(filter.id)
        } else {
            activeFilters.insert(filter.id)
            viewMode = .list
        }
    }

    // MARK: Aggregation

    private func recomputeCategories() {
        guard let root else { categoryTotals = []; return }
        var totals: [Category: Int64] = [:]
        for child in root.children ?? [] {
            totals[child.category, default: 0] += child.size
        }
        categoryTotals = totals
            .map { CategoryTotal(category: $0.key, bytes: $0.value) }
            .sorted { $0.bytes > $1.bytes }
    }

    private func bloatMatches() -> [FileNode] {
        guard let root else { return [] }
        let filters = BloatFilter.all.filter { activeFilters.contains($0.id) }
        guard !filters.isEmpty else { return [] }
        var hits: [FileNode] = []

        func walk(_ node: FileNode) {
            if hits.count > 400 { return }
            if !node.isSynthetic, filters.contains(where: { $0.matches(node) }) {
                hits.append(node)
                return   // do not descend into a folder already reported
            }
            for child in node.children ?? [] { walk(child) }
        }
        walk(root)
        return hits.sorted { $0.size > $1.size }
    }

    private func searchMatches(_ query: String) -> [FileNode] {
        guard let node = currentNode else { return [] }
        var hits: [FileNode] = []
        func walk(_ n: FileNode) {
            if hits.count > 400 { return }
            for child in n.children ?? [] {
                if !child.isSynthetic, child.name.localizedCaseInsensitiveContains(query) {
                    hits.append(child)
                }
                walk(child)
            }
        }
        walk(node)
        return hits.sorted { $0.size > $1.size }
    }

    // MARK: Safe clean routine

    /// Confirms, then moves the node to the system Trash with FileManager.trashItem.
    func clean(_ node: FileNode) {
        // The single paywall in the app. Scanning, drilling and the list view
        // stay free forever; removing files is what a licence buys.
        guard LicenseStore.shared.canClean else {
            LicenseStore.shared.presentSheet()
            return
        }

        guard !node.isSynthetic else { return }
        guard let parent = node.parent,
              let index = parent.children?.firstIndex(where: { $0 === node }) else { return }

        let alert = NSAlert()
        alert.alertStyle = node.category.isSafeToClean ? .warning : .critical
        alert.messageText = "Move “\(node.name)” to the Trash?"
        alert.informativeText = """
        \(node.url.path)

        \(Bytes.format(node.size)) will be moved to the Trash. \
        \(node.category.isSafeToClean
            ? "This looks like regenerable developer cache — usually safe to remove."
            : "This is not a cache. Make sure you have a copy before continuing.")
        """
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var trashURL: NSURL?
        do {
            try FileManager.default.trashItem(at: node.url, resultingItemURL: &trashURL)
        } catch {
            errorMessage = "Could not trash “\(node.name)”: \(error.localizedDescription)"
            return
        }

        let record = TrashRecord(node: node, parent: parent, index: index,
                                 originalURL: node.url,
                                 trashURL: trashURL as URL?,
                                 size: node.size)
        detach(node, from: parent, at: index)
        trashRecords.append(record)
        reclaimed += record.size
        volume = VolumeStats.current()
        hoveredNode = nil
        rebuildBlocks()
        recomputeCategories()
    }

    /// Puts everything this session trashed back where it came from.
    func restoreAll() {
        var failures: [String] = []
        for record in trashRecords.reversed() {
            guard let trashURL = record.trashURL else {
                failures.append(record.node.name)
                continue
            }
            do {
                try FileManager.default.moveItem(at: trashURL, to: record.originalURL)
                reattach(record)
            } catch {
                failures.append(record.node.name)
            }
        }
        trashRecords.removeAll { record in !failures.contains(record.node.name) }
        reclaimed = trashRecords.reduce(Int64(0)) { $0 + $1.size }
        if !failures.isEmpty {
            errorMessage = "Could not restore: \(failures.joined(separator: ", ")). They are still in the Trash."
        }
        volume = VolumeStats.current()
        recomputeCategories()
        rebuildBlocks()
    }

    func revealTrashInFinder() {
        let trash = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: false)
        NSWorkspace.shared.open(trash ?? URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"))
    }

    func revealInFinder(_ node: FileNode) {
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    private func detach(_ node: FileNode, from parent: FileNode, at index: Int) {
        parent.children?.remove(at: index)
        if parent.children?.isEmpty == true { parent.children = nil }
        var cursor: FileNode? = parent
        while let n = cursor { n.size = max(0, n.size - node.size); cursor = n.parent }
        if path.contains(where: { $0 === node || $0.isDescendant(of: node) }) {
            path = path.prefix { $0 !== node && !$0.isDescendant(of: node) }.map { $0 }
        }
    }

    private func reattach(_ record: TrashRecord) {
        let parent = record.parent
        var kids = parent.children ?? []
        kids.insert(record.node, at: min(record.index, kids.count))
        parent.children = kids
        var cursor: FileNode? = parent
        while let n = cursor { n.size += record.size; cursor = n.parent }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Small reusable pieces
// ─────────────────────────────────────────────────────────────────────────────

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Theme.font(10.5, .semibold))
            .kerning(1.3)
            .foregroundColor(Theme.textLabel)
    }
}

struct FlatButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// Track bar used by the category rows and the list view.
struct MiniBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 3
    var gradient = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Theme.radius(height / 2)).fill(Theme.trackBG)
                RoundedRectangle(cornerRadius: Theme.radius(height / 2))
                    .fill(gradient
                          ? AnyShapeStyle(LinearGradient(colors: [color.opacity(0.55), color],
                                                         startPoint: .leading, endPoint: .trailing))
                          : AnyShapeStyle(color))
                    .frame(width: max(0, geo.size.width * CGFloat(min(max(fraction, 0), 1))))
            }
        }
        .frame(height: height)
    }
}

struct DiagonalStripes: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.stripeBase))
            var x: CGFloat = -size.height
            while x < size.width + size.height {
                var line = Path()
                line.move(to: CGPoint(x: x, y: size.height))
                line.addLine(to: CGPoint(x: x + size.height, y: 0))
                context.stroke(line, with: .color(Theme.stripeInk), lineWidth: 4)
                x += 8
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Title bar
// ─────────────────────────────────────────────────────────────────────────────

/// Two-up switch between the Apple-native skin and the Modernist one.
struct ThemeSwitch: View {
    @ObservedObject var store: ThemeStore

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTheme.allCases) { theme in
                let active = store.theme == theme
                Button { store.select(theme) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: theme.symbol).font(.system(size: 10, weight: .medium))
                        Text(theme.shortTitle).font(Theme.font(12, active ? .semibold : .regular))
                    }
                    .foregroundColor(active ? Theme.onTab : Theme.textControl)
                    .frame(height: 25)
                    .padding(.horizontal, 9)
                    .background(RoundedRectangle(cornerRadius: Theme.radius(5))
                        .fill(active ? Theme.tabTop : .clear))
                }
                .buttonStyle(FlatButtonStyle())
                .help("Switch the whole app to the \(theme.title) theme")
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Theme.radius(7)).fill(Theme.chipBG))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius(7))
            .strokeBorder(Theme.borderChip, lineWidth: Theme.ruleWidth))
    }
}

struct TitleBar: View {
    @ObservedObject var engine: ScanEngine
    @ObservedObject var themeStore: ThemeStore
    @ObservedObject var licenseStore: LicenseStore
    @FocusState.Binding var searchFocused: Bool
    @State private var hoverHeat = false
    @State private var hoverApps = false
    @State private var hoverUpgrade = false

    var body: some View {
        HStack(spacing: 16) {
            // Space reserved for the real window traffic lights.
            Spacer().frame(width: Theme.trafficLightInset - 16)

            HStack(spacing: 8) {
                Image(systemName: "externaldrive")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.accent)
                Text("DrivePurge")
                    .font(Theme.font(14, .semibold))
                    .kerning(-0.2)
                    .foregroundColor(Theme.textPrimary)
            }

            Spacer(minLength: 12)

            // Search
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Theme.radius(8)).fill(Theme.inputBG)
                RoundedRectangle(cornerRadius: Theme.radius(8)).strokeBorder(
                    searchFocused ? Theme.accent.opacity(0.7) : Theme.borderInput, lineWidth: Theme.ruleWidth)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.textDim)
                    TextField("Search files and folders…", text: $engine.searchText)
                        .textFieldStyle(.plain)
                        .font(Theme.font(13))
                        .foregroundColor(Theme.textPrimary)
                        .focused($searchFocused)
                        .onSubmit { engine.rebuildBlocks() }
                        .onChange(of: engine.searchText) { _ in engine.rebuildBlocks() }
                    if engine.searchText.isEmpty {
                        Text("⌘F")
                            .font(Theme.font(11))
                            .foregroundColor(Theme.textDim)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: Theme.radius(4)).strokeBorder(Theme.borderInput, lineWidth: Theme.ruleWidth))
                    } else {
                        Button {
                            engine.searchText = ""
                            engine.rebuildBlocks()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textDim)
                        }
                        .buttonStyle(FlatButtonStyle())
                    }
                }
                .padding(.horizontal, 11)
            }
            .frame(height: 33)
            .frame(maxWidth: 520)

            Spacer(minLength: 12)

            HStack(spacing: 6) {
                ThemeSwitch(store: themeStore)

                Button { engine.scanApplications() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.grid.2x2").font(.system(size: 11, weight: .medium))
                        Text("Apps").font(Theme.font(12.5))
                    }
                    .foregroundColor(hoverApps ? Theme.textControlHover : Theme.textControl)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: Theme.radius(7)).fill(Theme.chipBG))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius(7))
                        .strokeBorder(hoverApps ? Theme.borderControlHover : Theme.borderChip, lineWidth: Theme.ruleWidth))
                }
                .buttonStyle(FlatButtonStyle())
                .onHover { hoverApps = $0 }
                .help("Scan /Applications")

                Button { engine.toggleHeat() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: engine.heatMode ? "flame.fill" : "circle.lefthalf.filled")
                            .font(.system(size: 11, weight: .medium))
                        Text(engine.heatMode ? "Heat" : "Category").font(Theme.font(12.5))
                    }
                    .foregroundColor(hoverHeat ? Theme.textControlHover : Theme.textControl)
                    .frame(height: 29)
                    .padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: Theme.radius(7)).fill(Theme.chipBG))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius(7))
                        .strokeBorder(hoverHeat ? Theme.borderControlHover : Theme.borderChip, lineWidth: Theme.ruleWidth))
                }
                .buttonStyle(FlatButtonStyle())
                .onHover { hoverHeat = $0 }
                .help("Toggle between category colours and a size heat ramp")

                Button { licenseStore.presentSheet() } label: {
                    HStack(spacing: 6) {
                        if licenseStore.canClean {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        Text(licenseStore.purchaseButtonTitle)
                            .font(Theme.font(12.5, .bold))
                    }
                    .foregroundColor(licenseStore.canClean ? Theme.textControl : Theme.promoInk)
                    .frame(height: 29)
                    .padding(.horizontal, 14)
                    .background {
                        if licenseStore.canClean {
                            RoundedRectangle(cornerRadius: Theme.radius(7)).fill(Theme.chipBG)
                                .overlay(RoundedRectangle(cornerRadius: Theme.radius(7))
                                    .strokeBorder(Theme.borderChip, lineWidth: Theme.ruleWidth))
                        } else {
                            RoundedRectangle(cornerRadius: Theme.radius(7))
                                .fill(LinearGradient(colors: [Theme.promoTop, Theme.promoBottom],
                                                     startPoint: .top, endPoint: .bottom))
                        }
                    }
                    .brightness(hoverUpgrade ? 0.06 : 0)
                }
                .buttonStyle(FlatButtonStyle())
                .onHover { hoverUpgrade = $0 }
                .help(licenseStore.canClean ? "View your licence" : "Unlock cleaning")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(
            LinearGradient(colors: [Theme.titleBarTop, Theme.titleBarBottom],
                           startPoint: .top, endPoint: .bottom)
        )
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: Theme.ruleWidth) }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Sidebar
// ─────────────────────────────────────────────────────────────────────────────

struct ScanActionButton: View {
    enum Kind { case primary, secondary }
    let kind: Kind
    let title: String
    let icon: String
    var trailingIcon: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 13, weight: .medium))
                Text(title).font(Theme.font(13.5, kind == .primary ? .semibold : .medium))
                if let trailingIcon {
                    Image(systemName: trailingIcon).font(.system(size: 10, weight: .bold)).opacity(0.85)
                }
            }
            .foregroundColor(kind == .primary ? Theme.onAccent : Theme.textBody)
            .frame(maxWidth: .infinity)
            .frame(height: kind == .primary ? 42 : 40)
            .background {
                if kind == .primary {
                    RoundedRectangle(cornerRadius: Theme.radius(9))
                        .fill(LinearGradient(colors: [Theme.accentTop, Theme.accentBottom],
                                             startPoint: .top, endPoint: .bottom))
                        .shadow(color: Theme.accentBottom.opacity(0.35), radius: 9, x: 0, y: 6)
                } else {
                    RoundedRectangle(cornerRadius: Theme.radius(9))
                        .fill(hovering ? Theme.controlHoverBG : Theme.controlBG)
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius(9))
                            .strokeBorder(hovering ? Theme.borderControlHover : Theme.borderControl, lineWidth: Theme.ruleWidth))
                }
            }
            .brightness(kind == .primary && hovering ? 0.06 : 0)
        }
        .buttonStyle(FlatButtonStyle())
        .onHover { hovering = $0 }
    }
}

struct DiskGauge: View {
    let stats: VolumeStats
    let reclaimed: Int64

    private var gaugeColor: Color {
        let p = stats.usedPercent
        return p > 85 ? Theme.dangerSoft : (p > 65 ? Theme.warning : Theme.success)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "DISK STORAGE")
                .padding(.bottom, 14)

            HStack(spacing: 16) {
                ZStack {
                    Circle().strokeBorder(Theme.gaugeTrack, lineWidth: 9)
                    Circle()
                        .inset(by: 4.5)
                        .trim(from: 0, to: CGFloat(stats.usedPercent) / 100)
                        .stroke(gaugeColor, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.4), value: stats.usedPercent)
                    VStack(spacing: 1) {
                        Image(systemName: "internaldrive")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textDim)
                        Text("\(stats.usedPercent)%")
                            .font(Theme.font(15, .bold))
                            .kerning(-0.4)
                            .foregroundColor(Theme.textPrimary)
                    }
                }
                .frame(width: 86, height: 86)

                VStack(spacing: 7) {
                    statRow("Total", Bytes.format(stats.total), Theme.textPrimary)
                    statRow("Used", Bytes.format(stats.used), Theme.dangerSoft)
                    statRow("Free", Bytes.format(stats.free), Theme.success)
                }
            }

            // Used / reclaimed stacked bar
            GeometryReader { geo in
                let total = max(1.0, Double(stats.total))
                let usedW = geo.size.width * CGFloat(Double(stats.used) / total)
                let reclaimedW = geo.size.width * CGFloat(Double(reclaimed) / total)
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(LinearGradient(colors: [Theme.dangerSoft, Theme.danger],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(0, usedW))
                    DiagonalStripes().frame(width: max(0, reclaimedW))
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 7)
            .background(Theme.railBG)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius(4)))
            .padding(.top, 14)
        }
    }

    private func statRow(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack {
            Text(label).font(Theme.font(12.5)).foregroundColor(Theme.textMuted)
            Spacer()
            Text(value).font(Theme.mono(12.5, .semibold)).foregroundColor(color)
        }
    }
}

struct CategoryRow: View {
    let total: CategoryTotal
    let maxBytes: Int64
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: Theme.radius(2))
                    .fill(total.category.color)
                    .frame(width: 9, height: 9)
                    .shadow(color: total.category.rgb.color(0.5), radius: 5)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(total.category.title)
                            .font(Theme.font(12.5, .medium))
                            .foregroundColor(Theme.textBody)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(Bytes.format(total.bytes))
                            .font(Theme.mono(11.5))
                            .foregroundColor(Theme.textMuted)
                    }
                    MiniBar(fraction: Double(total.bytes) / Double(max(1, maxBytes)),
                            color: total.category.color)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: Theme.radius(7))
                .fill(selected ? Theme.rowSelectedBG : (hovering ? Theme.rowHoverBG : .clear)))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius(7))
                .strokeBorder(selected ? Theme.borderSelected : .clear, lineWidth: Theme.ruleWidth))
        }
        .buttonStyle(FlatButtonStyle())
        .onHover { hovering = $0 }
    }
}

struct SidebarView: View {
    @ObservedObject var engine: ScanEngine

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 0) {

                // Scan actions
                VStack(spacing: 9) {
                    ScanActionButton(kind: .primary, title: "Scan Full Mac",
                                     icon: "externaldrive.fill", trailingIcon: "lock.fill") {
                        engine.scanRoot()
                    }
                    ScanActionButton(kind: .secondary, title: "Scan Home", icon: "house") {
                        engine.scanHome()
                    }
                    ScanActionButton(kind: .secondary, title: "Choose Folder", icon: "folder") {
                        engine.chooseFolderAndScan()
                    }
                    if engine.isScanning {
                        Button { engine.cancelScan() } label: {
                            HStack(spacing: 7) {
                                ProgressView().controlSize(.small).scaleEffect(0.7)
                                Text("Stop scanning").font(Theme.font(12.5, .medium))
                                    .foregroundColor(Theme.dangerSoft)
                            }
                            .frame(maxWidth: .infinity).frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: Theme.radius(8))
                                .fill(Theme.danger.opacity(0.12)))
                            .overlay(RoundedRectangle(cornerRadius: Theme.radius(8))
                                .strokeBorder(Theme.danger.opacity(0.35), lineWidth: Theme.ruleWidth))
                        }
                        .buttonStyle(FlatButtonStyle())
                    }
                }
                .padding(14)
                divider

                // Disk gauge
                VStack(alignment: .leading, spacing: 0) {
                    DiskGauge(stats: engine.volume, reclaimed: engine.reclaimed)
                    if engine.reclaimed > 0 {
                        HStack {
                            HStack(spacing: 7) {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                                Text("\(engine.reclaimedLabel) queued")
                                    .font(Theme.font(12.5, .semibold))
                            }
                            .foregroundColor(Theme.success)
                            Spacer()
                            Button { engine.restoreAll() } label: {
                                Text("Restore")
                                    .font(Theme.font(11.5))
                                    .foregroundColor(Theme.textControl)
                                    .padding(.horizontal, 10).frame(height: 24)
                                    .background(RoundedRectangle(cornerRadius: Theme.radius(6)).fill(Theme.chipBG))
                                    .overlay(RoundedRectangle(cornerRadius: Theme.radius(6))
                                        .strokeBorder(Theme.borderChip, lineWidth: Theme.ruleWidth))
                            }
                            .buttonStyle(FlatButtonStyle())
                            .help("Move everything this session trashed back to its original location")
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: Theme.radius(8)).fill(Theme.success.opacity(0.09)))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius(8))
                            .strokeBorder(Theme.success.opacity(0.28), lineWidth: Theme.ruleWidth))
                        .padding(.top, 12)
                    }
                }
                .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 14)
                divider

                // Trash row
                HStack {
                    HStack(spacing: 9) {
                        Image(systemName: "trash").font(.system(size: 12)).foregroundColor(Theme.textMuted)
                        Text("Trash").font(Theme.font(13)).foregroundColor(Theme.textBody)
                        Text("\(engine.trashRecords.count) item\(engine.trashRecords.count == 1 ? "" : "s")")
                            .font(Theme.font(13, .semibold))
                            .foregroundColor(engine.trashRecords.isEmpty ? Theme.textFaint : Theme.amber)
                    }
                    Spacer()
                    Button { engine.revealTrashInFinder() } label: {
                        Text("Open")
                            .font(Theme.font(11.5, .semibold))
                            .foregroundColor(Theme.dangerSoft)
                            .padding(.horizontal, 11).frame(height: 25)
                            .background(RoundedRectangle(cornerRadius: Theme.radius(6)).fill(Theme.danger.opacity(0.12)))
                            .overlay(RoundedRectangle(cornerRadius: Theme.radius(6))
                                .strokeBorder(Theme.danger.opacity(0.35), lineWidth: Theme.ruleWidth))
                    }
                    .buttonStyle(FlatButtonStyle())
                    .help("Reveal the system Trash in Finder")
                }
                .padding(14)
                divider

                // Categories
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel(text: "CATEGORIES").padding(.bottom, 12)
                    if engine.categoryTotals.isEmpty {
                        Text("Run a scan to break this Mac down by category.")
                            .font(Theme.font(12))
                            .foregroundColor(Theme.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        VStack(spacing: 3) {
                            let maxBytes = engine.categoryTotals.first?.bytes ?? 1
                            ForEach(engine.categoryTotals) { total in
                                CategoryRow(total: total,
                                            maxBytes: maxBytes,
                                            selected: engine.selectedCategory == total.category) {
                                    engine.toggleCategory(total.category)
                                }
                            }
                        }
                    }
                }
                .padding(14)
                divider

                // Dev bloat filters
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: "DEV BLOAT FILTERS")
                    FlowLayout(spacing: 6) {
                        ForEach(BloatFilter.all) { filter in
                            let on = engine.activeFilters.contains(filter.id)
                            Button { engine.toggleFilter(filter) } label: {
                                Text(filter.name)
                                    .font(Theme.font(11.5, on ? .semibold : .regular))
                                    .foregroundColor(on ? Theme.accentSoft : Theme.textMuted)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(RoundedRectangle(cornerRadius: Theme.radius(6))
                                        .fill(on ? Theme.accent.opacity(0.16) : Theme.chipBG))
                                    .overlay(RoundedRectangle(cornerRadius: Theme.radius(6))
                                        .strokeBorder(on ? Theme.accent.opacity(0.5) : Theme.borderChip, lineWidth: Theme.ruleWidth))
                            }
                            .buttonStyle(FlatButtonStyle())
                        }
                    }
                }
                .padding(14)

                Spacer(minLength: 12)

                Rectangle().fill(Theme.borderSoft).frame(height: Theme.ruleWidth)
                HStack {
                    Text("DrivePurge v3.0.0 · Native")
                        .font(Theme.font(11.5))
                        .foregroundColor(Theme.textFaint)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }
        }
        .background(Theme.sidebarBG)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.borderSidebar).frame(width: Theme.ruleWidth) }
    }

    private var divider: some View {
        Rectangle().fill(Theme.borderSoft).frame(height: Theme.ruleWidth)
    }
}

/// Wrapping chip row — the CSS `flex-wrap` in the design.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 260
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Treemap canvas
// ─────────────────────────────────────────────────────────────────────────────

struct TreemapBlockView: View {
    let block: TreemapBlock
    let hovered: Bool
    let dimmed: Bool
    let showSize: Bool
    let onHover: (Bool) -> Void
    let onOpen: () -> Void
    let onClean: () -> Void

    private var showLabel: Bool { block.rect.width > 44 && block.rect.height > 15 }
    private var showSizeLabel: Bool { showSize && block.rect.width > 118 && block.rect.height > 15 }
    private var showActions: Bool { hovered && block.rect.width > 74 && block.rect.height > 30 }

    /// Apple tints the rectangle's own accent for its edge; Modernist cuts a
    /// paper gutter between blocks and inks the one under the pointer.
    private var borderColor: Color {
        if Theme.palette.solidTreemapFills {
            return hovered ? Theme.border : Theme.palette.treemapGridline.color
        }
        return hovered ? .white : block.accent.color(block.isLeaf ? 0.42 : 0.30)
    }

    /// Legible ink for whatever this block is filled with.
    private var ink: Color {
        Theme.palette.solidTreemapFills ? Treemap.ink(on: block.blockRGB) : .white
    }

    private var labelShadow: Color {
        Theme.palette.solidTreemapFills ? .clear : .black.opacity(0.6)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Theme.radius(3)).fill(block.fill)
            RoundedRectangle(cornerRadius: Theme.radius(3)).strokeBorder(borderColor, lineWidth: Theme.ruleWidth)

            if showLabel {
                HStack(spacing: 8) {
                    Text(block.node.name)
                        .font(Theme.font(block.depth == 0 ? 11.5 : 10.5,
                                         block.depth == 0 ? .semibold : .medium))
                        .kerning(-0.1)
                        .foregroundColor(ink.opacity(0.94))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .shadow(color: labelShadow, radius: 1, x: 0, y: 1)
                    if showSizeLabel {
                        Spacer(minLength: 4)
                        Text(Bytes.format(block.node.size))
                            .font(Theme.mono(10.5))
                            .foregroundColor(ink.opacity(0.7))
                            .lineLimit(1)
                            .shadow(color: labelShadow, radius: 1, x: 0, y: 1)
                    }
                }
                .padding(.horizontal, 5)
                .padding(.vertical, block.isLeaf ? 3 : 0)
                .frame(height: block.isLeaf ? nil : 18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(block.isLeaf ? Color.clear : ink.opacity(Theme.palette.solidTreemapFills ? 0.12 : 0.22))
            }

            if showActions {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        if block.node.isSynthetic {
                            Text("aggregated")
                                .font(Theme.font(10, .semibold))
                                .foregroundColor(Theme.textMuted)
                                .padding(.horizontal, 7).frame(height: 22)
                                .background(RoundedRectangle(cornerRadius: Theme.radius(5)).fill(Theme.windowBG.opacity(0.85)))
                        } else {
                            Button(action: onClean) {
                                HStack(spacing: 5) {
                                    Image(systemName: "trash").font(.system(size: 9, weight: .bold))
                                    Text("Clean").font(Theme.font(11, .bold))
                                }
                                .foregroundColor(Theme.elevated ? Theme.onAccent : Theme.accent)
                                .padding(.horizontal, 9).frame(height: 22)
                                .background(RoundedRectangle(cornerRadius: Theme.radius(5))
                                    .fill(Theme.elevated ? Theme.danger : Theme.windowBG))
                                .overlay(RoundedRectangle(cornerRadius: Theme.radius(5))
                                    .strokeBorder(Theme.elevated ? .clear : Theme.border, lineWidth: Theme.ruleWidth))
                                .shadow(color: Theme.elevated ? .black.opacity(0.5) : .clear, radius: 4, x: 0, y: 3)
                            }
                            .buttonStyle(FlatButtonStyle())
                        }
                    }
                }
                .padding(4)
                .transition(.opacity)
            }
        }
        .frame(width: max(1, block.rect.width), height: max(1, block.rect.height))
        .clipped()
        .compositingGroup()
        .shadow(color: hovered && Theme.elevated ? .black.opacity(0.6) : .clear,
                radius: hovered && Theme.elevated ? 13 : 0, x: 0, y: hovered && Theme.elevated ? 8 : 0)
        .opacity(dimmed ? 0.18 : 1)
        .position(x: block.rect.midX, y: block.rect.midY)
        .zIndex(Double(block.depth * 2 + (hovered ? 40 : 0)))
        .onHover(perform: onHover)
        .onTapGesture(perform: onOpen)
        .help("\(block.node.displayPath) — \(Bytes.format(block.node.size))")
    }
}

struct TreemapCanvas: View {
    @ObservedObject var engine: ScanEngine

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Theme.canvasBG)

                ForEach(engine.blocks) { block in
                    TreemapBlockView(
                        block: block,
                        hovered: engine.hoveredNode === block.node,
                        dimmed: engine.isDimmed(block.node),
                        showSize: engine.showSizes,
                        onHover: { inside in
                            if inside { engine.hoveredNode = block.node }
                            else if engine.hoveredNode === block.node { engine.hoveredNode = nil }
                        },
                        onOpen: { engine.drill(into: block.node) },
                        onClean: { engine.clean(block.node) }
                    )
                }

                if engine.blocks.isEmpty {
                    EmptyCanvasState(engine: engine)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.38), value: engine.blocks.map(\.id))
            .onAppear { engine.setCanvasSize(geo.size) }
            .onChange(of: geo.size) { engine.setCanvasSize($0) }
        }
        .background(Theme.canvasBG)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius(8)))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius(8)).strokeBorder(Theme.borderCanvas, lineWidth: Theme.ruleWidth))
    }
}

struct EmptyCanvasState: View {
    @ObservedObject var engine: ScanEngine

    var body: some View {
        VStack(spacing: 14) {
            if engine.isScanning {
                ProgressView().controlSize(.large)
                Text("Mapping \(engine.scannedItems.formatted()) items…")
                    .font(Theme.font(13, .medium)).foregroundColor(Theme.textBody)
                Text(engine.currentScanPath)
                    .font(Theme.font(11)).foregroundColor(Theme.textFaint)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 460)
            } else {
                Image(systemName: "square.grid.3x3.topleft.filled")
                    .font(.system(size: 34, weight: .light))
                    .foregroundColor(Theme.textFaint)
                Text("Nothing mapped yet")
                    .font(Theme.font(14, .semibold)).foregroundColor(Theme.textBody)
                Text("Pick Scan Home, Scan Full Mac, or Choose Folder to build the treemap.")
                    .font(Theme.font(12)).foregroundColor(Theme.textFaint)
                ScanActionButton(kind: .primary, title: "Choose Folder", icon: "folder") {
                    engine.chooseFolderAndScan()
                }
                .frame(width: 200)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - List view
// ─────────────────────────────────────────────────────────────────────────────

struct FileRow: View {
    @ObservedObject var engine: ScanEngine
    let node: FileNode
    let maxBytes: Int64
    @State private var hovering = false
    @State private var hoveringClean = false

    private var safe: Bool { node.category.isSafeToClean }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: Theme.radius(2))
                .fill(node.category.color)
                .frame(width: 8, height: 8)

            Text(Bytes.format(node.size))
                .font(Theme.mono(12.5, .semibold))
                .foregroundColor(Theme.textBody)
                .frame(width: 84, alignment: .leading)

            Text(node.name)
                .font(Theme.font(13))
                .foregroundColor(hovering ? Theme.accent : Theme.textStrong)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 120, alignment: .leading)
                .onTapGesture { engine.drill(into: node) }

            MiniBar(fraction: Double(node.size) / Double(max(1, maxBytes)),
                    color: node.category.color, height: 6, gradient: true)
                .frame(minWidth: 60)

            Text(safe ? "Safe" : "Caution")
                .font(Theme.font(11, .semibold))
                .foregroundColor(safe ? Theme.successSoft : Theme.warning)
                .frame(width: 62)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: Theme.radius(5))
                    .fill((safe ? Theme.success : Theme.warning).opacity(0.14)))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius(5))
                    .strokeBorder((safe ? Theme.success : Theme.warning).opacity(0.3), lineWidth: Theme.ruleWidth))

            Button { engine.revealInFinder(node) } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textMuted)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(FlatButtonStyle())
            .help("Reveal in Finder")

            Button { engine.clean(node) } label: {
                Text("Clean")
                    .font(Theme.font(11.5, .semibold))
                    .foregroundColor(hoveringClean ? Theme.onAccent : Theme.textControl)
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: Theme.radius(6))
                        .fill(hoveringClean ? Theme.danger : Theme.chipBG))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius(6))
                        .strokeBorder(hoveringClean ? Theme.danger : Theme.borderChip, lineWidth: Theme.ruleWidth))
            }
            .buttonStyle(FlatButtonStyle())
            .onHover { hoveringClean = $0 }
            .disabled(node.isSynthetic)
            .opacity(node.isSynthetic ? 0.35 : 1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: Theme.radius(8)).fill(hovering ? Theme.rowHoverBG : .clear))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.borderRow).frame(height: Theme.ruleWidth) }
        .onHover { inside in
            hovering = inside
            engine.hoveredNode = inside ? node : (engine.hoveredNode === node ? nil : engine.hoveredNode)
        }
    }
}

struct FileListView: View {
    @ObservedObject var engine: ScanEngine

    var body: some View {
        let rows = engine.listRows
        VStack(alignment: .leading, spacing: 0) {
            if let heading = engine.listHeading {
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 12)).foregroundColor(Theme.accent)
                    Text(heading).font(Theme.font(12, .medium)).foregroundColor(Theme.textControl)
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.bottom, 8)
            }
            if rows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.system(size: 26)).foregroundColor(Theme.textFaint)
                    Text("Nothing to list here").font(Theme.font(13)).foregroundColor(Theme.textFaint)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { node in
                            FileRow(engine: engine, node: node, maxBytes: engine.listRowsMaxSize)
                        }
                    }
                    .padding(.trailing, 6)
                }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Detail pane
// ─────────────────────────────────────────────────────────────────────────────

struct ViewTab: View {
    let title: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.font(12.5, active ? .semibold : .medium))
                .foregroundColor(active ? Theme.onTab : Theme.textMuted)
                .padding(.horizontal, 13).padding(.vertical, 5)
                .background {
                    if active {
                        RoundedRectangle(cornerRadius: Theme.radius(6))
                            .fill(LinearGradient(colors: [Theme.tabTop, Theme.tabBottom],
                                                 startPoint: .top, endPoint: .bottom))
                    }
                }
        }
        .buttonStyle(FlatButtonStyle())
    }
}

struct DetailView: View {
    @ObservedObject var engine: ScanEngine
    @State private var hoverBack = false

    var body: some View {
        VStack(spacing: 0) {

            // Toolbar: tabs + breadcrumbs + back
            HStack(spacing: 14) {
                HStack(spacing: 2) {
                    ViewTab(title: "Treemap", active: engine.viewMode == .treemap) { engine.viewMode = .treemap }
                    ViewTab(title: "List View", active: engine.viewMode == .list) { engine.viewMode = .list }
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: Theme.radius(8)).fill(Theme.chipBG))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius(8)).strokeBorder(Theme.border, lineWidth: Theme.ruleWidth))

                breadcrumbs

                Spacer(minLength: 8)

                Text(engine.nodeCountLabel)
                    .font(Theme.mono(12))
                    .foregroundColor(Theme.textDim)
                    .lineLimit(1)

                Button { engine.goUp() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("Back").font(Theme.font(12))
                    }
                    .foregroundColor(hoverBack && engine.canGoUp ? Theme.textControlHover : Theme.textControl)
                    .padding(.horizontal, 11).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: Theme.radius(7)).fill(Theme.chipBG))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius(7))
                        .strokeBorder(hoverBack && engine.canGoUp ? Theme.borderControlHover : Theme.borderChip, lineWidth: Theme.ruleWidth))
                }
                .buttonStyle(FlatButtonStyle())
                .onHover { hoverBack = $0 }
                .disabled(!engine.canGoUp)
                .opacity(engine.canGoUp ? 1 : 0.45)
            }
            .padding(.horizontal, 18)
            .frame(height: 52)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.borderSoft).frame(height: Theme.ruleWidth) }

            // Canvas / list
            ZStack {
                if engine.viewMode == .treemap {
                    TreemapCanvas(engine: engine)
                } else {
                    FileListView(engine: engine)
                }
            }
            .padding(14)

            StatusBar(engine: engine)
        }
        .background(Theme.windowBG)
    }

    private var breadcrumbs: some View {
        HStack(spacing: 6) {
            ForEach(Array(engine.breadcrumbs.enumerated()), id: \.element.id) { index, node in
                let isLast = index == engine.breadcrumbs.count - 1
                Text(node.name)
                    .font(Theme.font(12.5, isLast ? .semibold : .regular))
                    .foregroundColor(isLast ? Theme.textStrong : Theme.textMuted)
                    .lineLimit(1)
                    .onTapGesture { engine.goTo(breadcrumbIndex: index) }
                if !isLast {
                    Text("/").font(Theme.font(12)).foregroundColor(Theme.textSeparator)
                }
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
        .clipped()
    }
}

struct StatusBar: View {
    @ObservedObject var engine: ScanEngine
    @ObservedObject private var licenseStore = LicenseStore.shared

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(engine.statusColor).frame(width: 8, height: 8)
            Text(engine.statusText)
                .font(Theme.mono(12))
                .foregroundColor(Theme.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let warning = licenseStore.graceWarning {
                // Louder than a status line, quieter than a modal — the point is
                // that nobody discovers a lapsed licence by having Clean fail.
                Button { licenseStore.presentSheet() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10)).foregroundColor(Theme.warning)
                        Text(warning)
                            .font(Theme.font(11.5)).foregroundColor(Theme.warning)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    .frame(maxWidth: 460, alignment: .trailing)
                }
                .buttonStyle(FlatButtonStyle())
            } else if let error = engine.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundColor(Theme.warning)
                    Text(error)
                        .font(Theme.font(11.5)).foregroundColor(Theme.warning)
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: 420, alignment: .trailing)
                }
                .onTapGesture { engine.errorMessage = nil }
            } else {
                Text("Click a block to zoom in · hover for quick clean")
                    .font(Theme.font(11.5))
                    .foregroundColor(Theme.textFaint)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 40)
        .background(Theme.statusBarBG)
        .overlay(alignment: .top) { Rectangle().fill(Theme.borderSoft).frame(height: Theme.ruleWidth) }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Root
// ─────────────────────────────────────────────────────────────────────────────

struct RootView: View {
    @StateObject private var engine = ScanEngine()
    @ObservedObject private var themeStore = ThemeStore.shared
    @ObservedObject private var licenseStore = LicenseStore.shared
    @FocusState private var searchFocused: Bool
    @State private var didAutoScan = false

    /// `swift run DrivePurge ~/Documents/GitHub` scans that folder on launch;
    /// with no argument the home folder is mapped.
    static var launchTarget: URL {
        if let arg = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            let url = URL(fileURLWithPath: (arg as NSString).expandingTildeInPath)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                return url
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(engine: engine, themeStore: themeStore, licenseStore: licenseStore,
                     searchFocused: $searchFocused)

            NavigationView {
                SidebarView(engine: engine)
                    .frame(minWidth: 262, idealWidth: 292, maxWidth: 360)
                DetailView(engine: engine)
                    .frame(minWidth: 620)
            }
            .navigationViewStyle(.columns)
        }
        .frame(minWidth: 1040, minHeight: 680)
        .background(Theme.windowBG)
        // Palette values are read at render time, so rebuilding the tree on a
        // theme change is what actually repaints the app.
        .id(themeStore.theme)
        .preferredColorScheme(themeStore.theme.colorScheme)
        .environment(\.colorScheme, themeStore.theme.colorScheme)
        .sheet(isPresented: $licenseStore.isPresentingSheet) {
            LicenseSheet(store: licenseStore)
        }
        .onAppear {
            guard !didAutoScan else { return }
            didAutoScan = true
            engine.startScan(RootView.launchTarget)
            // Best-effort and silent: being offline must never interrupt a launch.
            Task { await licenseStore.refreshIfDue() }
        }
        .background(
            // Invisible hosts for the keyboard shortcuts in the design.
            Group {
                Button("") { searchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                Button("") { engine.chooseFolderAndScan() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("") { engine.goUp() }
                    .keyboardShortcut("[", modifiers: .command)
                Button("") { themeStore.toggle() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("") { licenseStore.presentSheet() }
                    .keyboardShortcut("l", modifiers: .command)
            }
            .opacity(0)
        )
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - App entry point
// ─────────────────────────────────────────────────────────────────────────────

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `DrivePurge --audit <path>` runs the scanner headlessly and prints totals.
    /// Useful for checking the treemap against `du -sh`.
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Licensing is verifiable headlessly, which matters because the GUI is
        // awkward to drive from a script.
        if CommandLine.arguments.contains("--license-audit") {
            MainActor.assumeIsolated { AppDelegate.runLicenseAudit() }
        }
        guard CommandLine.arguments.contains("--audit") else { return }
        let target = RootView.launchTarget
        let ctx = ScanContext { _, _ in }
        let started = Date()
        let tree = DiskScanner.scan(url: target, parent: nil, depth: 0, ctx: ctx)
        let elapsed = Date().timeIntervalSince(started)
        print("path:    \(target.path)")
        print("total:   \(Bytes.format(tree?.size ?? 0))  (\(tree?.size ?? 0) bytes)")
        print("visited: \(ctx.count) items in \(String(format: "%.1fs", elapsed))")
        if let kids = tree?.children {
            print("top children:")
            for k in kids.prefix(12) {
                print(String(format: "  %10@  %@", Bytes.format(k.size) as NSString, k.name as NSString))
            }
        }
        exit(0)
    }

    /// `DrivePurge --license-audit [key]` prints this Mac's device hash and the
    /// current licence state, optionally activating a key first. Everything it
    /// touches is the same code path the GUI uses.
    @MainActor
    static func runLicenseAudit() -> Never {
        let store = LicenseStore.shared
        let args = CommandLine.arguments
        print("device hash:  \(DeviceIdentity.hash)")
        print("device name:  \(DeviceIdentity.name)")
        print("api base:     \(LicenseAPI.baseURL.absoluteString)")
        print("pubkey set:   \(LicenseTokenVerifier.isConfigured)")

        if let i = args.firstIndex(of: "--license-audit"), i + 1 < args.count,
           !args[i + 1].hasPrefix("-") {
            let key = args[i + 1]
            print("activating:   \(key)")
            let done = DispatchSemaphore(value: 0)
            Task { await store.activate(key: key); done.signal() }
            while done.wait(timeout: .now()) == .timedOut {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
        }

        print("state:        \(store.state)")
        print("can clean:    \(store.canClean)")
        print("summary:      \(store.statusSummary)")
        if let message = store.message { print("message:      \(message)") }
        for seat in store.seats {
            print("seat:         \(seat.deviceName ?? "?")\(seat.isThisMac ? "  (this Mac)" : "")")
        }
        exit(store.canClean ? 0 : 1)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `swift run` produces a bare executable; promote it to a real GUI app
        // so the window comes forward with a Dock icon and a menu bar.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let window = NSApplication.shared.windows.first {
            window.title = "DrivePurge"
            window.titlebarAppearsTransparent = true
            window.center()
        }
        applyThemeToWindows()

        // SwiftUI repaints itself, but the window's own chrome — traffic
        // lights, the ground behind the content — is AppKit's to update.
        NotificationCenter.default.addObserver(
            forName: .drivePurgeThemeChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyThemeToWindows() }
        }
    }

    @MainActor
    private func applyThemeToWindows() {
        let theme = ThemeStore.shared.theme
        let ground = theme.palette.windowBG
        let appearance = NSAppearance(named: theme == .apple ? .darkAqua : .aqua)
        NSApplication.shared.appearance = appearance
        for window in NSApplication.shared.windows {
            window.appearance = appearance
            window.backgroundColor = NSColor(red: ground.r, green: ground.g, blue: ground.b, alpha: 1)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct DrivePurgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @ObservedObject private var themeStore = ThemeStore.shared
    @ObservedObject private var licenseStore = LicenseStore.shared

    var body: some Scene {
        WindowGroup("DrivePurge") {
            RootView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1360, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Licence") {
                Button(licenseStore.isLicensed ? "Your Licence…" : "Unlock Cleaning…") {
                    licenseStore.presentSheet()
                }
                .keyboardShortcut("l", modifiers: .command)
                Divider()
                Button("Buy a Licence…") { NSWorkspace.shared.open(LicenseStore.purchaseURL) }
            }
            CommandMenu("Theme") {
                Picker("Appearance", selection: Binding(
                    get: { themeStore.theme },
                    set: { themeStore.select($0) }
                )) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Switch Theme") { themeStore.toggle() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
            }
        }
    }
}
