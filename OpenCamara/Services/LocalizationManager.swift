import Combine
import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    case japanese = "ja"
    case german = "de"

    var id: String { rawValue }

    var locale: Locale {
        switch self {
        case .system: return Self.supportedSystemLocale
        default: return Locale(identifier: rawValue)
        }
    }

    var displayName: String {
        switch self {
        case .system: return L10n.string("跟随系统")
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        case .japanese: return "日本語"
        case .german: return "Deutsch"
        }
    }

    private static var supportedSystemLocale: Locale {
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        if preferred.hasPrefix("zh") { return Locale(identifier: "zh-Hans") }
        if preferred.hasPrefix("ja") { return Locale(identifier: "ja") }
        if preferred.hasPrefix("de") { return Locale(identifier: "de") }
        return Locale(identifier: "en")
    }
}

@MainActor
final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()
    nonisolated static let defaultsKey = "OpenCamara.appLanguage"

    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.defaultsKey)
        }
    }

    var locale: Locale { language.locale }

    private init() {
        let savedValue = UserDefaults.standard.string(forKey: Self.defaultsKey)
        language = savedValue.flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    func string(_ key: String) -> String {
        L10n.string(key)
    }

    func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: L10n.string(key), locale: L10n.locale, arguments: arguments)
    }
}

enum L10n {
    static var locale: Locale {
        let savedValue = UserDefaults.standard.string(forKey: LocalizationManager.defaultsKey)
        return (savedValue.flatMap(AppLanguage.init(rawValue:)) ?? .system).locale
    }

    static func string(_ key: String) -> String {
        String(
            localized: String.LocalizationValue(key),
            table: "Localizable",
            bundle: localizedBundle,
            locale: locale
        )
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: locale, arguments: arguments)
    }

    private static var localizedBundle: Bundle {
        let resourceName = locale.identifier.hasPrefix("zh") ? "zh-Hans" : locale.language.languageCode?.identifier ?? "en"
        guard let path = Bundle.main.path(forResource: resourceName, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return .main
        }
        return bundle
    }
}
