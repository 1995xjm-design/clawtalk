import Foundation
import Speech

/// 语音识别/合成语言选择（对齐官方 TalkSpeechLocale）：
/// 本地识别语言 + 网关语音语言选择，支持自动/显式 locale。
enum TalkSpeechLocale {
    static let storageKey = "talk.speechLocale"
    static let automaticID = "auto"
    static let fallbackLocaleID = "zh-CN"

    struct Option: Identifiable {
        let id: String
        let label: String
    }

    static func supportedOptions(
        supportedLocales: Set<Locale> = SFSpeechRecognizer.supportedLocales()) -> [Option]
    {
        var seen = Set<String>()
        let dynamic: [Option] = supportedLocales
            .compactMap { locale in
                let id = Self.canonicalID(locale.identifier)
                guard seen.insert(id).inserted else { return nil }
                return Option(id: id, label: Self.friendlyName(for: locale))
            }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        return [Option(id: self.automaticID, label: "自动")] + dynamic
    }

    static func resolvedLocaleID(
        localSelection: String?,
        gatewaySelection: String?,
        deviceLocaleID: String = Locale.autoupdatingCurrent.identifier,
        fallbackLocaleID: String = Self.fallbackLocaleID,
        supportedLocaleIDs: Set<String>) -> String?
    {
        let candidates = [
            Self.normalizedExplicitSpeechLocaleID(localSelection),
            Self.normalizedExplicitSpeechLocaleID(gatewaySelection),
            deviceLocaleID,
        ]
        for candidate in candidates {
            if let candidate, !candidate.isEmpty {
                let canonical = Self.canonicalID(candidate)
                if supportedLocaleIDs.contains(canonical) {
                    return canonical
                }
                if supportedLocaleIDs.contains(candidate) {
                    return candidate
                }
            }
        }
        return fallbackLocaleID
    }

    static func normalizedExplicitSpeechLocaleID(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != Self.automaticID else { return nil }
        return Self.canonicalID(trimmed)
    }

    static func canonicalID(_ raw: String) -> String {
        let cleaned = raw.replacingOccurrences(of: "_", with: "-")
        return Locale(identifier: cleaned).identifier
    }

    static func friendlyName(for locale: Locale) -> String {
        let language = locale.localizedString(forLanguageCode: locale.language.languageCode?.identifier ?? "")
        let region = locale.localizedString(forRegionCode: locale.region?.identifier ?? "")
        var parts: [String] = []
        if let language, !language.isEmpty { parts.append(language) }
        if let region, !region.isEmpty { parts.append(region) }
        return parts.isEmpty ? locale.identifier : parts.joined(separator: " · ")
    }
}
