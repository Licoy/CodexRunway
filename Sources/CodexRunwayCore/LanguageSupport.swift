import CoreText
import Foundation

extension LanguagePreference {
    public static var explicitCases: [LanguagePreference] {
        allCases.filter { $0 != .system }
    }

    public static let nativeTitleEnglish = "English"
    public static let nativeTitleSimplifiedChinese = "简体中文"
    public static let nativeTitleTraditionalChinese = "繁體中文"
    public static let nativeTitleKorean = "한국어"
    public static let nativeTitleJapanese = "日本語"
    public static let nativeTitleRussian = "Русский"
    public static let nativeTitleFrench = "Français"

    /// Auto follows the current UI language. Explicit options stay in their own script.
    public func menuTitle(uiLanguage: ResolvedLanguage) -> String {
        switch self {
        case .system:
            return L10n(language: uiLanguage).text(.auto)
        case .english:
            return Self.nativeTitleEnglish
        case .simplifiedChinese:
            return Self.nativeTitleSimplifiedChinese
        case .traditionalChinese:
            return Self.nativeTitleTraditionalChinese
        case .korean:
            return Self.nativeTitleKorean
        case .japanese:
            return Self.nativeTitleJapanese
        case .russian:
            return Self.nativeTitleRussian
        case .french:
            return Self.nativeTitleFrench
        }
    }
}

extension ResolvedLanguage {
    public var localeIdentifier: String {
        switch self {
        case .english:
            return "en_US"
        case .simplifiedChinese:
            return "zh_Hans_CN"
        case .traditionalChinese:
            return "zh_Hant_TW"
        case .korean:
            return "ko_KR"
        case .japanese:
            return "ja_JP"
        case .russian:
            return "ru_RU"
        case .french:
            return "fr_FR"
        }
    }

    public var posixLocaleIdentifier: String {
        switch self {
        case .english:
            return "en_US_POSIX"
        default:
            return localeIdentifier
        }
    }

    public var locale: Locale {
        Locale(identifier: localeIdentifier)
    }

    public var preference: LanguagePreference {
        switch self {
        case .english:
            return .english
        case .simplifiedChinese:
            return .simplifiedChinese
        case .traditionalChinese:
            return .traditionalChinese
        case .korean:
            return .korean
        case .japanese:
            return .japanese
        case .russian:
            return .russian
        case .french:
            return .french
        }
    }

    public var usesFullwidthPunctuation: Bool {
        switch self {
        case .simplifiedChinese, .traditionalChinese, .japanese:
            return true
        default:
            return false
        }
    }

    public var colonSeparator: String {
        usesFullwidthPunctuation ? "：" : ": "
    }

    public var openParen: String {
        usesFullwidthPunctuation ? "（" : " ("
    }

    public var closeParen: String {
        usesFullwidthPunctuation ? "）" : ")"
    }

    public var usesCJKDatePattern: Bool {
        switch self {
        case .simplifiedChinese, .traditionalChinese, .japanese, .korean:
            return true
        default:
            return false
        }
    }

    public var compactNumberScale: CompactNumberScale {
        switch self {
        case .simplifiedChinese:
            return .wanYiSimplified
        case .traditionalChinese:
            return .wanYiTraditional
        case .japanese:
            return .wanYiJapanese
        case .korean:
            return .manEok
        case .english, .russian, .french:
            return .latin
        }
    }

    public static func resolveSystem(preferredLanguages: [String]) -> ResolvedLanguage {
        for identifier in preferredLanguages {
            if let resolved = mapLocaleIdentifier(identifier) {
                return resolved
            }
        }
        return .english
    }

    public static func mapLocaleIdentifier(_ identifier: String) -> ResolvedLanguage? {
        let normalized = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        let parts = normalized.split(separator: "-").map(String.init)
        guard let language = parts.first, !language.isEmpty else { return nil }

        if language == "zh" {
            if parts.contains("hant") {
                return .traditionalChinese
            }
            if parts.contains("hans") {
                return .simplifiedChinese
            }
            if parts.contains(where: { ["tw", "hk", "mo"].contains($0) }) {
                return .traditionalChinese
            }
            return .simplifiedChinese
        }

        switch language {
        case "ko":
            return .korean
        case "ja":
            return .japanese
        case "ru":
            return .russian
        case "fr":
            return .french
        case "en":
            return .english
        default:
            return nil
        }
    }
}

public enum CompactNumberScale: Sendable, Equatable {
    case latin
    case wanYiSimplified
    case wanYiTraditional
    case wanYiJapanese
    case manEok
}

/// Selected-title width for the settings language menu. Caps the well so a short
/// selection such as “English” is not stretched to the longest menu item.
public enum LanguagePickerSizing {
    public static let compactCap: CGFloat = 108
    public static let minimumWidth: CGFloat = 52
    public static let horizontalChrome: CGFloat = 28
    public static let menuFontSize: CGFloat = 13

    public static func measuredTitleWidth(_ title: String) -> CGFloat {
        let font = CTFontCreateWithName("Helvetica Neue" as CFString, menuFontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font,
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: title, attributes: attributes))
        return ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
    }

    public static func controlWidth(selectedTitle: String) -> CGFloat {
        let raw = measuredTitleWidth(selectedTitle) + horizontalChrome
        return min(compactCap, max(minimumWidth, raw))
    }
}
