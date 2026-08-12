import Foundation
import CoreLocation
import AudioToolbox
import UIKit
import Observation

/// 紧急求助触发状态机（供界面实时展示）。
enum SOSPhase: Equatable {
    case idle
    /// 倒计时中（触发后 10 秒内可取消，防误触）
    case countingDown(remaining: Int)
    /// 倒计时结束，正在执行发送链路
    case sending
    /// 链路执行完成（界面展示结果，可手动复位回 idle）
    case finished
}

/// 单个联系人的发送结果（诚实展示：成功 / 未发送+原因）。
struct EmergencySendResult: Identifiable, Equatable {
    let id = UUID()
    let contact: String
    let delivered: Bool
    let detail: String
}

/// 紧急求助核心：
/// - 本地存储配置（UserDefaults JSON，持久化写法仿 MemoryProfileStore）
/// - triggerSOS() 触发链路：并行取当前位置（15s 超时兜底）→ 10 秒取消窗口
///   → 拼求助信息 → ① 本地高优先级通知（NotificationCapability）
///   → ② 网关 chat.send 给预设频道联系人（失败不阻塞、诚实标「未发送」）
///   → ③ 短暂连续响铃/震动（AudioServicesPlaySystemSound + 震动）
/// - 深链兜底入口 clawtalk://sos（锁屏小组件/快捷指令打开 App 后触发）
///
/// 诚实标注（不假装实现）：
/// 1. 电源键连按 5 次：iOS 无公开 API 检测，未实现；用主页 SOS 按钮 + 深链/小组件入口代替。
/// 2. 自动拨号 110/120：iOS 不允许 App 自动拨号，仅提供 tel:// 手动拨号（需用户确认）。
/// 3. BGAppRefresh 兜底：系统调度不确定（可能延迟 15 分钟以上），且触发时 App 进程
///    可能已被系统终止，不适合作为紧急触发的即时通道；只作为打开 App 后的弱兜底。
@MainActor
@Observable
final class EmergencyStore {
    /// 全局共享实例（仿 BGAppRefreshManager.shared：独立持有 SettingsStore）
    static let shared = EmergencyStore(settings: SettingsStore())

    private let defaults = UserDefaults.standard
    private let snapshotKey = "safety_emergency_config_v1"
    /// 取消窗口（秒）：触发后 N 秒内可取消，防误触
    private let cancelWindowSeconds = 10
    /// 定位超时兜底（秒）
    private let locationTimeoutSeconds: TimeInterval = 15
    /// 反地理编码超时兜底（秒）
    private let geocodeTimeoutSeconds: TimeInterval = 5

    private let settings: SettingsStore?
    private let client = OpenClawClient()

    /// 当前配置（编辑统一走 update() 持久化）
    private(set) var config: EmergencyConfig
    /// 触发状态机
    private(set) var phase: SOSPhase = .idle
    /// 最近一次触发取到的位置文案（地址或坐标；nil = 未取到，诚实降级）
    private(set) var lastLocationText: String?
    /// 最近一次触发的逐联系人结果
    private(set) var lastSendResults: [EmergencySendResult] = []
    /// 本地通知失败原因（nil = 成功）
    private(set) var notificationFailure: String?
    /// 最近一次触发/取消的人读摘要
    private(set) var lastTriggerSummary: String?

    @ObservationIgnored private var sosTask: Task<Void, Never>?
    @ObservationIgnored private var locationTask: Task<String?, Never>?
    @ObservationIgnored private var cancellationRequested = false

    init(settings: SettingsStore? = nil) {
        self.settings = settings
        self.config = Self.load(defaults: defaults, snapshotKey: snapshotKey)
    }

    // MARK: - 配置持久化（仿 MemoryProfileStore：UserDefaults JSON）

    private static func load(defaults: UserDefaults, snapshotKey: String) -> EmergencyConfig {
        guard let data = defaults.data(forKey: snapshotKey),
              let decoded = try? JSONDecoder().decode(EmergencyConfig.self, from: data)
        else { return .default }
        return decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(config) {
            defaults.set(data, forKey: snapshotKey)
        }
    }

    /// 统一入口：修改配置后自动保存并刷新 updatedAt。
    func update(_ transform: (inout EmergencyConfig) -> Void) {
        transform(&config)
        config.updatedAt = Date()
        persist()
    }

    func setEnabled(_ enabled: Bool) { update { $0.enabled = enabled } }
    func setIncludeLocation(_ on: Bool) { update { $0.includeLocation = on } }
    func setSOSMessage(_ text: String) { update { $0.sosMessage = text } }

    func addContact(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !config.emergencyContacts.contains(trimmed) else { return }
        update { $0.emergencyContacts.append(trimmed) }
    }

    func removeContact(at offsets: IndexSet) {
        update { $0.emergencyContacts.remove(atOffsets: offsets) }
    }

    // MARK: - 触发链路

    /// 一键触发紧急求助。
    /// - 防误触：先短暂响铃/震动提醒并进入 10 秒倒计时，期间 cancelSOS() 可取消；
    ///   倒计时结束才真正发本地通知 + 网关消息。
    /// - 诚实：未开启或没有联系人时拒绝触发并提示（不假装发送）。
    /// - simulated=true：模拟触发，只做本地通知（标题带【模拟】前缀）+ 响铃/震动，
    ///   不实际发送给联系人，用于设置页测试。
    func triggerSOS(simulated: Bool = false) {
        guard phase == .idle else { return }
        guard simulated || (config.enabled && !config.emergencyContacts.isEmpty) else {
            lastTriggerSummary = config.enabled
                ? "尚未添加紧急联系人，请先到「紧急求助」设置页添加。"
                : "紧急求助未开启，请先到「紧急求助」设置页开启。"
            return
        }

        cancellationRequested = false
        lastLocationText = nil
        lastSendResults = []
        notificationFailure = nil
        lastTriggerSummary = simulated
            ? "模拟触发中（不会实际发送）…"
            : "紧急求助触发中，\(cancelWindowSeconds) 秒内可取消…"
        phase = .countingDown(remaining: cancelWindowSeconds)

        sosTask = Task { [weak self] in
            guard let self else { return }
            await self.runSOSSequence(simulated: simulated)
        }
    }

    /// 取消本次触发（仅在倒计时窗口内有效）。
    func cancelSOS() {
        guard case .countingDown = phase else { return }
        cancellationRequested = true
        sosTask?.cancel()
        locationTask?.cancel()
        phase = .idle
        lastTriggerSummary = "已取消：未发送任何求助消息（防误触生效）。"
    }

    /// 触发完成后手动复位（界面点「复位」回到待机）。
    func resetSOS() {
        guard phase == .finished else { return }
        phase = .idle
    }

    // MARK: - 内部执行

    private func runSOSSequence(simulated: Bool) async {
        // 0) 短暂连续响铃/震动，提醒注意
        await playRepeatedAlertFeedback()

        // 1) 并行取当前位置（15s 超时兜底；取消时一并终止，不阻塞）
        locationTask = Task { [weak self] in
            guard let self else { return nil }
            return await self.fetchLocationTextWithTimeout()
        }

        // 2) 10 秒取消窗口（防误触）
        for remaining in stride(from: cancelWindowSeconds - 1, through: 0, by: -1) {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !cancellationRequested, !Task.isCancelled else {
                locationTask?.cancel()
                return
            }
            phase = .countingDown(remaining: remaining)
        }
        guard !cancellationRequested, !Task.isCancelled else {
            locationTask?.cancel()
            return
        }

        // 3) 取位置结果并拼求助信息（取不到位置 → 诚实用纯文案）
        let locationText = await locationTask?.value
        locationTask = nil
        lastLocationText = locationText
        let message = composedMessage(locationText: locationText)

        phase = .sending

        // ① 本地高优先级通知（NotificationCapability；timeSensitive 级，
        //    critical 级需要 Apple 单独授权的关键通知能力，诚实降级不申请）
        let notifyTitle = simulated ? "【模拟】紧急求助测试" : "🚨 紧急求助"
        do {
            try await NotificationCapability.notify(
                title: notifyTitle,
                body: message,
                sound: nil,
                priority: "urgent"
            )
            notificationFailure = nil
        } catch {
            notificationFailure = "本地通知发送失败：\(error.localizedDescription)"
        }

        // ② 网关发送给预设联系人（失败不阻塞，诚实标「未发送」）
        if simulated {
            lastSendResults = config.emergencyContacts.map {
                EmergencySendResult(contact: $0, delivered: false, detail: "模拟模式：未实际发送")
            }
            lastTriggerSummary = "模拟触发完成：未向联系人发送任何消息（已测试通知链路）。"
        } else {
            await sendToGateway(message: message)
            lastTriggerSummary = sendSummary()
        }

        // ③ 收尾响铃/震动
        playAlertFeedback()

        phase = .finished
    }

    /// 拼装求助信息：
    /// - 开启位置且取到位置 → 「紧急求助：我在[地址/坐标]，请尽快联系我。」
    /// - 否则 → 使用自定义/默认 sosMessage（不塞假位置，诚实降级）。
    func composedMessage(locationText: String?) -> String {
        let base = config.sosMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let core = base.isEmpty ? "紧急求助，请尽快联系我！" : base
        if config.includeLocation, let locationText, !locationText.isEmpty {
            return "紧急求助：我在\(locationText)，请尽快联系我。"
        }
        return core
    }

    /// 网关发送：频道联系人走 chat.send（与 ChatViewModel 同款 WebSocket 通道）；
    /// 电话联系人无法代发（网关没有电话/短信通道），诚实标「未发送」。
    private func sendToGateway(message: String) async {
        guard let settings, settings.isConfigured,
              let wsURL = URL(string: settings.settings.resolvedWebSocketURL)
        else {
            lastSendResults = config.emergencyContacts.map {
                EmergencySendResult(contact: $0, delivered: false, detail: "网关未配置：未发送")
            }
            return
        }

        var results: [EmergencySendResult] = []
        for contact in config.emergencyContacts {
            switch EmergencyConfig.kind(of: contact) {
            case .phone:
                results.append(EmergencySendResult(
                    contact: contact,
                    delivered: false,
                    detail: "电话联系人：需手动拨号（iOS 不允许自动拨号）"
                ))

            case .gatewayChannel:
                guard let sessionKey = sessionKey(forChannelNamed: contact) else {
                    results.append(EmergencySendResult(
                        contact: contact,
                        delivered: false,
                        detail: "未发送：找不到名为「\(contact)」的频道"
                    ))
                    continue
                }

                let gateway = GatewayWebSocket(url: wsURL, token: settings.gatewayToken)
                do {
                    try await gateway.connect()
                    let _: ChatSendResponse = try await gateway.requestDecoded(
                        method: "chat.send",
                        params: [
                            "sessionKey": AnyCodable(sessionKey),
                            "message": AnyCodable(message),
                            "thinking": AnyCodable(""),
                            "idempotencyKey": AnyCodable(UUID().uuidString),
                            "timeoutMs": AnyCodable(10000)
                        ],
                        timeoutMs: 12000
                    )
                    await gateway.shutdown()
                    results.append(EmergencySendResult(
                        contact: contact,
                        delivered: true,
                        detail: "已发送到频道「\(contact)」"
                    ))
                } catch {
                    await gateway.shutdown()
                    results.append(EmergencySendResult(
                        contact: contact,
                        delivered: false,
                        detail: "未发送：\(error.localizedDescription)"
                    ))
                }
            }
        }
        lastSendResults = results
    }

    /// 触发结果人读摘要（诚实：多少已发送/未发送）。
    private func sendSummary() -> String {
        let delivered = lastSendResults.filter(\.delivered).count
        let failed = lastSendResults.count - delivered
        if lastSendResults.isEmpty {
            return "未发送：没有可用的联系人。"
        }
        if failed == 0 {
            return "已向 \(delivered) 个联系人发送求助。"
        }
        if delivered > 0 {
            return "已发送 \(delivered) 个，\(failed) 个未发送（原因见下方明细）。"
        }
        return "\(failed) 个联系人全部未发送成功（网关不可达或联系人无效），见下方明细。"
    }

    /// 短暂响铃/震动：iOS 内置警报音 1104 + 震动 + 重触感。
    /// 1104 为系统内置系统音 ID（无公开常量名），如需更大音量可替换为自定义音频文件。
    private func playAlertFeedback() {
        AudioServicesPlaySystemSound(1104)
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }

    private func playRepeatedAlertFeedback() async {
        for _ in 0..<3 {
            playAlertFeedback()
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
    }

    // MARK: - 定位（15s 超时兜底）

    /// 取位置文案：先取 CLLocation（15s 超时），再反地理编码（5s 超时），
    /// 失败/超时/权限拒绝一律返回 nil，由调用方诚实降级为纯文案，不阻塞求助。
    private func fetchLocationTextWithTimeout() async -> String? {
        let fetcher = SOSLocationFetcher()
        do {
            // Location (15s timeout): snapshot coordinates inside the group
            // to avoid crossing non-Sendable CLLocation between tasks.
            let location = try await withThrowingTaskGroup(of: SOSLocationSnapshot.self) { group in
                group.addTask {
                    let value = try await fetcher.requestLocation()
                    return SOSLocationSnapshot(
                        latitude: value.coordinate.latitude,
                        longitude: value.coordinate.longitude
                    )
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(self.locationTimeoutSeconds * 1_000_000_000))
                    throw SOSLocationError.timeout
                }
                guard let first = try await group.next() else { throw SOSLocationError.timeout }
                group.cancelAll()
                return first
            }

            // Reverse geocode (5s timeout)
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await Self.reverseGeocode(
                        latitude: location.latitude,
                        longitude: location.longitude
                    )
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(self.geocodeTimeoutSeconds * 1_000_000_000))
                    throw SOSLocationError.timeout
                }
                guard let first = try await group.next() else { throw SOSLocationError.timeout }
                group.cancelAll()
                return first
            }
        } catch {
            return nil
        }
    }

    /// 反地理编码：优先返回「地名·区县·街道」，失败返回经纬度坐标。
    private static func reverseGeocode(latitude: Double, longitude: Double) async throws -> String {
        let geocoder = CLGeocoder()
        let placemarks = try await geocoder.reverseGeocodeLocation(
            CLLocation(latitude: latitude, longitude: longitude),
            preferredLocale: Locale(identifier: "zh_CN")
        )
        if let placemark = placemarks.first {
            let parts = [placemark.name, placemark.locality, placemark.subLocality, placemark.thoroughfare]
                .compactMap { $0 }
            if !parts.isEmpty {
                return parts.joined(separator: "·")
            }
        }
        return String(format: "%.6f, %.6f", latitude, longitude)
    }

    /// 频道名 → 网关会话 key（与 ChatViewModel.sessionKey 相同的推导规则）。
    private func sessionKey(forChannelNamed name: String) -> String? {
        guard let channel = ChannelStore.shared.channels.first(where: { $0.name == name }) else { return nil }
        if let external = channel.serverSessionKey, !external.isEmpty { return external }
        let base = "agent:\(channel.agentId):clawtalk-user:\(client.deviceID):\(channel.id.uuidString.prefix(8).lowercased())"
        return channel.sessionVersion > 0 ? "\(base)-v\(channel.sessionVersion)" : base
    }

    // MARK: - 手动拨号兜底（诚实：仅打开系统拨号盘，需用户确认拨打）

    /// 打开系统拨号盘（tel://）。仅对电话联系人有效；频道联系人返回 false。
    /// iOS 不允许 App 自动拨号，这里只跳到拨号界面，用户仍需手动点拨打。
    @discardableResult
    func manualCall(contact: String) -> Bool {
        guard case .phone(let number) = EmergencyConfig.kind(of: contact) else { return false }
        let cleaned = number.filter { $0.isNumber || $0 == "+" }
        guard let url = URL(string: "tel://\(cleaned)") else { return false }
        UIApplication.shared.open(url)
        return true
    }

    // MARK: - 深链兜底入口

    /// 深链入口：clawtalk://sos 或 clawtalk://sos?simulate=1（模拟触发，测试用）。
    /// 锁屏小组件/快捷指令把 widgetURL 指到该链接，点击后打开 App 即触发。
    /// 接线（主智能体在 ClawTalkApp.onOpenURL 中调用）：
    /// `if !EmergencyStore.handleSOSDeepLink(url) { DeepLinkHandler.handle(url, settings: settingsStore) }`
    nonisolated static func handleSOSDeepLink(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == DeepLinkHandler.scheme,
              components.host?.lowercased() == "sos"
        else { return false }
        let simulate = components.queryItems?.first { $0.name == "simulate" }?.value == "1"
        Task { @MainActor in
            EmergencyStore.shared.triggerSOS(simulated: simulate)
        }
        return true
    }
}

// MARK: - 一次性定位取数器

/// Sendable coordinate snapshot (avoids crossing non-Sendable CLLocation between tasks).
private struct SOSLocationSnapshot: Sendable {
    let latitude: Double
    let longitude: Double
}

private enum SOSLocationError: LocalizedError {
    case timeout
    case denied

    var errorDescription: String? {
        switch self {
        case .timeout: return "定位请求超时"
        case .denied: return "定位权限被拒绝或定位服务不可用"
        }
    }
}

/// 一次性定位取数器（仿 LocationCapability.LocationDelegate，增加防重复续期保护）。
private final class SOSLocationFetcher: NSObject, CLLocationManagerDelegate {
    private var locationContinuation: CheckedContinuation<CLLocation, Error>?
    private var authorizationContinuation: CheckedContinuation<Void, Error>?
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func requestLocation() async throws -> CLLocation {
        guard CLLocationManager.locationServicesEnabled() else {
            throw SOSLocationError.denied
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            try await waitForAuthorization()
        case .denied, .restricted:
            throw SOSLocationError.denied
        case .authorizedWhenInUse, .authorizedAlways:
            break
        @unknown default:
            throw SOSLocationError.denied
        }
        manager.requestLocation()
        return try await waitForLocation()
    }

    private func waitForAuthorization() async throws {
        try await withCheckedThrowingContinuation { continuation in
            authorizationContinuation = continuation
        }
    }

    private func waitForLocation() async throws -> CLLocation {
        try await withCheckedThrowingContinuation { continuation in
            locationContinuation = continuation
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            authorizationContinuation?.resume()
            authorizationContinuation = nil
        case .denied, .restricted:
            authorizationContinuation?.resume(throwing: SOSLocationError.denied)
            authorizationContinuation = nil
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        locationContinuation?.resume(returning: location)
        locationContinuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        locationContinuation?.resume(throwing: error)
        locationContinuation = nil
    }
}
