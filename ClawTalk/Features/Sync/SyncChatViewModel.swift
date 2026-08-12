import Foundation
import SwiftUI

/// 三端同步消息（手机 / 电脑 AutoClaw / 桌面 AI 统一对话历史中的一条）
struct SyncMessage: Identifiable, Equatable {
    enum Role: String {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    let content: String
    let timestamp: Date
    /// 本地乐观追加、等待下一次 /sync 轮询确认的消息（显示「发送中…」）
    var isLocalPending: Bool
    /// 本地发送失败（保留在列表里可重试，不进入历史上下文）
    var hasSendError: Bool
}

/// 桥的 /sync 接口响应（仅含 ts/role/content 三字段）
struct SyncHistoryResponse: Codable {
    struct Item: Codable {
        let ts: String
        let role: String
        let content: String
    }
    let messages: [Item]
}

/// 三端同步聊天页 ViewModel：
/// - 数据源：GET http://<网关host>:18991/sync（codex）/ :18992/sync（claude）
/// - 每 3 秒轮询全历史，按 ts 排序、以 ts-role-content 稳定键增量去重追加
/// - 发送：走现有网关 chat（model=openclaw:<agentId>），回复由桥写入 /sync 后轮询带回
/// - 本地黑名单：删除单条 / 清空聊天只影响手机端显示，不动桥上的 /sync 文件
@Observable
@MainActor
final class SyncChatViewModel {
    private let settings: SettingsStore
    let agentId: String
    let channelName: String

    private(set) var messages: [SyncMessage] = []
    var errorMessage: String?
    var isLoading = false
    private(set) var isSending = false

    private let openClaw = OpenClawClient()
    private var pollTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    /// 已展示消息的服务端稳定键（ts-role-content），轮询增量追加的判重依据
    private var seenKeys: Set<String> = []
    /// 等待服务端确认的本地乐观消息键（role-content）
    private var pendingLocalKeys: Set<String> = []

    // MARK: - 本地黑名单（只影响手机端显示，不动桥上的 /sync 文件）

    private let defaults = UserDefaults.standard
    private var deletedKeysDefaultsKey: String { "syncBlacklist.\(agentId)" }
    private var clearTimeDefaultsKey: String { "syncClearTime.\(agentId)" }

    /// 被删除单条消息的稳定键（ts-role-content），按频道（agentId）隔离
    private var deletedKeys: Set<String> {
        get { Set(defaults.stringArray(forKey: deletedKeysDefaultsKey) ?? []) }
        set { defaults.set(Array(newValue), forKey: deletedKeysDefaultsKey) }
    }

    /// 清空时间点：记录后只显示该时间之后的消息
    private var clearTimestamp: Date? {
        get {
            let time = defaults.double(forKey: clearTimeDefaultsKey)
            return time > 0 ? Date(timeIntervalSince1970: time) : nil
        }
        set {
            if let newValue {
                defaults.set(newValue.timeIntervalSince1970, forKey: clearTimeDefaultsKey)
            } else {
                defaults.removeObject(forKey: clearTimeDefaultsKey)
            }
        }
    }

    init(settings: SettingsStore, agentId: String, channelName: String) {
        self.settings = settings
        self.agentId = agentId
        self.channelName = channelName
    }

    /// 三端同步地址：从网关地址提取主机，codex 桥 18991 / claude 桥 18992
    var syncBaseURL: String {
        let port = agentId == "codex" ? 18991 : 18992
        return "http://\(Self.host(from: settings.settings.gatewayURL)):\(port)/sync"
    }

    // MARK: - 轮询

    /// 视图出现时启动：立即拉一次全历史，之后每 3 秒增量刷新
    func startPolling() {
        guard pollTask == nil else { return }
        let task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        pollTask = task
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// 拉取 /sync 全历史并按 ts 增量合并
    func refresh() async {
        let trimmedURL = settings.settings.gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            errorMessage = "三端同步不可用：请先在设置中填写网关地址。"
            return
        }
        guard let url = URL(string: syncBaseURL) else {
            errorMessage = "三端同步地址无效：请检查网关地址。"
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            guard (200...299).contains(http.statusCode) else {
                throw SyncLoadError.httpStatus(http.statusCode)
            }
            let decoded = try JSONDecoder().decode(SyncHistoryResponse.self, from: data)
            merge(serverItems: decoded.messages)
            errorMessage = nil
        } catch {
            // 已有消息时保留旧列表，只提示不打断；空列表时给全屏错误 + 重试
            let hint = messages.isEmpty ? "无法连接三端同步服务：" : "同步刷新失败："
            errorMessage = "\(hint)\(AppErrorText.localized(error.localizedDescription))"
        }
    }

    // MARK: - 合并去重（加载与轮询共用，过滤本地黑名单）

    private func merge(serverItems: [SyncHistoryResponse.Item]) {
        let parsed = serverItems.compactMap { item -> (ts: Date, role: SyncMessage.Role, content: String)? in
            guard let ts = Self.parseTimestamp(item.ts) else { return nil }
            let role: SyncMessage.Role = item.role.lowercased() == "user" ? .user : .assistant
            let content = item.content
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return (ts, role, content)
        }

        for item in parsed.sorted(by: { $0.ts < $1.ts }) {
            let stableKey = Self.stableKey(ts: item.ts, role: item.role, content: item.content)
            if seenKeys.contains(stableKey) { continue }
            // 本地黑名单：已删除的单条消息不再重新出现
            if deletedKeys.contains(stableKey) {
                seenKeys.insert(stableKey)
                continue
            }
            // 清空时间点：只显示清空之后的消息
            if let clearTime = clearTimestamp, item.ts < clearTime { continue }

            let pendingKey = "\(item.role.rawValue)-\(item.content)"
            if pendingLocalKeys.contains(pendingKey) {
                // 服务端已确认本机刚发的消息：原地替换为服务端版本（保留 id 与滚动位置）
                if let idx = messages.lastIndex(where: {
                    $0.isLocalPending && !$0.hasSendError
                        && $0.role == item.role && $0.content == item.content
                }) {
                    messages[idx] = SyncMessage(
                        id: messages[idx].id,
                        role: item.role,
                        content: item.content,
                        timestamp: item.ts,
                        isLocalPending: false,
                        hasSendError: false
                    )
                }
                pendingLocalKeys.remove(pendingKey)
                seenKeys.insert(stableKey)
                continue
            }

            messages.append(SyncMessage(
                id: UUID(),
                role: item.role,
                content: item.content,
                timestamp: item.ts,
                isLocalPending: false,
                hasSendError: false
            ))
            seenKeys.insert(stableKey)
        }
    }

    // MARK: - 本地黑名单操作

    /// 删除单条消息：本地记录稳定键（ts-role-content），只影响本机显示
    func deleteMessage(_ message: SyncMessage) {
        messages.removeAll { $0.id == message.id }
        // 待确认消息保留 pendingKey：轮询确认时按「原地替换」分支吞掉服务端版本，避免删除后重新出现
        if message.isLocalPending { return }
        // 发送失败消息只存在于本地，无需记录黑名单
        guard !message.hasSendError else { return }
        var keys = deletedKeys
        keys.insert(Self.stableKey(ts: message.timestamp, role: message.role, content: message.content))
        deletedKeys = keys
    }

    /// 清空聊天：记录清空时间点，只显示之后的消息（不影响桥上的历史文件）
    func clearHistory() {
        let cutoff = Date()
        clearTimestamp = cutoff
        messages.removeAll { $0.timestamp < cutoff }
    }

    // MARK: - 语音输入（按住说话 → STT 填入输入框，与其他聊天页一致）

    private let audioCapture = AudioCaptureManager()
    private(set) var isRecordingVoiceInput = false
    private(set) var isTranscribingVoice = false
    var voiceInputError: String?

    func startVoiceInput() {
        guard !isRecordingVoiceInput, !isTranscribingVoice else { return }
        VoiceWakeCapability.shared.stopListening()
        do {
            try audioCapture.startRecording()
            isRecordingVoiceInput = true
        } catch {
            voiceInputError = "麦克风访问失败：\(AppErrorText.localized(error.localizedDescription))"
        }
    }

    func stopVoiceInputAndTranscribe(appendTo completion: @escaping (String) -> Void) {
        guard isRecordingVoiceInput else { return }
        isRecordingVoiceInput = false
        let samples = audioCapture.stopRecording()
        guard samples.count > 8000 else {
            isTranscribingVoice = false
            return
        }
        isTranscribingVoice = true
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.isTranscribingVoice = false
                NotificationCenter.default.post(name: .clawTalkWakeRestartRequested, object: nil)
            }
            do {
                guard let stt = self.makeTranscriptionService() else {
                    self.voiceInputError = "语音转文字服务未配置，请在设置中开启语音输入。"
                    return
                }
                let transcript = try await stt.transcribe(audioSamples: samples)
                let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    completion(trimmed)
                }
            } catch {
                self.voiceInputError = "转写失败：\(AppErrorText.localized(error.localizedDescription))"
            }
        }
    }

    private func makeTranscriptionService() -> (any TranscriptionService)? {
        let s = settings.settings
        switch s.sttProvider {
        case .doubao:
            if let key = SecureStorage.shared.doubaoAPIKey, !key.isEmpty {
                return DoubaoSTTService(apiKey: key, language: s.whisperLanguage)
            }
            return AppleSTTService(language: s.whisperLanguage)
        case .apple:
            return AppleSTTService(language: s.whisperLanguage)
        }
    }

    // MARK: - 发送

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        guard settings.isConfigured else {
            errorMessage = "三端同步发送不可用：请在设置中配置 OpenClaw 网关。"
            return
        }
        errorMessage = nil

        // 本地乐观追加，等待轮询确认（避免等待期间用户看不到自己的消息）
        let local = SyncMessage(
            id: UUID(),
            role: .user,
            content: trimmed,
            timestamp: Date(),
            isLocalPending: true,
            hasSendError: false
        )
        messages.append(local)
        pendingLocalKeys.insert("\(local.role.rawValue)-\(local.content)")
        isSending = true

        // 上下文只含服务端已确认的历史（不含发送失败/待确认的本地消息）
        let history = messages
            .filter { !$0.isLocalPending && !$0.hasSendError }
            .map { Message(role: $0.role == .user ? .user : .assistant, content: $0.content) }

        sendTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isSending = false }
            do {
                let token = OpenClawClient.resolveHTTPToken(
                    settingsToken: self.settings.gatewayToken,
                    gatewayURL: self.settings.settings.gatewayURL
                )
                let eventStream = self.openClaw.stream(
                    messages: history + [Message(role: .user, content: trimmed)],
                    gatewayURL: self.settings.settings.gatewayURL,
                    token: token,
                    model: "openclaw:\(self.agentId)",
                    apiMode: self.settings.settings.agentAPIMode,
                    sessionKey: nil,
                    messageChannel: "webchat"
                )
                // 跑完整个流保持网关连接：回复由桥写入 /sync，轮询自动带回
                for try await _ in eventStream {}
                // 发送成功立即刷新一次，尽快显示自己的消息与服务端回复
                await self.refresh()
            } catch is CancellationError {
                // 页面退出/取消：不打扰用户
            } catch {
                self.markSendFailed(content: trimmed)
                self.errorMessage = "发送失败：\(AppErrorText.localized(error.localizedDescription))"
            }
        }
    }

    /// 发送失败：移除「待确认」标记，保留消息展示「发送失败 + 重试」
    private func markSendFailed(content: String) {
        pendingLocalKeys.remove("user-\(content)")
        if let idx = messages.lastIndex(where: { $0.isLocalPending && $0.content == content }) {
            messages[idx].isLocalPending = false
            messages[idx].hasSendError = true
        }
    }

    /// 重试失败的本地消息（原内容重新发送）
    func retryFailedMessage(content: String) {
        messages.removeAll { $0.hasSendError && $0.content == content }
        send(content)
    }

    // MARK: - 工具

    /// 从网关 URL 提取主机（去协议/端口/路径），用于拼 http://<host>:1899x/sync
    static func host(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let host = url.host, !host.isEmpty {
            return host
        }
        var stripped = trimmed
        for prefix in ["https://", "http://", "wss://", "ws://"] where stripped.hasPrefix(prefix) {
            stripped = String(stripped.dropFirst(prefix.count))
            break
        }
        let hostPort = stripped.split(separator: "/").first.map(String.init) ?? stripped
        return hostPort.split(separator: ":").first.map(String.init) ?? hostPort
    }

    /// 兼容多种时间格式：ISO8601（含小数秒）/ 秒级时间戳 / 毫秒级时间戳
    static func parseTimestamp(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let epoch = Double(trimmed) {
            let seconds = epoch > 1_000_000_000_000 ? epoch / 1000 : epoch
            return Date(timeIntervalSince1970: seconds)
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: trimmed) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) { return date }
        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let date = fallback.date(from: trimmed) { return date }
        fallback.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return fallback.date(from: trimmed)
    }

    /// 服务端消息稳定键（ts-role-content），单条删除黑名单的判重依据
    static func stableKey(ts: Date, role: SyncMessage.Role, content: String) -> String {
        "\(ts.timeIntervalSince1970)-\(role.rawValue)-\(content)"
    }
}

/// 同步服务加载错误
enum SyncLoadError: LocalizedError {
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code):
            return AppErrorText.httpStatus(code)
        }
    }
}
