import Foundation
import KeychainAccess

/// All sensitive credentials stored in iOS Keychain, never UserDefaults or disk.
final class SecureStorage {
    static let shared = SecureStorage()

    private let keychain: Keychain

    private enum Keys {
        static let gatewayToken = "openclaw_gateway_token"
        static let elevenLabsAPIKey = "elevenlabs_api_key"
        static let openAIAPIKey = "openai_api_key"
        static let doubaoAPIKey = "doubao_api_key"
        static let weatherAPIKey = "weather_api_key"
    }

    private init() {
        keychain = Keychain(service: "com.openclaw.clawtalk")
            .accessibility(.whenUnlockedThisDeviceOnly)
    }

    var gatewayToken: String? {
        get { try? keychain.get(Keys.gatewayToken) }
        set {
            if let value = newValue {
                try? keychain.set(value, key: Keys.gatewayToken)
            } else {
                try? keychain.remove(Keys.gatewayToken)
            }
        }
    }

    var elevenLabsAPIKey: String? {
        get { try? keychain.get(Keys.elevenLabsAPIKey) }
        set {
            if let value = newValue {
                try? keychain.set(value, key: Keys.elevenLabsAPIKey)
            } else {
                try? keychain.remove(Keys.elevenLabsAPIKey)
            }
        }
    }

    var openAIAPIKey: String? {
        get { try? keychain.get(Keys.openAIAPIKey) }
        set {
            if let value = newValue {
                try? keychain.set(value, key: Keys.openAIAPIKey)
            } else {
                try? keychain.remove(Keys.openAIAPIKey)
            }
        }
    }

    var doubaoAPIKey: String? {
        get { try? keychain.get(Keys.doubaoAPIKey) }
        set {
            if let value = newValue {
                try? keychain.set(value, key: Keys.doubaoAPIKey)
            } else {
                try? keychain.remove(Keys.doubaoAPIKey)
            }
        }
    }

    var weatherAPIKey: String? {
        get { try? keychain.get(Keys.weatherAPIKey) }
        set {
            if let value = newValue {
                try? keychain.set(value, key: Keys.weatherAPIKey)
            } else {
                try? keychain.remove(Keys.weatherAPIKey)
            }
        }
    }

    // MARK: - Generic Key Access

    func getString(_ key: String) -> String? {
        try? keychain.get(key)
    }

    func setString(_ value: String?, forKey key: String) {
        if let value {
            try? keychain.set(value, key: key)
        } else {
            try? keychain.remove(key)
        }
    }

    func clearAll() {
        try? keychain.removeAll()
    }
}
