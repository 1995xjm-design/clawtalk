import Foundation
import SwiftUI
import Observation
import UIKit

// MARK: - 状态

/// 写文章页状态。
enum WritingComposeState: Equatable {
    case idle
    case recording
    case transcribing
    case generating
}

/// 语音写文章专属错误。
enum WritingComposeError: LocalizedError {
    case timeout
    case emptyReply

    var errorDescription: String? {
        switch self {
        case .timeout: return "等待 AI 回复超时"
        case .emptyReply: return "AI 没有返回内容"
        }
    }
}

// MARK: - ViewModel

/// 语音写文章页 ViewModel：
/// 按住说话录要点（AudioCaptureManager + STT）→ 要点列表（可编辑/增删）
/// → 语气选择 → 生成文章（AI 优先流式显示，失败本地规则降级并诚实标注）
/// → 落库 WritingStore。
@Observable
@MainActor
final class WritingComposeViewModel {

    // MARK: - 依赖（现有语音栈/网关，只读引用）

    private let settingsStore: SettingsStore
    let writingStore: WritingStore
    private let audioCapture = AudioCaptureManager()
    /// 按 SettingsStore.sttProvider 懒创建，规则与 ClawTalkApp.configureServices 一致
    private var transcriptionService: (any TranscriptionService)?
    private var levelTimer: Timer?
    private var recordingStart: Date?

    // MARK: - UI 状态

    private(set) var state: WritingComposeState = .idle
    /// 录音实时电平（驱动按住录音的外圈脉冲动画）
    var audioLevel: Float = 0
    var errorMessage: String? {
        didSet {
            if let errorMessage {
                LogCollector.record(module: "语音写文章", errorMessage)
            }
        }
    }
    /// 口述要点列表（可编辑/增删）
    var points: [String] = []
    /// 手动添加要点的输入框
    var newPointText: String = ""
    /// 语气选择（正式/轻松/专业/感人）
    var tone: ArticleTone = .formal
    /// AI 流式生成中的原文（逐 token 追加展示）
    private(set) var streamingText: String = ""
    /// 生成说明（诚实：AI 生成 / 本地生成（未接 AI）及原因）
    private(set) var generationNotice: String?
    /// 生成完成后的草稿（驱动详情 sheet）
    var savedDraft: ArticleDraft?

    var isGenerating: Bool {
        state == .generating
    }

    /// 可生成条件：至少一个非空要点，且不在录音/转写/生成中。
    var canGenerate: Bool {
        state == .idle && !pointsText.isEmpty
    }

    /// 过滤空白后的要点列表。
    var pointsText: [String] {
        points
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    init(settingsStore: SettingsStore, writingStore: WritingStore) {
        self.settingsStore = settingsStore
        self.writingStore = writingStore
    }

    // MARK: - 录音（与文档口述/语音日记同模式）

    func startRecording() {
        guard state == .idle else { return }
        VoiceWakeCapability.shared.stopListening()
        errorMessage = nil
        do {
            try audioCapture.startRecording()
            recordingStart = Date()
            state = .recording
            startLevelTimer()
        } catch {
            errorMessage = "麦克风访问失败：\(AppErrorText.localized(error.localizedDescription))"
            restoreWakeListening()
        }
    }

    func stopRecordingAndTranscribe() {
        guard state == .recording else { return }
        stopLevelTimer()
        let samples = audioCapture.stopRecording()

        // 与聊天页同阈值：<0.5s 或样本过少视为误触
        let duration = Date().timeIntervalSince(recordingStart ?? Date())
        guard duration >= 0.5, samples.count > 8000 else {
            state = .idle
            restoreWakeListening()
            return
        }

        state = .transcribing
        Task {
            defer { restoreWakeListening() }
            guard let stt = makeTranscriptionService() else {
                errorMessage = "语音输入已在设置中关闭，请到设置页开启后重试"
                state = .idle
                return
            }
            do {
                let text = try await stt.transcribe(audioSamples: samples)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    errorMessage = "没有识别到内容，请再试一次"
                    state = .idle
                    return
                }
                points.append(trimmed)
                state = .idle
            } catch {
                errorMessage = "转写失败：\(AppErrorText.localized(error.localizedDescription))"
                state = .idle
            }
        }
    }

    /// 页面退出时丢弃未完成的录音（不转写、不保存）。
    func discardActiveRecording() {
        guard state == .recording else { return }
        stopLevelTimer()
        _ = audioCapture.stopRecording()
        state = .idle
        restoreWakeListening()
    }

    // MARK: - 要点增删改

    func addManualPoint() {
        let trimmed = newPointText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        points.append(trimmed)
        newPointText = ""
    }

    func removePoint(at index: Int) {
        guard points.indices.contains(index) else { return }
        points.remove(at: index)
    }

    // MARK: - 生成文章（两条路）

    func generateArticle() {
        let trimmedPoints = pointsText
        guard !trimmedPoints.isEmpty else {
            errorMessage = "还没有要点，先按住说话录几句，或手动添加"
            return
        }
        guard state == .idle else { return }
        state = .generating
        errorMessage = nil
        generationNotice = nil
        streamingText = ""
        savedDraft = nil

        Task {
            let result = await WritingOrganizer.generate(
                points: trimmedPoints,
                tone: tone,
                settings: settingsStore,
                onDelta: { [weak self] delta in
                    guard let self else { return }
                    self.streamingText += delta
                }
            )
            writingStore.add(result.draft)
            if let aiError = result.aiError {
                LogCollector.record(module: "语音写文章", "AI 生成失败：\(AppErrorText.localized(aiError.localizedDescription))")
            }
            savedDraft = result.draft
            if result.usedFallback {
                generationNotice = result.fallbackReason.map { "\($0)，已改用本地生成" }
                    ?? "本次为本地生成（未接 AI）"
            } else if let notice = result.fallbackReason {
                // AI 成功但结构不完整时的说明（如实标注，不冒充标准结构）
                generationNotice = notice
            } else {
                generationNotice = "AI 生成完成"
            }
            state = .idle
        }
    }

    func clearAll() {
        points = []
        newPointText = ""
        streamingText = ""
        generationNotice = nil
        savedDraft = nil
        errorMessage = nil
        tone = .formal
    }

    /// 设置里切换 STT 提供商后由外部调用，重建服务。
    func rebuildSTTService() {
        transcriptionService = nil
    }

    // MARK: - STT 服务工厂（与文档口述/语音日记同规则）

    private func makeTranscriptionService() -> (any TranscriptionService)? {
        let settings = settingsStore.settings
        guard settings.voiceInputEnabled else { return nil }
        if let cached = transcriptionService { return cached }

        let service: any TranscriptionService
        switch settings.sttProvider {
        case .apple:
            service = AppleSTTService(language: settings.whisperLanguage)
        case .doubao:
            if let key = SecureStorage.shared.doubaoAPIKey, !key.isEmpty {
                service = DoubaoSTTService(apiKey: key, language: settings.whisperLanguage)
            } else {
                service = AppleSTTService(language: settings.whisperLanguage)
            }
        }
        transcriptionService = service
        return service
    }

    // MARK: - 工具

    private func startLevelTimer() {
        stopLevelTimer()
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.audioLevel = self.audioCapture.currentLevel
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
        audioLevel = 0
    }

    /// 录音/转写结束后恢复语音唤醒监听（App 层已监听该通知）。
    private func restoreWakeListening() {
        NotificationCenter.default.post(name: .clawTalkWakeRestartRequested, object: nil)
    }
}

// MARK: - 生成逻辑（两条路）

/// 生成结果：draft 为生成好的文章（未落库）+ 诚实来源信息。
struct WritingGenerationResult {
    let draft: ArticleDraft
    /// true = 本地规则降级（AI 未接入 / 调用失败）
    let usedFallback: Bool
    /// 降级原因或 AI 结构说明（展示给用户，诚实说明）
    let fallbackReason: String?
    /// AI 调用原始错误（仅记录日志用）
    let aiError: Error?
}

/// 文章生成逻辑，两条路：
/// ① 网关可用时调 OpenClawClient.stream（与 VoiceAssistantViewModel.requestAgentReplyViaGateway
///    同独立发送链路），按要点+语气扩写成文章（提示词限定输出 title + content），
///    流式逐 token 回调给 UI 展示；
/// ② 网关不可用 / 调用失败 → 本地规则降级（要点按句号拼接 + 简单过渡句），
///    结果带 generatedByAI = false，UI 诚实标注「本地生成（未接 AI）」。
@MainActor
enum WritingOrganizer {

    /// 默认模型：跟随默认频道 agent，兜底 "main"（与 DictationOrganizer 同策略）。
    static func defaultAgentID(settings: SettingsStore) -> String {
        if let wakeChannelID = settings.settings.voiceWakeChannelID,
           let matched = ChannelStore.shared.channels.first(where: { $0.id.uuidString == wakeChannelID }) {
            return matched.agentId
        }
        if let first = ChannelStore.shared.channels.first {
            return first.agentId
        }
        return "main"
    }

    static func generate(
        points: [String],
        tone: ArticleTone,
        settings: SettingsStore,
        onDelta: @escaping (String) -> Void
    ) async -> WritingGenerationResult {
        let trimmedPoints = points
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let fallback = WritingLocalFallback.makeDraft(points: trimmedPoints, tone: tone)

        guard !trimmedPoints.isEmpty else {
            return WritingGenerationResult(
                draft: fallback,
                usedFallback: true,
                fallbackReason: "没有可生成的要点",
                aiError: nil
            )
        }

        // ① 网关不可用 → 诚实降级（不假装调用 AI）
        guard settings.isConfigured else {
            return WritingGenerationResult(
                draft: fallback,
                usedFallback: true,
                fallbackReason: "未配置 OpenClaw 网关",
                aiError: nil
            )
        }

        do {
            let raw = try await requestAIReply(points: trimmedPoints, tone: tone, settings: settings, onDelta: onDelta)
            if let parsed = parseAIOutput(raw) {
                let draft = ArticleDraft(
                    title: parsed.title,
                    content: parsed.content,
                    outline: trimmedPoints,
                    tone: tone,
                    generatedByAI: true
                )
                return WritingGenerationResult(draft: draft, usedFallback: false, fallbackReason: nil, aiError: nil)
            }
            // AI 返回了内容但结构不标准 → 仍用 AI 原文（不造假），标题取首行，如实说明结构问题
            let content = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = Self.resolveTitleFromRawAI(content)
            let draft = ArticleDraft(
                title: title,
                content: content,
                outline: trimmedPoints,
                tone: tone,
                generatedByAI: true,
                generationNotice: "AI 未按「标题 + 正文」格式返回，已原样保存"
            )
            return WritingGenerationResult(
                draft: draft,
                usedFallback: false,
                fallbackReason: "AI 未按「标题 + 正文」格式返回，已原样保存",
                aiError: nil
            )
        } catch {
            // 网络失败 / 超时 / 空回复 → 诚实降级
            return WritingGenerationResult(
                draft: fallback,
                usedFallback: true,
                fallbackReason: "AI 生成失败（\(Self.friendlyError(error))）",
                aiError: error
            )
        }
    }

    // MARK: - AI 独立发送链路（与 DictationOrganizer.requestAIReply 同模式）

    /// 与 VoiceAssistantViewModel.requestAgentReplyViaGateway 同模式：
    /// OpenClawClient.stream 流式累积回复并逐 token 回调 UI，90 秒超时兜底。
    private static func requestAIReply(
        points: [String],
        tone: ArticleTone,
        settings: SettingsStore,
        onDelta: @escaping (String) -> Void
    ) async throws -> String {
        let token = OpenClawClient.resolveHTTPToken(
            settingsToken: settings.gatewayToken,
            gatewayURL: settings.settings.gatewayURL
        )

        let prompt = aiPrompt(points: points, tone: tone)
        let eventStream = OpenClawClient().stream(
            messages: [Message(role: .user, content: prompt)],
            gatewayURL: settings.settings.gatewayURL,
            token: token,
            model: "openclaw:\(defaultAgentID(settings: settings))",
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
                    throw WritingComposeError.timeout
                }
                switch event {
                case .textDelta(let delta):
                    reply += delta
                    onDelta(delta)
                case .modelIdentified, .completed:
                    break
                }
            }
        } catch {
            throw error
        }

        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WritingComposeError.emptyReply
        }
        return trimmed
    }

    /// AI 提示词：要求只输出 JSON（title + content），禁止编造要点之外的内容。
    /// 要点超长时截断到 8000 字再送 AI（原始要点仍完整保存在 outline，不丢内容）。
    private static func aiPrompt(points: [String], tone: ArticleTone) -> String {
        let bulletPoints = points.map { "- \($0)" }.joined(separator: "\n")
        let capped = bulletPoints.count > 8000 ? String(bulletPoints.prefix(8000)) + "\n…（后续要点省略）" : bulletPoints
        return """
        你是文章扩写助手。请根据用户口述的要点，扩写成一篇完整文章。只输出一个 JSON 对象，不要输出任何其他文字、解释或 Markdown 代码块标记。

        语气要求：\(tone.promptDescription)

        输出格式（严格按此结构）：
        {
          "title": "文章标题（一句话概括，20 字以内）",
          "content": "完整文章正文，分段用换行分隔"
        }

        规则：
        - 只输出 JSON，禁止在 JSON 前后添加说明文字。
        - 严格围绕用户给出的要点展开，不要编造要点之外的新事实。
        - content 是一篇完整可读的文章（开头引入、中间展开、结尾收束），按语气要求组织语言。
        - 输出必须使用简体中文。

        用户口述要点：
        \(capped)
        """
    }

    /// 解析 AI 输出：严格 JSON 优先；兼容带 ```json 代码块包裹的输出。
    private static func parseAIOutput(_ raw: String) -> (title: String, content: String)? {
        var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // 去掉可能的 ```json ... ``` 包裹
        if candidate.hasPrefix("```") {
            let lines = candidate.components(separatedBy: "\n")
            candidate = lines.dropFirst().dropLast().joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let data = candidate.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let title = (object["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
              let content = (object["content"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            return nil
        }
        return (title, content)
    }

    /// AI 原文不是标准 JSON 时：取第一个非空行做标题（≤20 字），其余全部作为正文。
    private static func resolveTitleFromRawAI(_ raw: String) -> String {
        let lines = raw.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else { return "AI 生成文章" }
        return first.count > 20 ? String(first.prefix(20)) + "…" : first
    }

    private static func friendlyError(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let msg = localized.errorDescription {
            return msg
        }
        return error.localizedDescription
    }
}

/// 本地规则降级生成（诚实兜底，不造假）：
/// 要点按句号拼接 + 简单过渡句组织成段落；标题取自第一个要点；字数如实统计。
enum WritingLocalFallback {

    /// 段落目标长度（字符）：优先保持要点完整，尽量让每段落在该长度左右。
    private static let targetParagraphLength = 120
    /// 过渡词：给非首个要点加简单过渡，让拼接读起来自然一点。
    private static let transitions = ["首先", "其次", "然后", "接着", "最后"]

    static func makeDraft(points: [String], tone: ArticleTone) -> ArticleDraft {
        let cleanPoints = points
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let paragraphs = buildParagraphs(from: cleanPoints)
        let content = paragraphs.joined(separator: "\n\n")
        let title = resolveTitle(firstPoint: cleanPoints.first)

        return ArticleDraft(
            title: title,
            content: content,
            outline: cleanPoints,
            tone: tone,
            generatedByAI: false
        )
    }

    /// 要点按句号拼接，按目标长度合并成段落；段落内非首个要点加简单过渡词。
    private static func buildParagraphs(from points: [String]) -> [String] {
        guard !points.isEmpty else { return [] }

        var paragraphs: [String] = []
        var current = ""
        for (index, point) in points.enumerated() {
            let sentence = normalizedSentence(point, transition: transitionWord(at: index))
            if !current.isEmpty && current.count + sentence.count > targetParagraphLength {
                paragraphs.append(current)
                current = sentence
            } else {
                current = current.isEmpty ? sentence : current + sentence
            }
        }
        if !current.isEmpty {
            paragraphs.append(current)
        }
        return paragraphs
    }

    /// 保证要点以句号结尾；非首个要点加「首先/其次/…」过渡。
    private static func normalizedSentence(_ point: String, transition: String?) -> String {
        let trimmed = point.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        var sentence = trimmed
        if let last = sentence.last, "。！？!?.".contains(last) == false {
            sentence += "。"
        }
        if let transition, !transition.isEmpty {
            return "\(transition)，\(sentence)"
        }
        return sentence
    }

    private static func transitionWord(at index: Int) -> String? {
        guard index > 0 else { return nil }
        let idx = min(index - 1, transitions.count - 1)
        return transitions[idx]
    }

    /// 标题：第一个要点前 15 字（本地生成不编造标题）。
    private static func resolveTitle(firstPoint: String?) -> String {
        guard let firstPoint, !firstPoint.isEmpty else { return "未命名文章" }
        return firstPoint.count > 15 ? String(firstPoint.prefix(15)) + "…" : firstPoint
    }
}

// MARK: - 写文章页

/// 语音写文章页：
/// - 口述要点列表（按住底部麦克风录音，松开转写成一个要点；可编辑/手动增删）
/// - 语气选择（正式/轻松/专业/感人）
/// - 「生成文章」按钮：AI 优先流式显示，失败本地规则降级并诚实标注
/// - 生成完成弹出文章详情（可编辑/分享 txt/md/朗读）
struct WritingComposeView: View {
    @State private var viewModel: WritingComposeViewModel
    var onBack: (() -> Void)?

    // 按住说话手势状态（参考 DictationRecorderView / VoiceDiaryView）
    @State private var isPressed = false
    @State private var holdTimer: Task<Void, Never>?
    @State private var isHolding = false
    @State private var showHoldHint = false

    private let hapticsEnabled: Bool
    private let recordButtonSize: CGFloat = 72
    /// 按住多久算开始录音（0.3 秒，与文档口述/语音日记一致）
    private let holdThreshold: UInt64 = 300_000_000

    init(
        settingsStore: SettingsStore,
        writingStore: WritingStore,
        onBack: (() -> Void)? = nil
    ) {
        _viewModel = State(initialValue: WritingComposeViewModel(
            settingsStore: settingsStore,
            writingStore: writingStore
        ))
        self.onBack = onBack
        self.hapticsEnabled = settingsStore.settings.hapticsEnabled
    }

    var body: some View {
        VStack(spacing: 0) {
            navBar
            Divider().opacity(0.3)
            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().opacity(0.3)
            bottomArea
        }
        .background(Color(.systemBackground))
        .onDisappear { viewModel.discardActiveRecording() }
        .sheet(item: $viewModel.savedDraft) { draft in
            NavigationStack {
                WritingDetailView(draft: draft, store: viewModel.writingStore)
            }
        }
        .overlay(alignment: .bottom) {
            GlobalVoiceInputFloating(settingsStore: SettingsStore())
                .padding(.bottom, 120)
        }
    }

    // MARK: - 导航栏

    private var navBar: some View {
        ZStack {
            Text("语音写文章")
                .font(.headline)
            HStack {
                if let onBack {
                    Button(action: onBack) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                            .padding(10)
                            .background(Color(.systemGray5), in: Circle())
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 52)
    }

    // MARK: - 内容区（要点/语气/流式）

    private var contentArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                pointsSection
                toneSection
                if viewModel.isGenerating {
                    streamingSection
                }
            }
            .padding(16)
        }
    }

    private var pointsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("口述要点")
                    .font(.headline)
                Spacer()
                if !viewModel.points.isEmpty {
                    Button("清空") { viewModel.clearAll() }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if viewModel.points.isEmpty {
                emptyPointsHint
            } else {
                ForEach(viewModel.points.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .background(Color(.systemGray5), in: Circle())
                        TextField("要点 \(index + 1)（可编辑）", text: $viewModel.points[index], axis: .vertical)
                            .font(.subheadline)
                        Button {
                            viewModel.removePoint(at: index)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
                }
            }

            // 手动添加要点
            HStack(spacing: 8) {
                TextField("手动添加一个要点", text: $viewModel.newPointText)
                    .font(.subheadline)
                    .submitLabel(.done)
                    .onSubmit { viewModel.addManualPoint() }
                Button("添加") { viewModel.addManualPoint() }
                    .font(.subheadline.weight(.medium))
                    .disabled(viewModel.newPointText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(.systemGray4), style: StrokeStyle(lineWidth: 1, dash: [4]))
            )
        }
    }

    /// 空要点时的诚实空状态（不塞假数据）。
    private var emptyPointsHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "mic.circle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("按住底部麦克风录音，松开自动转写成一个要点；可以录多条，也可以手动添加。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var toneSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("文章语气")
                .font(.headline)
            Picker("文章语气", selection: $viewModel.tone) {
                ForEach(ArticleTone.allCases) { tone in
                    Text(tone.rawValue).tag(tone)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    /// AI 流式生成区：逐 token 追加显示。
    private var streamingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("AI 生成中…（流式输出）", systemImage: "sparkles")
                .font(.headline)
                .foregroundStyle(.indigo)
            ScrollView {
                Text(viewModel.streamingText.isEmpty ? "正在等待 AI 输出…" : viewModel.streamingText)
                    .font(.body)
                    .foregroundStyle(viewModel.streamingText.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 180)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
    }

    // MARK: - 底部：生成按钮 + 录音区

    private var bottomArea: some View {
        VStack(spacing: 12) {
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            if let notice = viewModel.generationNotice {
                Label(notice, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if viewModel.canGenerate {
                generateButton
            }

            recordArea
        }
        .padding(.vertical, 10)
    }

    private var generateButton: some View {
        Button {
            viewModel.generateArticle()
        } label: {
            HStack(spacing: 8) {
                if viewModel.isGenerating {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(viewModel.isGenerating ? "生成中…" : "生成文章")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(viewModel.isGenerating ? Color.gray : Color.indigo)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .disabled(viewModel.isGenerating)
        .padding(.horizontal, 16)
    }

    private var recordArea: some View {
        VStack(spacing: 8) {
            recordButton
            statusLabel
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch viewModel.state {
        case .idle:
            Text(showHoldHint ? "按住说话，录完松开" : "按住说话，松开添加一个要点")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(showHoldHint ? Color.openClawRed : .secondary)
        case .recording:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在录音… 松开结束")
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.openClawRed)
        case .transcribing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("转写中…")
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
        case .generating:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("生成中…（AI 失败会自动用本地拼接）")
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - 按住说话按钮

    private var recordButton: some View {
        ZStack {
            if viewModel.state == .recording {
                Circle()
                    .stroke(Color.openClawRed.opacity(0.25), lineWidth: 3)
                    .frame(
                        width: recordButtonSize + 18 + CGFloat(viewModel.audioLevel * 60),
                        height: recordButtonSize + 18 + CGFloat(viewModel.audioLevel * 60)
                    )
                    .animation(.easeOut(duration: 0.08), value: viewModel.audioLevel)

                Circle()
                    .trim(from: 0, to: 0.65)
                    .stroke(Color.openClawRed.opacity(0.6), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: recordButtonSize + 10, height: recordButtonSize + 10)
                    .rotationEffect(.degrees(recordingRingAngle))
                    .animation(.linear(duration: 1.0).repeatForever(autoreverses: false), value: recordingRingAngle)
            }

            Circle()
                .fill(buttonColor)
                .frame(width: recordButtonSize, height: recordButtonSize)
                .shadow(color: buttonColor.opacity(0.4), radius: isPressed ? 4 : 8, y: isPressed ? 1 : 3)
                .scaleEffect(isPressed ? 0.9 : 1.0)

            buttonIcon
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(width: recordButtonSize + 60, height: recordButtonSize + 60)
        .contentShape(Circle())
        .gesture(recordGesture)
        .animation(.spring(response: 0.25, dampingFraction: 0.65), value: isPressed)
        .disabled(viewModel.state == .transcribing || viewModel.state == .generating)
        .accessibilityLabel(accessibilityLabel)
    }

    private var recordingRingAngle: Double {
        viewModel.state == .recording ? 360 : 0
    }

    private var buttonColor: Color {
        switch viewModel.state {
        case .idle: return .openClawRed
        case .recording: return .red
        case .transcribing, .generating: return .openClawRed.opacity(0.5)
        }
    }

    @ViewBuilder
    private var buttonIcon: some View {
        switch viewModel.state {
        case .idle:
            Image(systemName: "mic.fill")
        case .recording:
            Image(systemName: "mic.fill")
                .symbolEffect(.pulse)
        case .transcribing, .generating:
            Image(systemName: "waveform")
        }
    }

    private var accessibilityLabel: String {
        switch viewModel.state {
        case .idle: return "按住说话，录完松开自动转写成一个要点"
        case .recording: return "正在录音，松开结束"
        case .transcribing: return "正在转写"
        case .generating: return "正在生成文章"
        }
    }

    private var canInteract: Bool {
        viewModel.state == .idle || viewModel.state == .recording
    }

    // MARK: - 按住说话手势（参考 DictationRecorderView）

    private var recordGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !isPressed, canInteract else { return }
                isPressed = true
                isHolding = false
                if viewModel.state == .recording {
                    return
                }
                if hapticsEnabled {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
                holdTimer = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: holdThreshold)
                    guard !Task.isCancelled else { return }
                    isHolding = true
                    if hapticsEnabled {
                        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                    }
                    viewModel.startRecording()
                }
            }
            .onEnded { _ in
                holdTimer?.cancel()
                holdTimer = nil
                guard isPressed else { return }
                isPressed = false
                if hapticsEnabled {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                if viewModel.state == .recording || isHolding {
                    viewModel.stopRecordingAndTranscribe()
                } else {
                    showHoldHint = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_800_000_000)
                        showHoldHint = false
                    }
                }
            }
    }
}

// MARK: - 文章详情页（编辑/分享/朗读）

/// 文章详情页：
/// - 标题/正文可编辑（实时写回 WritingStore，字数随编辑刷新）
/// - 生成来源诚实标注（AI 生成 / 本地生成（未接 AI））
/// - ShareLink 导出 txt / Markdown 两种格式
/// - TTS 朗读全文（复用 SpeechService 链路，参考 DailyBriefingView 一键播报）
struct WritingDetailView: View {
    private let store: WritingStore
    private let settings: SettingsStore
    @State private var currentDraft: ArticleDraft
    @State private var exportTXTURL: URL?
    @State private var exportMDURL: URL?
    @Environment(\.dismiss) private var dismiss

    // TTS 朗读状态（参考 DailyBriefingView 一键播报）
    @State private var isSpeaking = false
    @State private var speechError: String?
    @State private var speechTask: Task<Void, Never>?
    @State private var speechService: (any SpeechService)?
    @State private var audioPlayback = AudioPlaybackManager()

    init(draft: ArticleDraft, store: WritingStore, settings: SettingsStore? = nil) {
        self.store = store
        self.settings = settings ?? SettingsStore()
        _currentDraft = State(initialValue: draft)
    }

    var body: some View {
        List {
            headerSection
            contentSection
            actionSection
            outlineSection
            deleteSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("文章")
        .navigationBarTitleDisplayMode(.inline)
        .task { rebuildExportFiles() }
        .onChange(of: currentDraft.title) { persistEdits() }
        .onChange(of: currentDraft.content) { persistEdits() }
        .onDisappear { stopSpeaking() }
    }

    // MARK: - 头部（标题可编辑 + 来源标注 + 语气/字数）

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                TextField("文章标题", text: $currentDraft.title)
                    .font(.title3.weight(.semibold))

                HStack(spacing: 8) {
                    Label(
                        currentDraft.generationLabel,
                        systemImage: currentDraft.generatedByAI ? "sparkles" : "exclamationmark.triangle"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(currentDraft.generatedByAI ? .indigo : .orange)

                    Spacer()

                    Text("\(currentDraft.tone.rawValue) · \(currentDraft.wordCountText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let notice = currentDraft.generationNotice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("更新于 \(Self.dateTimeText(currentDraft.updatedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - 正文（可编辑）

    private var contentSection: some View {
        Section {
            TextEditor(text: $currentDraft.content)
                .font(.body)
                .frame(minHeight: 220)
                .scrollContentBackground(.hidden)
                .padding(4)
        } header: {
            Text("正文（可编辑）")
        }
    }

    // MARK: - 朗读与导出

    private var actionSection: some View {
        Section {
            Button {
                if isSpeaking {
                    stopSpeaking()
                } else {
                    startSpeaking()
                }
            } label: {
                Label(
                    isSpeaking ? "停止朗读" : "朗读全文",
                    systemImage: isSpeaking ? "stop.circle.fill" : "speaker.wave.2.fill"
                )
                .font(.subheadline.weight(.medium))
            }

            if let speechError {
                Label(speechError, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            if let exportTXTURL {
                ShareLink(item: exportTXTURL, preview: SharePreview("\(currentDraft.title) · txt")) {
                    Label("导出/分享为 txt", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.medium))
                }
            }

            if let exportMDURL {
                ShareLink(item: exportMDURL, preview: SharePreview("\(currentDraft.title) · md")) {
                    Label("导出/分享为 Markdown", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.medium))
                }
            }

            if exportTXTURL == nil && exportMDURL == nil {
                Label("导出文件生成失败", systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("朗读与导出")
        }
    }

    // MARK: - 口述要点（原文保留，诚实展示）

    @ViewBuilder
    private var outlineSection: some View {
        if let outline = currentDraft.outline, !outline.isEmpty {
            Section {
                ForEach(Array(outline.enumerated()), id: \.offset) { index, point in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6))
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                        Text(point)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text("口述要点")
            }
        }
    }

    // MARK: - 删除

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                store.delete(id: currentDraft.id)
                dismiss()
            } label: {
                HStack {
                    Spacer()
                    Text("删除这篇文章")
                    Spacer()
                }
            }
        }
    }

    // MARK: - 编辑落库

    private func persistEdits() {
        if let updated = store.refresh(
            id: currentDraft.id,
            title: currentDraft.title,
            content: currentDraft.content
        ) {
            currentDraft = updated
            rebuildExportFiles()
        }
    }

    // MARK: - TTS 朗读（参考 DailyBriefingView 一键播报）

    private func startSpeaking() {
        let trimmed = currentDraft.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stopSpeaking()

        let tts = makeSpeechService()
        speechService = tts
        do {
            try audioPlayback.start()
        } catch {
            speechError = "朗读启动失败：\(AppErrorText.localized(error.localizedDescription))"
            return
        }

        isSpeaking = true
        speechError = nil
        speechTask = Task { @MainActor in
            defer { isSpeaking = false }
            do {
                for try await chunk in tts.streamSpeech(text: currentDraft.content) {
                    try Task.checkCancellation()
                    audioPlayback.enqueue(pcmData: chunk)
                }
                audioPlayback.markStreamingDone()
                await audioPlayback.waitUntilFinished()
            } catch is CancellationError {
                // 用户点了停止：静默结束
            } catch {
                LogCollector.record(module: "语音写文章", "朗读失败：\(AppErrorText.localized(error.localizedDescription))")
            }
            audioPlayback.stop()
        }
    }

    private func stopSpeaking() {
        speechTask?.cancel()
        speechTask = nil
        speechService?.stop()
        speechService = nil
        audioPlayback.stop()
        isSpeaking = false
    }

    /// 与 ClawTalkApp.configureServices / DailyBriefingView 同规则：
    /// 按设置选 Apple/Doubao/Edge，缺 key 回退 Apple。
    private func makeSpeechService() -> any SpeechService {
        let s = settings.settings
        switch s.ttsProvider {
        case .apple:
            return AppleTTSService(speed: s.ttsSpeed, pitch: s.ttsPitch)
        case .doubao:
            if let key = SecureStorage.shared.doubaoAPIKey, !key.isEmpty {
                return DoubaoTTSService(apiKey: key, voiceID: s.doubaoVoiceID)
            }
            return AppleTTSService(speed: s.ttsSpeed, pitch: s.ttsPitch)
        case .edge:
            return EdgeTTSService(voiceID: s.edgeVoiceID, speed: s.ttsSpeed, pitch: s.ttsPitch)
        }
    }

    // MARK: - 导出文件生成（txt / Markdown）

    private func rebuildExportFiles() {
        let baseName = Self.safeFileName(currentDraft.title)
        let txtURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(baseName)-文章.txt")
        let mdURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(baseName)-文章.md")
        do {
            try exportTXT.write(to: txtURL, atomically: true, encoding: .utf8)
            try exportMD.write(to: mdURL, atomically: true, encoding: .utf8)
            exportTXTURL = txtURL
            exportMDURL = mdURL
        } catch {
            exportTXTURL = nil
            exportMDURL = nil
        }
    }

    /// txt 导出内容：标题 + 生成方式（诚实标注）+ 正文 + 口述要点原文。
    private var exportTXT: String {
        var lines: [String] = []
        lines.append(currentDraft.title.isEmpty ? "未命名文章" : currentDraft.title)
        lines.append("")
        lines.append("生成方式：\(currentDraft.generationLabel)")
        if let notice = currentDraft.generationNotice {
            lines.append("说明：\(notice)")
        }
        lines.append("语气：\(currentDraft.tone.rawValue) · 字数：\(currentDraft.wordCountText) · 更新时间：\(Self.dateTimeText(currentDraft.updatedAt))")
        lines.append("")
        lines.append(currentDraft.content)
        if let outline = currentDraft.outline, !outline.isEmpty {
            lines.append("")
            lines.append("—— 口述要点 ——")
            for (index, point) in outline.enumerated() {
                lines.append("\(index + 1). \(point)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Markdown 导出内容：标题 + 生成方式（诚实标注）+ 正文 + 口述要点原文。
    private var exportMD: String {
        var lines: [String] = []
        lines.append("# \(currentDraft.title.isEmpty ? "未命名文章" : currentDraft.title)")
        lines.append("")
        lines.append("> 生成方式：\(currentDraft.generationLabel)")
        if let notice = currentDraft.generationNotice {
            lines.append("> 说明：\(notice)")
        }
        lines.append("> 语气：\(currentDraft.tone.rawValue) · 字数：\(currentDraft.wordCountText) · 更新时间：\(Self.dateTimeText(currentDraft.updatedAt))")
        lines.append("")
        lines.append(currentDraft.content)
        if let outline = currentDraft.outline, !outline.isEmpty {
            lines.append("")
            lines.append("## 口述要点")
            for point in outline {
                lines.append("- \(point)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func safeFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
        return cleaned.isEmpty ? "文章" : cleaned
    }

    private static func dateTimeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter.string(from: date)
    }
}
