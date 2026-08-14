import Foundation
import SwiftUI
import UIKit
import AVFoundation

/// 语音助手四种会话状态（对应卡片四种动画）。
enum VoiceAssistantState: Equatable {
    case idle
    case listening
    case thinking
    case speaking
}

/// 语音助手专用错误。
enum VoiceAssistantError: LocalizedError {
    case notConfigured(String)
    case busy
    case emptyReply
    case timeout

    var errorDescription: String? {
        switch self {
        case .notConfigured(let message): return message
        case .busy: return "聊天页正在使用麦克风或朗读，请稍后再试。"
        case .emptyReply: return "智能体没有返回有效回复。"
        case .timeout: return "等待回复超时，请检查网络后重试。"
        }
    }
}

/// 语音大卡「记录」条目：一轮完整对讲（用户转写 + 智能体回复）。
struct VoiceAssistantTranscriptEntry: Identifiable, Codable, Equatable {
    var id: UUID
    var date: Date
    var userText: String
    var replyText: String
}

/// 语音助手意图（本地规则识别）：记账 / 提醒 / 写文章 / 日记。
enum VoiceIntentKind: String, CaseIterable, Identifiable {
    case expense = "记账"
    case reminder = "提醒"
    case article = "写文章"
    case diary = "日记"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .expense: return "yensign.circle.fill"
        case .reminder: return "bell.fill"
        case .article: return "doc.text.fill"
        case .diary: return "book.fill"
        }
    }
}

/// 待确认意图：识别到后在语音大卡展示确认条，用户确认才写入对应本地 Store。
struct PendingVoiceIntent: Identifiable, Equatable {
    let id = UUID()
    let kind: VoiceIntentKind
    let summary: String
    let userText: String
}

/// 随身语音助手「连续对讲」会话管理器。
///
/// 状态机（一轮连续对讲）：
///
///   idle ──startConversation──▶ listening
///   listening ──VAD 检测到说话（停顿自动结束）──▶ thinking
///   thinking ──转写 + 智能体回复完成──▶ speaking
///   speaking ──朗读完成──▶ listening（下一轮，轮数 +1）
///   speaking ──用户开口打断──▶ listening（不计数，优先听）
///   任意状态 ──stopConversation / 长按退出 / 达 maxRounds──▶ idle
///
/// 说明：
/// - 「3 秒无新声音自动结束说话」由 AudioCaptureManager 的 VAD 实现
///   （内部 silenceDuration=0.5s + 最少 12000 采样），本类直接复用，不重复造轮子。
/// - 朗读（TTS）由本类自己驱动（场景音量/打断需要）；
/// - 发送链路双模式：
///   - 独立路径（默认）：本类自己持有 OpenClawClient，走网关流式发送
///     （OpenClawClient.stream + model "openclaw:<agentId>"，与 SyncChatViewModel.send 同链路），
///     主页不依赖聊天页，没进过聊天也能用；
///   - 兼容路径（宿主注入了 chatViewModel）：复用 ChatViewModel 的 sendText + messages 轮询，
///     并持续抑制其自带朗读（详见 requestAgentReply）。
@Observable
@MainActor
final class VoiceAssistantViewModel {

    // MARK: - 状态（工程统一用 @Observable，等价任务要求的 @Published，供卡片绑定）

    /// 当前会话状态：idle / listening / thinking / speaking。
    private(set) var state: VoiceAssistantState = .idle

    /// 最近一次错误（展示在卡片或日志）。
    var errorMessage: String? {
        didSet {
            if let errorMessage {
                LogCollector.record(module: "语音助手", errorMessage)
            }
        }
    }

    /// 当前场景模式：卡片右上角按钮循环切换（normal/driving/night）。
    /// 本类用 UserDefaults 兜底持久化（voiceAssistant.sceneMode）；
    /// 若后续主智能体在 AppSettings 增加 voiceAssistantScene 字段，可改由设置存储承载。
    var sceneMode: VoiceSceneMode = .normal

    /// 已完成轮数（被打断不计入）。
    private(set) var roundCount = 0

    /// 本轮用户说的话（供 UI/调试展示）。
    private(set) var lastTranscript = ""

    /// 本轮智能体回复文本（供 UI/调试展示）。
    private(set) var lastReply = ""

    /// 连续对讲最大轮数：达到自动结束，防止无人值守死循环；
    /// 卡片同时支持「长按退出」随时手动结束。
    let maxRounds = 20

    // MARK: - 依赖

    private let audioCapture = AudioCaptureManager()
    private let audioPlayback = AudioPlaybackManager()
    private var transcriptionService: (any TranscriptionService)?
    private var speechService: (any SpeechService)?
    /// 设置存储：独立发送时读取网关地址/令牌/API 模式。
    private let settings: SettingsStore
    /// 兼容路径：宿主（主页/聊天页）可注入 ChatViewModel，走原有 sendText + 轮询发送。
    private var chatViewModel: ChatViewModel?
    /// 网关连接（可选）：当前独立发送走 OpenClawClient HTTP 流式，与 SyncChatViewModel.send
    /// 一致；保留该引用供后续 WebSocket 直连扩展。
    private let gatewayConnection: GatewayConnection?
    /// 目标智能体 ID：默认 "main"，或 settings 里的默认频道（唤醒频道/首个频道）的 agentId。
    private let agentId: String
    /// 独立发送链路持有的 OpenClawClient（与 SyncChatViewModel 同模式）。
    private let openClaw = OpenClawClient()
    /// 本地记忆档案（直连 DeepSeek 通道注入用；懒加载，读不到时诚实降级为无档案）。
    private var cachedMemoryStore: MemoryProfileStore?
    private var memoryStore: MemoryProfileStore {
        if let store = cachedMemoryStore { return store }
        let store = MemoryProfileStore(settings: settings)
        if store.profiles.isEmpty {
            store.refreshFromConversations()
        }
        cachedMemoryStore = store
        return store
    }
    /// 连续对讲内的上下文历史（独立路径；每轮结束后保留，最多 20 条）。
    private var conversationHistory: [Message] = []

    private var sessionTask: Task<Void, Never>?
    private var interruptedDuringSpeaking = false

    /// 主初始化：不依赖 ChatViewModel，语音助手可独立于聊天页工作。
    /// - Parameters:
    ///   - settings: 设置存储（网关地址/令牌/API 模式/STT 语言/TTS 参数）
    ///   - gatewayConnection: 可选网关连接（保留给后续 WebSocket 直连）
    ///   - agentId: 目标智能体 ID；传 nil 时取 settings 里的默认频道，兜底 "main"
    ///   - chatViewModel: 兼容路径：传入时复用原 sendText + 轮询发送链路
    init(
        settings: SettingsStore,
        gatewayConnection: GatewayConnection? = nil,
        agentId: String? = nil,
        chatViewModel: ChatViewModel? = nil
    ) {
        self.settings = settings
        self.gatewayConnection = gatewayConnection
        self.agentId = agentId ?? Self.resolveDefaultAgentID(settings: settings)
        self.chatViewModel = chatViewModel
        self.sceneMode = Self.loadSceneMode()
        // 自建服务兜底：App 层未注入（主页独立创建路径）时按设置自建 STT/TTS，避免「只聆听不回复」。
        bootstrapServicesIfNeeded()
    }

    /// 兼容旧调用方：仅传入 ChatViewModel（聊天页内嵌场景）。
    @available(*, deprecated, message: "请改用 init(settings:gatewayConnection:agentId:chatViewModel:)")
    convenience init(chatViewModel: ChatViewModel) {
        self.init(settings: SettingsStore(), chatViewModel: chatViewModel)
    }

    /// 由 App 层接线（与 ChatViewModel.configure 同模式），传入 STT/TTS 服务。
    func configure(transcription: (any TranscriptionService)?, speech: any SpeechService) {
        transcriptionService = transcription
        speechService = speech
    }

    /// 按当前设置自建 STT/TTS（与 ClawTalkApp.configureServices 同逻辑）；已注入则不覆盖。
    private func bootstrapServicesIfNeeded() {
        guard speechService == nil || transcriptionService == nil else { return }
        let secure = SecureStorage.shared
        let s = settings.settings
        if transcriptionService == nil {
            let stt: (any TranscriptionService)?
            if !s.voiceInputEnabled {
                stt = nil
            } else {
                switch s.sttProvider {
                case .apple:
                    stt = AppleSTTService(language: s.whisperLanguage)
                case .doubao:
                    if let key = secure.doubaoAPIKey, !key.isEmpty {
                        let doubao = DoubaoSTTService(apiKey: key, language: s.whisperLanguage)
                        // 流式转写：逐句中间结果实时上屏（voiceAssistantShowTranscript 开启时生效）
                        doubao.onPartialTranscript = { [weak self] text in
                            guard let self, self.settings.settings.voiceAssistantShowTranscript else { return }
                            Task { @MainActor in
                                if !text.isEmpty { self.lastTranscript = text }
                            }
                        }
                        stt = doubao
                    } else {
                        stt = AppleSTTService(language: s.whisperLanguage)
                    }
                }
            }
            transcriptionService = stt
        }
        if speechService == nil {
            let tts: any SpeechService = {
                switch s.ttsProvider {
                case .apple:
                    return AppleTTSService(speed: s.ttsSpeed, pitch: s.ttsPitch)
                case .doubao:
                    if let key = secure.doubaoAPIKey, !key.isEmpty {
                        return DoubaoTTSService(apiKey: key, voiceID: s.doubaoVoiceID)
                    }
                    return AppleTTSService(speed: s.ttsSpeed, pitch: s.ttsPitch)
                case .edge:
                    return EdgeTTSService(voiceID: s.edgeVoiceID, speed: s.ttsSpeed, pitch: s.ttsPitch)
                }
            }()
            speechService = tts
        }
    }

    /// 当前输入音量（VAD 平滑 RMS），供「说话」声波动画使用。
    var audioLevel: Float {
        audioCapture.currentLevel
    }

    /// 麦克风引擎是否在运行（对讲中为 true；空闲时引擎已停止，避免占麦与耗电）。
    var isMicActive: Bool {
        audioCapture.isRecording
    }

    var isActive: Bool {
        state != .idle
    }

    /// 语音助手大卡是否显示实时转写/回复文字（只读透传 AppSettings 开关，设置页可切换）。
    var voiceAssistantShowTranscript: Bool {
        settings.settings.voiceAssistantShowTranscript
    }
    // MARK: - 对话记录（大卡「记录」入口数据源）

    /// 对话记录存储 key（UserDefaults 落盘，真实对讲流水，非假数据）。
    private static let transcriptDefaultsKey = "clawtalk.voiceAssistant.transcript"
    /// 记录条数上限：超出丢弃最旧，避免无限增长。
    private static let transcriptMaxCount = 100

    /// 历史对话记录（最新在前）。
    var transcriptEntries: [VoiceAssistantTranscriptEntry] {
        Self.loadTranscript()
    }

    /// 当前记录条数（供卡片角标）。
    var transcriptCount: Int {
        transcriptEntries.count
    }

    /// 追加一轮对话记录（转写与回复均非空才记）。
    func recordTranscript(userText: String, replyText: String) {
        let trimmedUser = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedReply = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUser.isEmpty, !trimmedReply.isEmpty else { return }
        var entries = Self.loadTranscript()
        entries.insert(
            VoiceAssistantTranscriptEntry(id: UUID(), date: Date(), userText: trimmedUser, replyText: trimmedReply),
            at: 0
        )
        if entries.count > Self.transcriptMaxCount {
            entries = Array(entries.prefix(Self.transcriptMaxCount))
        }
        Self.saveTranscript(entries)
    }

    /// 清空全部对话记录。
    func clearTranscript() {
        UserDefaults.standard.removeObject(forKey: Self.transcriptDefaultsKey)
    }

    private static func loadTranscript() -> [VoiceAssistantTranscriptEntry] {
        guard let data = UserDefaults.standard.data(forKey: transcriptDefaultsKey),
              let entries = try? JSONDecoder().decode([VoiceAssistantTranscriptEntry].self, from: data) else {
            return []
        }
        return entries
    }

    private static func saveTranscript(_ entries: [VoiceAssistantTranscriptEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: transcriptDefaultsKey)
    }
    // MARK: - 记忆沉淀与意图分发（v049）

    /// 待确认意图（语音大卡确认条数据源）；nil = 无可确认意图。
    private(set) var pendingIntent: PendingVoiceIntent?
    /// 最近一次意图执行反馈（如「已记入记账：…」），6 秒后自动消失。
    private(set) var lastIntentFeedback: String?

    private var cachedExpenseStore: ExpenseStore?
    private var expenseStore: ExpenseStore {
        if let store = cachedExpenseStore { return store }
        let store = ExpenseStore()
        cachedExpenseStore = store
        return store
    }
    private var cachedWritingStore: WritingStore?
    private var writingStore: WritingStore {
        if let store = cachedWritingStore { return store }
        let store = WritingStore()
        cachedWritingStore = store
        return store
    }
    private var cachedCareReminderStore: CareReminderStore?
    private var careReminderStore: CareReminderStore {
        if let store = cachedCareReminderStore { return store }
        let store = CareReminderStore()
        cachedCareReminderStore = store
        return store
    }
    private var feedbackClearTask: Task<Void, Never>?
    private static let voiceDiaryDefaultsKey = "voice_assistant_diary_entries_v1"

    /// 对话记忆沉淀：把本轮 user+assistant 文本喂给本地记忆（失败静默，不影响对话）。
    private func absorbConversationMemory(userText: String, replyText: String) {
        memoryStore.absorb(
            userText: userText,
            assistantText: replyText,
            source: "语音助手"
        )
    }

    /// 意图分发（轻量本地规则）：识别记账/提醒/写文章/日记并提取参数。
    /// 识别不到就静默不提示（诚实）；识别到只展示「待确认」，不自动写入。
    private func dispatchIntentIfNeeded(userText: String) {
        guard pendingIntent == nil else { return }
        if let draft = ExpenseVoiceParser.parse(userText) {
            pendingIntent = PendingVoiceIntent(
                kind: .expense,
                summary: "记一笔：\(Self.expensePreview(draft))，对吗？",
                userText: userText
            )
            return
        }
        if Self.hasReminderIntent(userText) {
            pendingIntent = PendingVoiceIntent(
                kind: .reminder,
                summary: "设提醒：\(Self.reminderPreview(userText))，对吗？",
                userText: userText
            )
            return
        }
        if Self.hasArticleIntent(userText) {
            pendingIntent = PendingVoiceIntent(
                kind: .article,
                summary: "帮你存一篇写文章草稿：\(Self.preview(userText))，对吗？",
                userText: userText
            )
            return
        }
        if Self.hasDiaryIntent(userText) {
            pendingIntent = PendingVoiceIntent(
                kind: .diary,
                summary: "帮你记日记：\(Self.preview(userText))，对吗？",
                userText: userText
            )
        }
    }

    /// 确认待确认意图：执行写入并展示「已记入…」反馈。
    func confirmPendingIntent() {
        guard let intent = pendingIntent else { return }
        pendingIntent = nil
        lastIntentFeedback = executeIntent(intent)
        feedbackClearTask?.cancel()
        feedbackClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.lastIntentFeedback = nil
        }
    }

    /// 取消待确认意图。
    func cancelPendingIntent() {
        pendingIntent = nil
    }

    private func executeIntent(_ intent: PendingVoiceIntent) -> String {
        switch intent.kind {
        case .expense:
            guard let draft = ExpenseVoiceParser.parse(intent.userText) else {
                return "记账失败：没有识别出金额"
            }
            guard expenseStore.add(
                amount: draft.amount,
                type: draft.type,
                category: draft.category,
                note: draft.note,
                date: Date()
            ) != nil else {
                return "记账失败：金额无效"
            }
            return "已记入记账：\(draft.amount.expenseAmountText) 元（\(draft.category.rawValue)）"
        case .reminder:
            let added = careReminderStore.add(makeReminder(from: intent.userText))
            return "已加入提醒：\(added.title)"
        case .article:
            let draft = ArticleDraft(
                title: Self.articleTitle(from: intent.userText),
                content: intent.userText,
                outline: [intent.userText],
                tone: .casual,
                generatedByAI: false,
                generationNotice: "语音助手识别意图后由用户确认归档"
            )
            writingStore.add(draft)
            return "已存入写文章草稿"
        case .diary:
            saveDiaryEntry(intent.userText)
            return "已记入日记"
        }
    }

    /// 语音提醒 → CareReminder：优先 VoiceReminderParser 解析，失败兜底 1 小时后（与随手捕捉一致）。
    private func makeReminder(from text: String) -> CareReminder {
        switch VoiceReminderParser.parse(text) {
        case .success(let draft):
            return CareReminder(
                title: draft.title,
                time: draft.time,
                category: draft.category,
                repeatType: draft.repeatType,
                enabled: true,
                scheduledDate: draft.scheduledDate
            )
        case .failure:
            return CareReminder(
                title: VoiceReminderParser.extractTitle(from: text),
                time: Date().addingTimeInterval(3600),
                category: .custom,
                repeatType: .none,
                enabled: true
            )
        }
    }

    /// 语音日记暂存：VoiceDiaryViewModel 无公开写入接口，沿用随手捕捉的本地暂存模模式
    /// （独立 key，避免双写互相覆盖）；待 DiaryStore 落地后由主线程统一接线。
    private func saveDiaryEntry(_ text: String) {
        var entries = Self.loadDiaryEntries()
        entries.insert(DiaryEntry(text: text, category: DiaryCategory.classify(text)), at: 0)
        if entries.count > 200 {
            entries = Array(entries.prefix(200))
        }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.voiceDiaryDefaultsKey)
        }
    }

    private static func loadDiaryEntries() -> [DiaryEntry] {
        guard let data = UserDefaults.standard.data(forKey: voiceDiaryDefaultsKey),
              let decoded = try? JSONDecoder().decode([DiaryEntry].self, from: data) else {
            return []
        }
        return decoded
    }

    // MARK: - 意图识别规则（本地关键词/正则，中文）

    private static func hasReminderIntent(_ text: String) -> Bool {
        // 注意：不含裸「记得」，避免「我记得…」这类叙述被误判为提醒意图
        let keywords = [
            "提醒我", "提醒一下", "别忘了", "别忘", "要记得",
            "帮我设", "帮我设置", "帮我定", "设个提醒", "设置提醒", "设提醒",
            "定个提醒", "安排个提醒", "安排提醒",
        ]
        return keywords.contains { text.contains($0) }
    }

    private static func hasArticleIntent(_ text: String) -> Bool {
        let keywords = ["帮我写", "写篇文章", "写一篇文章", "写个文章", "写文章", "写一篇", "起草"]
        return keywords.contains { text.contains($0) }
    }

    private static func hasDiaryIntent(_ text: String) -> Bool {
        let keywords = ["写日记", "记日记", "记个日记", "记录今天", "记一笔日记"]
        return keywords.contains { text.contains($0) }
    }

    private static func preview(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 18 ? String(trimmed.prefix(18)) + "…" : trimmed
    }

    private static func expensePreview(_ draft: ExpenseVoiceParser.Draft) -> String {
        let note = draft.note.count > 18 ? String(draft.note.prefix(18)) + "…" : draft.note
        return "\(note) \(draft.amount.expenseAmountText) 元（\(draft.category.rawValue)）"
    }

    private static func reminderPreview(_ text: String) -> String {
        switch VoiceReminderParser.parse(text) {
        case .success(let draft):
            return "\(draft.title)（\(Self.timeText(draft.time))）"
        case .failure:
            return "\(VoiceReminderParser.extractTitle(from: text))（1 小时后）"
        }
    }

    private static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }

    private static func articleTitle(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "语音文章" }
        return trimmed.count > 12 ? String(trimmed.prefix(12)) + "…" : trimmed
    }


    // MARK: - 生命周期

    /// 卡片点按入口：空闲 → 开始对讲；对讲中 → 结束。
    func toggle() {
        if state == .idle {
            startConversation()
        } else {
            stopConversation()
        }
    }

    /// 开始连续对讲。
    func startConversation() {
        guard state == .idle else { return }
        // 每次进入重新按当前设置自建 STT/TTS：用户在设置里开启语音输入后立即生效，
        // 避免只在 init 自建导致「语音转文字开着但大卡仍无反应」。
        bootstrapServicesIfNeeded()
        guard ensureMicPermission() else { return }
        guard transcriptionService != nil else {
            errorMessage = "语音转文字服务未配置，请在设置中开启语音输入。"
            return
        }
        if let chatViewModel, chatViewModel.isConversationMode {
            errorMessage = "聊天页免提对话正在使用麦克风，请先退出。"
            return
        }
        // 与语音唤醒/免提对话共用麦克风：开始前先停唤醒，避免两个音频引擎抢麦。
        VoiceWakeCapability.shared.stopListening()

        roundCount = 0
        conversationHistory.removeAll()
        lastTranscript = ""
        lastReply = ""
        errorMessage = nil
        interruptedDuringSpeaking = false

        // 必须先启动录音引擎（麦克风采集 + VAD），再 enableVAD 接管；
        // 漏掉 startRecording 会导致引擎不跑：听不到说话、打断检测也失效。
        do {
            try audioCapture.startRecording()
        } catch {
            errorMessage = "麦克风访问失败：\(AppErrorText.localized(error.localizedDescription))"
            return
        }

        audioCapture.enableVAD(
            onUtterance: { [weak self] samples in
                Task { @MainActor in
                    self?.handleUtterance(samples)
                }
            },
            onAudioChunk: { [weak self] chunk in
                // 流式转写：豆包 STT + 实时转写开关开启时，把音频块喂给流式引擎（中间结果经 onPartialTranscript 上屏）
                guard let self, self.settings.settings.voiceAssistantShowTranscript,
                      let stt = self.transcriptionService as? DoubaoSTTService else { return }
                Task { @MainActor in
                    try? await stt.feedStreaming(samples: chunk)
                }
            },
            onInterrupt: { [weak self] in
                Task { @MainActor in
                    self?.handleInterrupt()
                }
            }
        )
        state = .listening
        applyScreenAwakePolicy()
    }

    /// 结束连续对讲：停录音、停朗读、取消任务。
    func stopConversation() {
        sessionTask?.cancel()
        sessionTask = nil
        audioCapture.stopContinuousRecording()
        speechService?.stop()
        audioPlayback.stop()
        state = .idle
        applyScreenAwakePolicy()
    }

    /// 页面退出/App 生命周期兜底（幂等）。
    func stop() {
        stopConversation()
    }

    /// 清空卡片上显示的错误（错误横幅超时自动消失时调用）。
    func clearErrorMessage() {
        errorMessage = nil
    }

    /// 麦克风权限预检：未授权给出明确引导，不静默失败。
    private func ensureMicPermission() -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            errorMessage = "需要麦克风权限：请到 系统设置 → 隐私与安全性 → 麦克风 开启 ClawTalk 后重试。"
            return false
        case .undetermined:
            // 首次使用：弹系统授权框；用户授权后再点一次即可开始。
            AVAudioApplication.requestRecordPermission { granted in
                if !granted {
                    Task { @MainActor in
                        LogCollector.record(module: "语音助手", "用户拒绝麦克风权限")
                    }
                }
            }
            errorMessage = "请允许麦克风权限后再次点击开始。"
            return false
        @unknown default:
            return true
        }
    }

    // MARK: - 场景模式

    /// 场景模式快速切换（卡片右上角小按钮）：normal → driving → night → normal 循环。
    func cycleSceneMode() {
        guard let idx = VoiceSceneMode.allCases.firstIndex(of: sceneMode) else {
            sceneMode = .normal
            return
        }
        let next = VoiceSceneMode.allCases[(idx + 1) % VoiceSceneMode.allCases.count]
        sceneMode = next
        Self.saveSceneMode(next)
        applyScreenAwakePolicy()
    }

    /// 按场景模式设置屏幕常亮（开车/夜间对讲期间常亮，空闲恢复），与场景快速切换联动。
    private func applyScreenAwakePolicy() {
        UIApplication.shared.isIdleTimerDisabled = state != .idle && sceneMode.keepsScreenAwake
    }

    private static let sceneModeDefaultsKey = "voiceAssistant.sceneMode"

    private static func loadSceneMode() -> VoiceSceneMode {
        guard let raw = UserDefaults.standard.string(forKey: sceneModeDefaultsKey),
              let mode = VoiceSceneMode(rawValue: raw) else {
            return .normal
        }
        return mode
    }

    private static func saveSceneMode(_ mode: VoiceSceneMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: sceneModeDefaultsKey)
    }

    /// 默认目标智能体：优先 settings 里「唤醒后进入的频道」（voiceWakeChannelID），
    /// 其次频道列表第一个频道；都没有则 "main"。

    /// 是否属于「没听到声音」：正常事件，不做错误提示（避免日志刷屏）。
    private static func isNoSpeechError(_ error: Error) -> Bool {
        if let sttError = error as? AppleSTTError {
            if case .noSpeech = sttError { return true }
        }
        let raw = error.localizedDescription.lowercased()
        return raw.contains("no speech") || raw.contains("没有听到")
    }
    private static func resolveDefaultAgentID(settings: SettingsStore) -> String {
        if let wakeChannelID = settings.settings.voiceWakeChannelID,
           let matched = ChannelStore.shared.channels.first(where: { $0.id.uuidString == wakeChannelID }) {
            return matched.agentId
        }
        if let first = ChannelStore.shared.channels.first {
            return first.agentId
        }
        return "main"
    }

    // MARK: - 对话循环

    /// VAD 检测到一次完整说话（停顿自动结束）后的处理。
    private func handleUtterance(_ samples: [Float]) {
        guard state == .listening else { return }
        audioCapture.pauseListening()
        state = .thinking

        sessionTask?.cancel()
        sessionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let transcript = try await transcribe(samples)
                guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    resumeNextRound()
                    return
                }
                lastTranscript = transcript

                let reply = try await requestAgentReply(transcript)
                guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    resumeNextRound()
                    return
                }
                lastReply = reply

                // 记录本轮对话（真实流水，供大卡「记录」入口查看）。
                recordTranscript(userText: transcript, replyText: reply)
                // v049：对话自动沉淀记忆 + 本地规则意图分发（失败静默，不影响对话）
                absorbConversationMemory(userText: transcript, replyText: reply)
                dispatchIntentIfNeeded(userText: transcript)

                let finishedSpeaking = await speak(reply)
                try Task.checkCancellation()

                if !finishedSpeaking {
                    // 被打断：handleInterrupt 已停朗读并恢复聆听，直接结束本轮。
                    return
                }

                // 正常说完一轮：计入轮数，继续下一轮；达上限自动结束。
                roundCount += 1
                if roundCount >= maxRounds {
                    stopConversation()
                    return
                }
                resumeNextRound()
            } catch is CancellationError {
                // 手动退出/打断取消：静默，不报错。
            } catch {
                // 没听到声音是正常事件：不报错、不记日志，静默进入下一轮聆听。
                if Self.isNoSpeechError(error) {
                    resumeNextRound()
                    return
                }
                errorMessage = "语音助手出错了：\(AppErrorText.localized(error.localizedDescription))"
                // 单轮失败不结束会话，继续聆听下一句。
                resumeNextRound()
            }
        }
    }

    /// 进入下一轮监听。
    private func resumeNextRound() {
        guard state != .idle else { return }
        audioCapture.resumeListening()
        state = .listening
    }

    /// 转写：调 TranscriptionService.transcribe 拿文字。
    private func transcribe(_ samples: [Float]) async throws -> String {
        guard let stt = transcriptionService else {
            throw VoiceAssistantError.notConfigured("语音转文字服务未初始化")
        }
        // 豆包 + 实时转写开关：取流式引擎最终结果（onAudioChunk 已喂 feedStreaming）
        if settings.settings.voiceAssistantShowTranscript, let doubao = stt as? DoubaoSTTService {
            return try await doubao.finishStreaming()
        }
        return try await stt.transcribe(audioSamples: samples)
    }

    /// 发送给智能体并拿到完整回复文本。
    ///
    /// - 独立路径（无 chatViewModel）：本类自己持有 OpenClawClient 走网关流式发送
    ///   （OpenClawClient.stream + model "openclaw:<agentId>"，与 SyncChatViewModel.send 同链路），
    ///   不依赖聊天页，主页没进过聊天也能用。
    /// - 兼容路径（注入了 chatViewModel）：复用 ChatViewModel 的 sendText + messages 轮询，
    ///   并持续抑制其自带朗读（语音助手自己控制 TTS 场景音量/打断）。
    private func requestAgentReply(_ text: String) async throws -> String {
        if settings.settings.voiceAgentChannel == .directDeepSeek {
            return try await requestAgentReplyViaDeepSeek(text)
        }
        if let chatViewModel {
            return try await requestAgentReplyViaChatViewModel(text, chatViewModel: chatViewModel)
        }
        return try await requestAgentReplyViaGateway(text)
    }

    /// 直连 DeepSeek 通道：本地档案 + 电脑快照 + 本轮上下文注入，不依赖网关。
    private func requestAgentReplyViaDeepSeek(_ text: String) async throws -> String {
        guard DeepSeekDirectClient.shared.apiKey != nil else {
            throw VoiceAssistantError.notConfigured("未配置 DeepSeek API Key：请到 设置 → 语音助手通道 填写。")
        }
        conversationHistory.append(Message(role: .user, content: text))
        trimConversationHistory()

        var recentDialogue: [String] = []
        for message in conversationHistory.suffix(8) {
            let who = message.role == .user ? "我" : "助手"
            recentDialogue.append("\(who)：\(message.content)")
        }
        let system = MemoryPromptBuilder.build(
            profiles: memoryStore.profiles,
            computerSummary: MemorySyncService.shared.computerSummary,
            dialogueSnippet: MemorySyncService.shared.recentDialogueSnippet,
            recentDialogue: recentDialogue,
            purpose: "作为 ClawTalk 语音助手回答用户"
        )
        let chatMessages = conversationHistory.compactMap(DeepSeekChatMessage.from)

        var reply = ""
        let deadline = Date().addingTimeInterval(90)
        do {
            for try await delta in DeepSeekDirectClient.shared.stream(messages: chatMessages, system: system) {
                try Task.checkCancellation()
                if Date() > deadline {
                    throw VoiceAssistantError.timeout
                }
                reply += delta
            }
        } catch {
            removeConversationUserMessage(text)
            throw error
        }

        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            removeConversationUserMessage(text)
            throw VoiceAssistantError.emptyReply
        }
        conversationHistory.append(Message(role: .assistant, content: trimmed))
        trimConversationHistory()
        return trimmed
    }

    /// 兼容路径：ChatViewModel sendText + 轮询 messages。
    private func requestAgentReplyViaChatViewModel(_ text: String, chatViewModel: ChatViewModel) async throws -> String {
        guard chatViewModel.state == .idle || chatViewModel.state == .speaking || chatViewModel.state == .streaming else {
            throw VoiceAssistantError.busy
        }

        let baselineCount = chatViewModel.messages.count
        chatViewModel.sendText(text)

        // ChatViewModel 在 voiceOutputEnabled=true 时会自带朗读；语音助手要自己控制
        // 朗读（场景音量/打断），这里持续抑制它的 TTS。注意 sendMessage 开头会重置
        // ttsStopped，所以要在流式开始后重复调用（见下方轮询）。
        chatViewModel.stopSpeaking()

        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            try Task.checkCancellation()

            // 流式开始后再次抑制自带朗读（sendMessage 已重置 ttsStopped）。
            if chatViewModel.state == .streaming || chatViewModel.state == .speaking {
                chatViewModel.stopSpeaking()
            }

            guard chatViewModel.messages.count >= baselineCount + 2 else {
                try await Task.sleep(nanoseconds: 150_000_000)
                continue
            }
            if let last = chatViewModel.messages.last {
                if last.role == .assistant, !last.isStreaming {
                    if !last.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return last.content
                    }
                    if last.sendError != nil {
                        throw VoiceAssistantError.emptyReply
                    }
                } else if last.role == .user, last.hasFailed {
                    // 失败时空 assistant 消息被移除，用户消息带 sendError。
                    throw VoiceAssistantError.emptyReply
                }
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        throw VoiceAssistantError.timeout
    }

    /// 独立路径：OpenClawClient.stream 流式拿完整回复（纯文本，不朗读）。
    private func requestAgentReplyViaGateway(_ text: String) async throws -> String {
        guard settings.isConfigured else {
            throw VoiceAssistantError.notConfigured("请先在设置中配置 OpenClaw 网关。")
        }

        conversationHistory.append(Message(role: .user, content: text))
        trimConversationHistory()

        let token = OpenClawClient.resolveHTTPToken(
            settingsToken: settings.gatewayToken,
            gatewayURL: settings.settings.gatewayURL
        )
        let eventStream = openClaw.stream(
            messages: conversationHistory,
            gatewayURL: settings.settings.gatewayURL,
            token: token,
            model: "openclaw:\(agentId)",
            apiMode: settings.settings.agentAPIMode,
            sessionKey: nil,
            messageChannel: "webchat"
        )

        var reply = ""
        let deadline = Date().addingTimeInterval(90)
        do {
            for try await event in eventStream {
                try Task.checkCancellation()
                if Date() > deadline {
                    throw VoiceAssistantError.timeout
                }
                switch event {
                case .textDelta(let delta):
                    reply += delta
                case .modelIdentified, .completed:
                    break
                }
            }
        } catch {
            // 发送失败/取消：不把失败消息留在上下文历史里，下一轮从干净上下文继续。
            removeConversationUserMessage(text)
            throw error
        }

        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            removeConversationUserMessage(text)
            throw VoiceAssistantError.emptyReply
        }

        conversationHistory.append(Message(role: .assistant, content: trimmed))
        trimConversationHistory()
        return trimmed
    }

    /// 上下文历史只保留最近 20 条（约 10 轮），避免无限增长。
    private func trimConversationHistory() {
        if conversationHistory.count > 20 {
            conversationHistory.removeFirst(conversationHistory.count - 20)
        }
    }

    private func removeConversationUserMessage(_ text: String) {
        if let idx = conversationHistory.lastIndex(where: { $0.role == .user && $0.content == text }) {
            conversationHistory.remove(at: idx)
        }
    }

    /// 朗读回复。返回 true = 正常读完；false = 被用户打断。
    /// 朗读期间 VAD 引擎保持运行（pauseListening 只停说话采集，打断检测仍生效）。
    private func speak(_ text: String) async -> Bool {
        guard let tts = speechService else {
            // 无 TTS 配置：跳过朗读，直接视为读完（回复文本已留在 lastReply/聊天记录）。
            return true
        }

        do {
            try audioPlayback.start()
        } catch {
            LogCollector.record(module: "语音助手", "朗读启动失败：\(AppErrorText.localized(error.localizedDescription))")
            return true
        }
        applySceneVolume()

        interruptedDuringSpeaking = false
        audioCapture.pauseListening()
        state = .speaking

        do {
            for try await chunk in tts.streamSpeech(text: text) {
                try Task.checkCancellation()
                audioPlayback.enqueue(pcmData: chunk)
            }
            audioPlayback.markStreamingDone()
            // 打断/退出路径：音频已被 handleInterrupt/stopConversation 停掉，
            // 跳过播放等待避免空转，立即响应新输入。
            if !Task.isCancelled {
                await audioPlayback.waitUntilFinished()
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            // 被打断/退出：静默结束。
        } catch {
            LogCollector.record(module: "语音助手", "朗读失败：\(AppErrorText.localized(error.localizedDescription))")
        }

        // 打断/退出时音频引擎已由 handleInterrupt/stopConversation 停止；
        // 这里不再 stop，避免误杀打断后新一轮对讲刚启动的播放引擎。
        if !Task.isCancelled {
            audioPlayback.stop()
        }
        return !interruptedDuringSpeaking
    }

    /// 朗读期间用户开口（输入音量超阈值）→ 停止朗读、优先听。
    private func handleInterrupt() {
        guard state == .speaking else { return }
        interruptedDuringSpeaking = true
        sessionTask?.cancel()
        speechService?.stop()
        audioPlayback.stop()
        // 立即回聆听（resumeListening 的 800ms 预热会吞掉 TTS 回声尾巴）。
        audioCapture.resumeListening()
        state = .listening
    }

    /// 场景音量：夜间轻声（duckVolume 0.3），其余恢复 1.0。
    private func applySceneVolume() {
        if sceneMode.usesQuietVoice {
            audioPlayback.duckVolume()
        } else {
            audioPlayback.restoreVolume()
        }
    }
}
