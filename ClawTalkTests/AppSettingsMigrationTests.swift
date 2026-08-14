import XCTest
@testable import ClawTalk

final class AppSettingsMigrationTests: XCTestCase {

    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    // MARK: - VoiceAgentChannel 迁移

    func testLegacyGatewayRawValueMigrates() throws {
        // 旧存档 rawValue 曾为中文占位符 \u7F51\u5173 = 网关
        let settings = try decode(#"{"gatewayURL":"x","voiceOutputEnabled":true,"voiceInputEnabled":true,"voiceAgentChannel":"\u7F51\u5173"}"#)
        XCTAssertEqual(settings.voiceAgentChannel, .gateway)
    }

    func testLegacyDirectDeepSeekRawValueMigrates() throws {
        // \u76F4\u8FDE = 直连（直连 DeepSeek）
        let settings = try decode(#"{"gatewayURL":"x","voiceOutputEnabled":true,"voiceInputEnabled":true,"voiceAgentChannel":"\u76F4\u8FDE DeepSeek"}"#)
        XCTAssertEqual(settings.voiceAgentChannel, .directDeepSeek)
    }

    func testCurrentRawValuesDecodeDirectly() throws {
        let settings = try decode(#"{"gatewayURL":"x","voiceOutputEnabled":true,"voiceInputEnabled":true,"voiceAgentChannel":"gateway"}"#)
        XCTAssertEqual(settings.voiceAgentChannel, .gateway)
    }

    func testUnknownChannelFallsBackToGateway() throws {
        let settings = try decode(#"{"gatewayURL":"x","voiceOutputEnabled":true,"voiceInputEnabled":true,"voiceAgentChannel":"some_future_value"}"#)
        XCTAssertEqual(settings.voiceAgentChannel, .gateway)
    }

    func testMissingChannelDefaultsToGateway() throws {
        let settings = try decode(#"{"gatewayURL":"x","voiceOutputEnabled":true,"voiceInputEnabled":true}"#)
        XCTAssertEqual(settings.voiceAgentChannel, .gateway)
    }

    func testChannelRoundTrip() throws {
        var settings = AppSettings.defaults
        settings.voiceAgentChannel = .directDeepSeek
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.voiceAgentChannel, .directDeepSeek)
    }

    // MARK: - 旧存档缺字段解码默认值

    func testMissingOptionalFieldsDecodeWithDefaults() throws {
        let json = #"""
        {
            "gatewayURL": "https://example.com",
            "voiceOutputEnabled": true,
            "voiceInputEnabled": true
        }
        """#
        let settings = try decode(json)
        XCTAssertEqual(settings.gatewayURL, "https://example.com")
        XCTAssertEqual(settings.voiceAgentChannel, .gateway)
        XCTAssertEqual(settings.agentAPIMode, .openResponses)
        XCTAssertEqual(settings.sttProvider, .apple)
        XCTAssertEqual(settings.ttsProvider, .apple)
        XCTAssertEqual(settings.appearance, .dark)
        XCTAssertEqual(settings.voiceWakeEnabled, false)
        XCTAssertEqual(settings.webSocketPath, "/ws")
        XCTAssertEqual(settings.homeThemeSource, .noWallpaper)
        XCTAssertEqual(settings.homeBlurStrength, 0.55)
        XCTAssertEqual(settings.fusionBackendURL, "http://127.0.0.1:18890")
        XCTAssertTrue(settings.customHeaders.isEmpty)
        XCTAssertNil(settings.voiceWakeChannelID)
    }

    func testRequiredFieldsMissingThrows() {
        // voiceOutputEnabled / voiceInputEnabled / gatewayURL 为必需字段：
        // 缺失时解码失败，SettingsStore 会回退到 .defaults（旧版本无此字段的存档会整体失效）
        XCTAssertThrowsError(try decode(#"{"gatewayURL":"x"}"#))
        XCTAssertThrowsError(try decode(#"{"gatewayURL":"x","voiceOutputEnabled":true}"#))
        XCTAssertThrowsError(try decode(#"{"voiceOutputEnabled":true,"voiceInputEnabled":true}"#))
    }

    // MARK: - 其他旧字段迁移

    func testLegacyVoiceWakeWordMigrates() throws {
        let settings = try decode(#"{"gatewayURL":"x","voiceOutputEnabled":true,"voiceInputEnabled":true,"voiceWakeWord":"hey claw"}"#)
        XCTAssertEqual(settings.voiceWakeWords, ["hey claw"])
    }

    func testUnknownAppearanceFallsBackToDark() throws {
        let settings = try decode(#"{"gatewayURL":"x","voiceOutputEnabled":true,"voiceInputEnabled":true,"appearance":"neon"}"#)
        XCTAssertEqual(settings.appearance, .dark)
    }

    func testUnknownProvidersFallBackToApple() throws {
        let settings = try decode(#"{"gatewayURL":"x","voiceOutputEnabled":true,"voiceInputEnabled":true,"ttsProvider":"unknown","sttProvider":"unknown"}"#)
        XCTAssertEqual(settings.ttsProvider, .apple)
        XCTAssertEqual(settings.sttProvider, .apple)
    }

    func testHomeThemeLegacyMigration() throws {
        // 旧版默认 systemWallpaper + id 0 且未主动选择 -> 迁移为 noWallpaper
        let legacy = try decode(#"{"gatewayURL":"x","voiceOutputEnabled":true,"voiceInputEnabled":true,"homeThemeSource":"systemWallpaper","homeWallpaperID":0,"homeWallpaperChosen":false}"#)
        XCTAssertEqual(legacy.homeThemeSource, .noWallpaper)

        // 主动选择过壁纸 -> 保持 systemWallpaper
        let chosen = try decode(#"{"gatewayURL":"x","voiceOutputEnabled":true,"voiceInputEnabled":true,"homeThemeSource":"systemWallpaper","homeWallpaperID":1,"homeWallpaperChosen":true}"#)
        XCTAssertEqual(chosen.homeThemeSource, .systemWallpaper)
        XCTAssertEqual(chosen.homeWallpaperID, 1)
    }
}