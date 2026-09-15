import SwiftUI
import CoreText

/// Roboto for the widget extension.
///
/// The app registers the same faces in `Dictionary/Support/AppFonts.swift`, but
/// a widget runs in its own process and reads its own bundle, so the extension
/// needs its own copy of the registration (and of the .ttf files). Without it
/// SwiftUI silently falls back to the system font and the widget stops looking
/// like the app.
enum WidgetFonts {
    private static let faces = [
        "Roboto-Regular",
        "Roboto-Medium",
        "Roboto-Bold",
        "Roboto-Italic",
        "Roboto-BoldItalic",
    ]

    /// Registered exactly once per process. A widget has no `App.init` to hang
    /// this off, and timeline rendering can happen on any launch of the
    /// extension, so every view that uses Roboto touches this first.
    static let registered: Void = {
        for face in faces {
            guard let url = Bundle.main.url(forResource: face, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()

    /// Roboto ships Regular, Medium and Bold here, so heavier weights round down
    /// to Bold and lighter ones up to Regular. There's no Medium Italic, so
    /// medium italic borrows the regular italic.
    static func postScriptName(weight: Font.Weight, italic: Bool) -> String {
        switch weight {
        case .bold, .semibold, .heavy, .black:
            return italic ? "Roboto-BoldItalic" : "Roboto-Bold"
        case .medium:
            return italic ? "Roboto-Italic" : "Roboto-Medium"
        default:
            return italic ? "Roboto-Italic" : "Roboto-Regular"
        }
    }
}

extension Font {
    /// Roboto at a fixed point size, mirroring `Font.roboto` in the app target.
    static func roboto(_ size: CGFloat, weight: Font.Weight = .regular, italic: Bool = false) -> Font {
        _ = WidgetFonts.registered
        return .custom(WidgetFonts.postScriptName(weight: weight, italic: italic), fixedSize: size)
    }
}

extension Color {
    /// The app's AccentColor asset, repeated here because asset catalogs aren't
    /// shared across targets. Used sparingly, as in the app.
    static let dictionaryAccent = Color(red: 0.769, green: 0.180, blue: 0.165)
}
