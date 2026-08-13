import Foundation

/// AI 分身 ViewModel（F1）：
/// - 读取本地记忆档案（MemoryProfileStore 只读）作为口吻参考
/// - 用 OpenClawClient 带「模仿用户口吻」提示词生成草稿（流式）
/// - 诚实原则：明确标注「风格模拟」，不是真正克隆；无档案时用通用口吻说明，不造假
@Observable
@MainActor
final class CloneTalkViewModel {
    private let settingsStore: SettingsStore
    private let memoryStore: MemoryProfileStore
    private let client = OpenClawClient()

    // MARK: - UI 状态

    var inputText = ""
    var style: CloneStyle = .casual
    private(set) var isGenerating = false
    private(set) var generatedText = ""
    private(set) var errorMessage: String?
    private(set) var profileCount = 0
    private(set) var drafts: [CloneDraft] = []
    private(set) var didSaveCurrent = false

    private static let draftsKey = "clone_talk_drafts_v1"

    init(settingsStore: SettingsStore, memoryStore: MemoryProfileStore? = nil) {
        self.settingsStore = settingsStore
        self.memoryStore = memoryStore ?? MemoryProfileStore(settings: settingsStore)
        loadDrafts()
        // 档案只读使用：聚合后统计条数用于提示（失败静默，不阻塞生成）
        if self.memoryStore.profiles.isEmpty {
            self.memoryStore.refreshFromConversations()
        }
        profileCount = self.memoryStore.profiles.count
    }

    // MARK: - 生成草稿

    func generate() async {
        let input = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            errorMessage = "先输入一句话，分身才知道要帮你写什么"
            return
        }
        isGenerating = true
        didSaveCurrent = false
        generatedText = ""
        errorMessage = nil

        let prompt = Self.buildPrompt(input: input, style: style, profiles: memoryStore.profiles)

        if settingsStore.settings.voiceAgentChannel == .directDeepSeek {
            await generateViaDeepSeek(prompt: prompt)
        } else {
            await generateViaGateway(prompt: prompt)
        }
        isGenerating = false
    }

    // MARK: - 直连 / 网关生成（T4）

    /// 直连 DeepSeek 通道：本地档案 + 电脑快照注入，不依赖网关。
    private func generateViaDeepSeek(prompt: String) async {
        let system = MemoryPromptBuilder.build(
            profiles: memoryStore.profiles,
            computerSummary: MemorySyncService.shared.computerSummary,
            dialogueSnippet: MemorySyncService.shared.recentDialogueSnippet,
            recentDialogue: [],
            purpose: "模仿用户口吻改写一句话"
        )
        do {
            for try await delta in DeepSeekDirectClient.shared.stream(
                messages: [DeepSeekChatMessage(role: "user", content: prompt)],
                system: system
            ) {
                generatedText += delta
            }
            let trimmed = generatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                errorMessage = "没有生成内容，请重试或换个说法"
            }
        } catch {
            errorMessage = AppErrorText.localized(error.localizedDescription)
            LogCollector.record(module: "AI 分身", "直连生成失败：\(error.localizedDescription)")
        }
    }

    /// 网关通道（原实现）：OpenClawClient 流式生成。
    private func generateViaGateway(prompt: String) async {
        guard settingsStore.isConfigured else {
            errorMessage = "尚未连接网关：请先配对或填写网关地址与令牌"
            return
        }
        do {
            let stream = client.stream(
                messages: [Message(role: .user, content: prompt)],
                gatewayURL: settingsStore.settings.gatewayURL,
                token: OpenClawClient.resolveHTTPToken(
                    settingsToken: settingsStore.gatewayToken,
                    gatewayURL: settingsStore.settings.gatewayURL
                ),
                model: "openclaw:main",
                apiMode: settingsStore.settings.agentAPIMode,
                sessionKey: nil,
                messageChannel: "clone-talk"
            )
            for try await event in stream {
                switch event {
                case .textDelta(let delta):
                    generatedText += delta
                case .modelIdentified, .completed:
                    break
                }
            }
            let trimmed = generatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                errorMessage = "没有生成内容，请重试或换个说法"
            }
        } catch {
            errorMessage = AppErrorText.localized(error.localizedDescription)
            LogCollector.record(module: "AI 分身", "生成失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 草稿保存

    func saveDraft() {
        let text = generatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !input.isEmpty, !didSaveCurrent else { return }
        drafts.insert(
            CloneDraft(id: UUID(), input: input, style: style, text: text, createdAt: Date()),
            at: 0
        )
        if drafts.count > 50 {
            drafts.removeLast(drafts.count - 50)
        }
        persist()
        didSaveCurrent = true
    }

    func deleteDraft(_ draft: CloneDraft) {
        drafts.removeAll { $0.id == draft.id }
        persist()
    }

    func clearDrafts() {
        drafts.removeAll()
        persist()
    }

    // MARK: - 提示词构建

    /// 把本地档案摘要 + 风格指令拼进提示词；档案为空时回退通用口吻说明（诚实，不编造档案）。
    private static func buildPrompt(input: String, style: CloneStyle, profiles: [MemoryProfile]) -> String {
        var reference: String
        if !profiles.isEmpty {
            let lines = profiles.prefix(12).map { profile in
                "【\(profile.category.rawValue)】\(profile.summary)"
            }
            reference = "参考以下关于这个人的本地档案，模仿 TA 的表达习惯：\n" + lines.joined(separator: "\n") + "\n\n"
        } else {
            reference = "（暂无本地档案，按常见中文用户的口语习惯模仿）\n"
        }
        return """
        \(reference)
        请模仿这个人的口吻（\(style.instruction)）改写下面这句话，写成一段自然的中文。不要解释过程，不要加前缀，直接输出结果：

        \(input)
        """
    }

    // MARK: - 持久化

    private func loadDrafts() {
        guard let data = UserDefaults.standard.data(forKey: Self.draftsKey),
              let decoded = try? JSONDecoder().decode([CloneDraft].self, from: data) else { return }
        drafts = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(drafts) {
            UserDefaults.standard.set(data, forKey: Self.draftsKey)
        }
    }
}
