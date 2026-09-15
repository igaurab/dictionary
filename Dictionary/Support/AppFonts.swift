import SwiftUI
import CoreText

/// Roboto, registered at launch and used for every piece of text in the app.
///
/// Google's dictionary panel renders in `"Google Sans Text", Roboto, Arial,
/// sans-serif`. Google Sans is proprietary and can't be redistributed, so the
/// app ships Roboto — the first freely licensable face in that stack, and the
/// one Google itself falls back to.
enum AppFonts {
    private static let faces = [
        "Roboto-Regular",
        "Roboto-Medium",
        "Roboto-Bold",
        "Roboto-Italic",
        "Roboto-BoldItalic",
    ]

    /// Registers the bundled faces with Core Text. Fonts loaded this way don't
    /// need a `UIAppFonts` entry in Info.plist.
    static func register() {
        for face in faces {
            guard let url = Bundle.main.url(forResource: face, withExtension: "ttf") else {
                assertionFailure("\(face).ttf missing from app bundle")
                continue
            }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

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
    /// Roboto at a fixed point size. Sizes in this app are already multiplied by
    /// the user's text-size setting, so they intentionally don't also scale with
    /// Dynamic Type.
    static func roboto(_ size: CGFloat, weight: Font.Weight = .regular, italic: Bool = false) -> Font {
        .custom(AppFonts.postScriptName(weight: weight, italic: italic), fixedSize: size)
    }
}
