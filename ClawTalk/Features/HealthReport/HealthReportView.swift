import SwiftUI

/// 「健康周报」页：近 7 天步数柱状图 + 达标率 + insights 列表 + 语音朗读 + 分享文本。
///
/// 自动生成：.task 时生成当前周；下拉刷新强制重读健康数据；页脚标注生成时间。
/// TTS：与 DailyBriefingView 同链路（按 SettingsStore 选 SpeechService，
/// PCM 流 → AudioPlaybackManager 播放）；每次朗读新建 TTS 实例
/// （AppleTTSService.stop() 会把实例永久置 stopped，不复用）。
///
/// 主智能体接线：
/// - 主页卡：HealthReportCardView()（自带 NavigationLink 进本页）
/// - 独立入口：NavigationStack { HealthReportView(settings: settingsStore) }
struct HealthReportView: View {
    private let settings: SettingsStore

    @State private var healthViewModel: HealthViewModel
    @State private var careStore: CareReminderStore
    @State private var diaryViewModel: VoiceDiaryViewModel
    @State private var report: HealthReport?
    @State private var isLoading = false

    // MARK: - 播报播放状态

    @State private var isSpeaking = false
    @State private var speechError: String?
    @State private var speechTask: Task<Void, Never>?
    @State private var speechService: (any SpeechService)?
    @State private var audioPlayback = AudioPlaybackManager()

    init(
        settings: SettingsStore? = nil,
        healthViewModel: HealthViewModel? = nil,
        careReminderStore: CareReminderStore? = nil,
        diaryViewModel: VoiceDiaryViewModel? = nil
    ) {
        let resolvedSettings = settings ?? SettingsStore()
        let resolvedHealth = healthViewModel ?? HealthViewModel()
        let resolvedCare = careReminderStore ?? CareReminderStore()
        let resolvedDiary = diaryViewModel ?? VoiceDiaryViewModel(settingsStore: resolvedSettings)
        self.settings = resolvedSettings
        _healthViewModel = State(initialValue: resolvedHealth)
        _careStore = State(initialValue: resolvedCare)
        _diaryViewModel = State(initialValue: resolvedDiary)
    }

    var body: some View {
        List {
            if let report {
                playAndShareSection(report)
                summarySection(report)
                stepsSection(report)
                insightsSection(report)
                generatedAtSection(report)
                skippedSection(report)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("健康周报")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoading {
                ProgressView()
            }
        }
        .task { await load() }
        .refreshable { await load(forceRefresh: true) }
        .onDisappear { stopSpeaking() }
    }

    // MARK: - 朗读 & 分享

    private func playAndShareSection(_ report: HealthReport) -> some View {
        Section {
            playButton(report)
            if let speechError {
                Label(speechError, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            ShareLink(item: report.spokenText) {
                Label("分享周报文本", systemImage: "square.and.arrow.up")
            }
        } header: {
            Label("朗读 & 分享", systemImage: "speaker.wave.2.fill")
        }
    }

    private func playButton(_ report: HealthReport) -> some View {
        Button {
            if isSpeaking {
                stopSpeaking()
            } else {
                startSpeaking(report)
            }
        } label: {
            Label(
                isSpeaking ? "停止朗读" : "语音朗读周报",
                systemImage: isSpeaking ? "stop.circle.fill" : "speaker.wave.2.fill"
            )
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                isSpeaking ? Color.red : Color.orange,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(report.spokenText.isEmpty)
    }

    // MARK: - 本周概况

    private func summarySection(_ report: HealthReport) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(report.periodText)
                            .font(.subheadline.weight(.semibold))
                        Text("本周健康总结")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    goalRateBadge(report)
                }

                if report.hasStepsData {
                    HStack(spacing: 24) {
                        summaryItem("总步数", value: "\(report.totalSteps ?? 0)")
                        summaryItem("日均步数", value: report.avgSteps.map { "\($0)" } ?? "–")
                        summaryItem("达标天数", value: "\(report.goalDays)/\(report.steps.count)")
                    }
                } else {
                    Label("暂无步数数据", systemImage: "figure.walk")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("健康权限未开启或暂无数据，开启后生成真实步数周报，不会展示估算数字。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 6)
        } header: {
            Label("本周概况", systemImage: "heart.fill")
        }
    }

    private func goalRateBadge(_ report: HealthReport) -> some View {
        let rate = report.goalRate ?? 0
        let text = report.goalRate == nil ? "无数据" : "达标率 \(Int((rate * 100).rounded()))%"
        return Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(rate >= 0.7 ? .green : .orange)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(Color(.secondarySystemGroupedBackground))
            )
    }

    private func summaryItem(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
    }

    // MARK: - 每日步数

    private func stepsSection(_ report: HealthReport) -> some View {
        Section {
            if report.hasStepsData {
                HealthReportBarChart(
                    values: report.steps,
                    dates: report.dayDates,
                    target: report.targetSteps
                )
                Text("柱状图为近 7 天真实步数，最后一天为今天；目标 \(report.targetSteps) 步/天。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                emptyDataRow(
                    title: "本周暂无步数数据",
                    detail: "在系统设置-健康中开启 ClawTalk 的步数读取权限后，下拉刷新即可生成周报。"
                )
            }
        } header: {
            Label("每日步数", systemImage: "chart.bar.fill")
        }
    }

    // MARK: - 洞察

    private func insightsSection(_ report: HealthReport) -> some View {
        Section {
            if report.insights.isEmpty {
                emptyDataRow(
                    title: "暂无洞察",
                    detail: "有真实数据后会自动生成步数最高/最低日、平均步数、达标率、提醒与日记等洞察。"
                )
            } else {
                ForEach(report.insights, id: \.self) { insight in
                    Label(insight, systemImage: "sparkles")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }
            }
        } header: {
            Label("本周洞察", systemImage: "lightbulb.fill")
        }
    }

    // MARK: - 生成时间

    private func generatedAtSection(_ report: HealthReport) -> some View {
        Section {
            HStack {
                Label("生成时间", systemImage: "clock")
                Spacer()
                Text(report.generatedTimeText)
                    .foregroundStyle(.secondary)
            }
            .font(.footnote)
        } header: {
            Label("关于本报告", systemImage: "info.circle")
        }
    }

    // MARK: - 跳过说明

    @ViewBuilder
    private func skippedSection(_ report: HealthReport) -> some View {
        if !report.skippedNotes.isEmpty {
            Section {
                ForEach(report.skippedNotes, id: \.self) { note in
                    Label(note, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("本次未读取的数据", systemImage: "exclamationmark.triangle")
            }
        }
    }

    private func emptyDataRow(title: String, detail: String) -> some View {
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

    // MARK: - 加载

    private func load(forceRefresh: Bool = false) async {
        isLoading = true
        defer { isLoading = false }
        speechError = nil
        let generator = HealthReportGenerator(
            healthViewModel: healthViewModel,
            careReminderStore: careStore,
            diaryViewModel: diaryViewModel
        )
        report = await generator.generate(forceRefresh: forceRefresh)
    }

    // MARK: - 语音朗读

    private func startSpeaking(_ report: HealthReport) {
        guard !report.spokenText.isEmpty else { return }
        stopSpeaking()

        let tts = makeSpeechService()
        speechService = tts
        do {
            try audioPlayback.start()
        } catch {
            speechError = "语音朗读启动失败：\(AppErrorText.localized(error.localizedDescription))"
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
                LogCollector.record(module: "健康周报", "朗读失败：\(AppErrorText.localized(error.localizedDescription))")
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
}

/// 近 7 天步数柱状图（纯 SwiftUI）：每根柱 = 当天步数，今天高亮，达标日加深。
struct HealthReportBarChart: View {
    let values: [Int]
    let dates: [Date]
    let target: Int

    private var maxValue: Int { max(values.max() ?? 0, 1) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                let date = index < dates.count ? dates[index] : Date()
                VStack(spacing: 6) {
                    Text("\(value)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(barColor(for: value, date: date))
                        .frame(height: barHeight(for: value))
                        .frame(maxWidth: .infinity)
                    Text(barLabel(for: date))
                        .font(.caption2)
                        .foregroundStyle(Calendar.current.isDateInToday(date) ? .primary : .secondary)
                }
            }
        }
        .frame(height: 150)
        .padding(.vertical, 6)
    }

    private func barHeight(for value: Int) -> CGFloat {
        guard value > 0 else { return 4 }
        return max(4, CGFloat(value) / CGFloat(maxValue) * 110)
    }

    private func barColor(for value: Int, date: Date) -> Color {
        let metGoal = value >= target
        let base: Color = metGoal ? .orange : .orange.opacity(0.45)
        return Calendar.current.isDateInToday(date) ? base : base.opacity(0.7)
    }

    private func barLabel(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "今天" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "E"
        return formatter.string(from: date)
    }
}
