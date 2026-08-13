import SwiftUI

/// 「周报月报」页：顶部周/月切换（SegmentedPicker）+ 生成按钮 + 分区展示 +
/// 一键语音朗读 + ShareLink 分享文本。
///
/// 数据源：ReportGenerator 聚合；各数据源失败/未授权时分区如实标注跳过原因。
/// TTS：与 ClawTalkApp.configureServices 同规则创建 SpeechService
/// （默认 AppleTTSService(speed:pitch:)），PCM 音频流走 AudioPlaybackManager
/// （与 DailyBriefingView / VoiceAssistantViewModel.speak 同链路）。
///
/// 主智能体接线：
/// - 主页卡：ReportCardView(settings:)（自带 NavigationLink 进本页）
/// - 独立入口：NavigationStack { ReportView(settings: settingsStore) }
struct ReportView: View {
    private let settings: SettingsStore

    @State private var diaryViewModel: VoiceDiaryViewModel
    @State private var habitStore: HabitStore
    @State private var expenseStore: ExpenseStore
    @State private var memoryProfileStore: MemoryProfileStore

    @State private var report: PeriodReport?
    @State private var isLoading = false
    @State private var selectedPeriod: ReportPeriod = .week

    // MARK: - 播报播放状态（与 DailyBriefingView 同链路）

    @State private var isSpeaking = false
    @State private var speechError: String?
    @State private var speechTask: Task<Void, Never>?
    @State private var speechService: (any SpeechService)?
    @State private var audioPlayback = AudioPlaybackManager()

    init(
        settings: SettingsStore? = nil,
        diaryViewModel: VoiceDiaryViewModel? = nil,
        habitStore: HabitStore? = nil,
        expenseStore: ExpenseStore? = nil,
        memoryProfileStore: MemoryProfileStore? = nil
    ) {
        let resolvedSettings = settings ?? SettingsStore()
        let resolvedDiary = diaryViewModel ?? VoiceDiaryViewModel(settingsStore: resolvedSettings)
        let resolvedHabit = habitStore ?? HabitStore()
        let resolvedExpense = expenseStore ?? ExpenseStore()
        let resolvedMemory = memoryProfileStore ?? MemoryProfileStore()
        self.settings = resolvedSettings
        _diaryViewModel = State(initialValue: resolvedDiary)
        _habitStore = State(initialValue: resolvedHabit)
        _expenseStore = State(initialValue: resolvedExpense)
        _memoryProfileStore = State(initialValue: resolvedMemory)
    }

    var body: some View {
        List {
            periodPickerSection
            summarySection
            if let report {
                ForEach(report.sections) { section in
                    reportSection(section)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("周报月报")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let report {
                    ShareLink(item: report.sharedText) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("分享报告")
                }
            }
        }
        .overlay {
            if isLoading {
                ProgressView()
            }
        }
        // 周期切换自动取消旧生成任务并重新生成
        .task(id: selectedPeriod) { await load() }
        .refreshable { await load() }
        .onDisappear { stopSpeaking() }
        .overlay(alignment: .bottom) {
            GlobalVoiceInputFloating(settingsStore: settings)
                .padding(.bottom, 20)
        }
    }

    // MARK: - 顶部：周期切换 + 总结 + 操作按钮

    private var periodPickerSection: some View {
        Section {
            Picker("报告周期", selection: $selectedPeriod) {
                ForEach(ReportPeriod.allCases) { period in
                    Text(period.displayName).tag(period)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Label("报告周期", systemImage: "calendar")
        }
    }

    private var summarySection: some View {
        Section {
            if let report {
                VStack(alignment: .leading, spacing: 6) {
                    Text(report.periodText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(report.summary)
                        .font(.body)
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                emptyRow("正在生成报告…", detail: "自动汇总日记/健康/习惯/记账/待办/记忆")
            }

            HStack(spacing: 12) {
                Button {
                    if isSpeaking {
                        stopSpeaking()
                    } else {
                        startSpeaking()
                    }
                } label: {
                    Label(
                        isSpeaking ? "停止朗读" : "语音朗读",
                        systemImage: isSpeaking ? "stop.circle.fill" : "speaker.wave.2.fill"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        isSpeaking ? Color.red : Color.indigo,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .disabled(report == nil)

                Button {
                    Task { await load() }
                } label: {
                    Label("重新生成", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            Color(.secondarySystemFill),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
            }

            if let speechError {
                Label(speechError, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Label("本期总结", systemImage: "text.alignleft")
        }
    }

    // MARK: - 分区

    private func reportSection(_ section: ReportSection) -> some View {
        Section {
            if !section.content.isEmpty {
                ForEach(Array(section.content.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
            } else if let reason = section.skippedReason {
                emptyRow("数据已跳过", detail: reason)
            } else {
                emptyRow("暂无数据", detail: "有记录后会自动汇总到这里")
            }
        } header: {
            Label(section.title, systemImage: Self.icon(for: section.id))
        }
    }

    private static func icon(for sectionID: String) -> String {
        switch sectionID {
        case "diary": return "book.fill"
        case "health": return "heart.fill"
        case "habits": return "checkmark.seal.fill"
        case "expense": return "yensign.circle.fill"
        case "todos": return "checklist"
        case "memory": return "brain.head.profile"
        default: return "doc.text.fill"
        }
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

    // MARK: - 语音朗读（复用 DailyBriefingView 同链路）

    private func startSpeaking() {
        guard let report, !report.spokenText.isEmpty else { return }
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
                for try await chunk in tts.streamSpeech(text: report.spokenText) {
                    try Task.checkCancellation()
                    audioPlayback.enqueue(pcmData: chunk)
                }
                audioPlayback.markStreamingDone()
                await audioPlayback.waitUntilFinished()
            } catch is CancellationError {
                // 用户点了停止：静默结束
            } catch {
                LogCollector.record(module: "周报月报", "朗读失败：\(AppErrorText.localized(error.localizedDescription))")
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
        let generator = ReportGenerator(
            diaryViewModel: diaryViewModel,
            habitStore: habitStore,
            expenseStore: expenseStore,
            memoryProfileStore: memoryProfileStore
        )
        report = await generator.generate(period: selectedPeriod)
    }
}
