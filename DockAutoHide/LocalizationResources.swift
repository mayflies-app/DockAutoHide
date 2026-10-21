import Foundation

/// Explicit app-language lookup shared by SwiftPM modules and native app bundles.
public enum LocalizationResources {
    public static func bundle(named name: String? = nil, application: Bundle = .main,
                              fallback: () -> Bundle = { .main }) -> Bundle {
        if let name, let url = application.resourceURL?.appendingPathComponent(name),
           let embedded = Bundle(url: url) {
            return embedded
        }
        return fallback()
    }

    public static func string(_ key: String, language: String, table: String = "Localizable",
                              bundle: Bundle) -> String {
        let missing = "\u{E000}missing-localization\u{E001}"
        for code in [language, "en"] {
            guard let localized = localizedBundle(code, in: bundle) else { continue }
            let value = localized.localizedString(forKey: key, value: missing, table: table)
            if value != missing { return value }
        }
        return key
    }

    public static func format(_ key: String, language: String, table: String = "Localizable",
                              bundle: Bundle, arguments: [CVarArg]) -> String {
        let value = string(key, language: language, table: table, bundle: bundle)
        guard !arguments.isEmpty else { return value }
        return String(format: value, locale: Locale(identifier: language), arguments: arguments)
    }

    /// Read one language's resource table for coverage checks and existing native-label refresh.
    public static func catalog(language: String, table: String = "Localizable",
                               bundle: Bundle) -> [String: String] {
        guard let localized = localizedBundle(language, in: bundle),
              let url = localized.url(forResource: table, withExtension: "strings"),
              let data = try? Data(contentsOf: url),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: String] else { return [:] }
        return values
    }

    private static func localizedBundle(_ language: String, in bundle: Bundle) -> Bundle? {
        let code = language.replacingOccurrences(of: "_", with: "-")
        guard let name = bundle.localizations.first(where: {
            $0.caseInsensitiveCompare(code) == .orderedSame
        }), let path = bundle.path(forResource: name, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }
}
