import SwiftUI

/// 「每日一站式播报」页：顶部大「一键播报」按钮（TTS 朗读全文）+
/// 播报文案全文 + 各分区（提醒/日程/待办/日记/自动化/天气）。
///
/// 数据源：DailyBriefingEngine 聚合；失败降级跳过并在分区如实标注。
/// TTS：与 ClawTalkApp.configureServices 同规则创建 SpeechService
/// （默认 AppleTTSService(speed:pitch:)），PCM 音频流走 AudioPlaybackManager
/// （与 VoiceAssistantViewModel.speak 同链路）。
///
/// 主智能体接线：
/// - 主页卡：DailyBriefingCardView()（自带 NavigationLink 进本页）
/// - 独立入口：NavigationStack { DailyBriefingView(settings: settingsStore) }
struct DailyBriefingView: View {
    private let settings: SettingsStore

    @State private var careStore: CareReminderStore
    @State private var diaryViewModel: VoiceDiaryViewModel
    @State private var automationViewModel: AutomationViewModel

    @State private var content: DailyBriefingEngine.Content?
    @State private var isLoading = false

    // MARK: - 播报播放状态

    @State private var isSpeaking = false
    @State private var speechError: String?
    @State private var speechTask: Task<Void, Never>?
    @State private var speechService: (any SpeechService)?
    @State private var audioPlayback = AudioPlaybackManager()

    init(
        settings: SettingsStore? = nil,
        careStore: CareReminderStore? = nil,
        diaryViewModel: VoiceDiaryViewModel? = nil,
        automationViewModel: AutomationViewModel? = nil
    ) {
        let resolvedSettings = settings ?? SettingsStore()
        let resolvedCare = careStore ?? CareReminderStore()
        let resolvedDiary = diaryViewModel ?? VoiceDiaryViewModel(settingsStore: resolvedSettings)
        let resolvedAutomation = automationViewModel ?? AutomationViewModel(settings: resolvedSettings)
        self.settings = resolvedSettings
        _careStore = State(initialValue: resolvedCare)
        _diaryViewModel = State(initialValue: resolvedDiary)
        _automationViewModel = State(initialValue: resolvedAutomation)
    }

    var body: some View {
        List {
            Section {
                playButton
                if let speechError {
                    Label(speechError, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } header: {
                Label("一键播报", systemImage: "speaker.wave.2.fill")
            }

            if let content {
                briefTextSection(content)
                reminderSection(content)
                scheduleSection(content)
                todoSection(content)
                diarySection(content)
                automationSection(content)
                weatherSection
                skippedSection(content)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("每日播报")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoading {
                ProgressView()
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .onDisappear { stopSpeaking() }
    }

    // MARK: - 一键播报

    private var playButton: some View {
        Button {
            if isSpeaking {
                stopSpeaking()
            } else {
                startSpeaking()
            }
        } label: {
            Label(
                isSpeaking ? "停止播报" : "一键播报",
                systemImage: isSpeaking ? "stop.circle.fill" : "speaker.wave.2.fill"
            )
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                isSpeaking ? Color.red : Color.indigo,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(isLoading || content?.spokenText.isEmpty ?? true)
    }

    /// 用 SpeechService 朗读播报文案（PCM 流 → AudioPlaybackManager 播放）。
    /// 每次播报新建 TTS 服务实例：AppleTTSService.stop() 会把实例永久置 stopped，
    /// 复用旧实例会导致后续朗读静音，故不缓存（与 App 层按需重建同思路）。
    private func startSpeaking() {
        guard let content, !content.spokenText.isEmpty else { return }
        stopSpeaking()

        let tts = makeSpeechService()
        speechService = tts
        do {
            try audioPlayback.start()
        } catch {
            speechError = "语音播报启动失败：\(AppErrorText.localized(error.localizedDescription))"
            return
        }

        isSpeaking = true
        speechError = nil
        speechTask = Task { @MainActor in
            defer { isSpeaking = false }
            do {
                for try await chunk in tts.streamSpeech(text: content.spokenText) {
                    try Task.checkCancellation()
                    audioPlayback.enqueue(pcmData: chunk)
                }
                audioPlayback.markStreamingDone()
                await audioPlayback.waitUntilFinished()
            } catch is CancellationError {
                // 用户点了停止：静默结束
            } catch {
                LogCollector.record(module: "每日播报", "朗读失败：\(AppErrorText.localized(error.localizedDescription))")
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

    /// 与 ClawTalkApp.configureServices 同规则：按设置选 Apple/Doubao/Edge，缺 key 回退 Apple。
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

    // MARK: - 加载

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        speechError = nil
        // 每次按当前设置构建引擎：天气 API Key / 城市修改后下拉刷新即生效
        let engine = DailyBriefingEngine(
            careStore: careStore,
            diaryViewModel: diaryViewModel,
            automationViewModel: automationViewModel,
            weatherAPIKey: settings.weatherAPIKey.isEmpty ? nil : settings.weatherAPIKey,
            weatherCity: settings.settings.weatherCity
        )
        content = await engine.build()
    }

    // MARK: - 分区

    private func briefTextSection(_ content: DailyBriefingEngine.Content) -> some View {
        Section {
            Text(content.spokenText)
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        } header: {
            Label("播报文案", systemImage: "text.quote")
        }
    }

    private func reminderSection(_ content: DailyBriefingEngine.Content) -> some View {
        Section {
            if content.reminderCount == 0 {
                emptyRow("今天暂无提醒", detail: "在「提醒」里创建的居家提醒会显示在这里")
            } else {
                ForEach(content.reminderItems) { item in
                    NavigationLink {
                        ReminderListView(store: careStore)
                    } label: {
                        briefRow(item)
                    }
                }
                if content.reminderCount > content.reminderItems.count {
                    Text("另有 \(content.reminderCount - content.reminderItems.count) 条，详见提醒列表")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        } header: {
            Label("今日提醒 · \(content.reminderCount)", systemImage: "bell.badge")
        }
    }

    private func scheduleSection(_ content: DailyBriefingEngine.Content) -> some View {
        Section {
            if let note = content.skippedNotes.first(where: { $0.section == "日程" }) {
                emptyRow("日程已跳过", detail: note.message)
            } else if content.scheduleCount == 0 {
                emptyRow("今天暂无日程", detail: "日历里没有安排，好好休息一下")
            } else {
                ForEach(content.scheduleItems) { item in
                    briefRow(item)
                }
                if content.scheduleCount > content.scheduleItems.count {
                    Text("另有 \(content.scheduleCount - content.scheduleItems.count) 个日程")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        } header: {
            Label("今日日程 · \(content.scheduleCount)", systemImage: "calendar")
        }
    }

    private func todoSection(_ content: DailyBriefingEngine.Content) -> some View {
        Section {
            if let note = content.skippedNotes.first(where: { $0.section == "待办" }) {
                emptyRow("待办已跳过", detail: note.message)
            } else if content.todoCount == 0 {
                emptyRow("今天暂无待办", detail: "提醒事项里没有安排在今天的事项")
            } else {
                ForEach(content.todoItems) { item in
                    briefRow(item)
                }
                if content.todoCount > content.todoItems.count {
                    Text("另有 \(content.todoCount - content.todoItems.count) 件待办")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        } header: {
            Label("今日待办 · \(content.todoCount)", systemImage: "checklist")
        }
    }

    private func diarySection(_ content: DailyBriefingEngine.Content) -> some View {
        Section {
            if let note = content.skippedNotes.first(where: { $0.section == "日记" }) {
                emptyRow("日记未接入", detail: note.message)
            } else {
                NavigationLink {
                    VoiceDiaryView(settingsStore: settings)
                } label: {
                    Label(
                        content.diaryCount > 0 ? "昨天记了 \(content.diaryCount) 篇日记" : "昨天没有记日记",
                        systemImage: "book.fill"
                    )
                    .foregroundStyle(.primary)
                }
            }
        } header: {
            Label("昨日日记", systemImage: "book")
        }
    }

    private func automationSection(_ content: DailyBriefingEngine.Content) -> some View {
        Section {
            if let note = content.skippedNotes.first(where: { $0.section == "自动化" }) {
                emptyRow("自动化未接入", detail: note.message)
            } else if let next = content.automationNextRunAt {
                NavigationLink {
                    AutomationListView(settings: settings)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("下次执行 \(Self.timeText(next))")
                            .font(.body)
                            .foregroundStyle(.primary)
                        if let name = content.automationTaskName {
                            Text("任务「\(name)」")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                emptyRow("暂无待执行任务", detail: "在「自动化」里创建任务并排程后，这里会显示下次执行时间")
            }
        } header: {
            Label("自动化", systemImage: "bolt.fill")
        }
    }

    private var weatherSection: some View {
        Section {
            if let content {
                if let weather = content.weather {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("\(weather.city) · \(weather.condition)", systemImage: "cloud.sun")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        Text("气温 \(weather.low)～\(weather.high)℃，当前 \(weather.temperature)℃")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                } else if let note = content.skippedNotes.first(where: { $0.section == "天气" }) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("天气暂未播报", systemImage: "cloud.sun")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(note.message)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 8)
                }
            }
        } header: {
            Label("天气", systemImage: "cloud.sun")
        }
    }

    @ViewBuilder
    private func skippedSection(_ content: DailyBriefingEngine.Content) -> some View {
        if !content.skippedNotes.isEmpty {
            Section {
                ForEach(content.skippedNotes) { note in
                    Label(note.message, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("本次未读取的数据", systemImage: "exclamationmark.triangle")
            }
        }
    }

    // MARK: - 通用

    private func briefRow(_ item: DailyBriefingEngine.BriefItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if let timeText = item.timeText {
                Text(timeText)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .frame(width: 52, alignment: .leading)
                    .foregroundStyle(.primary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func emptyRow(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    private static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
