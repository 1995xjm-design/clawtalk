import Foundation
import SwiftUI
import Observation
import UIKit

/// 摘要页状态。
enum SummarizePageState: Equatable {
    case idle
    case recording
    case transcribing
    case summarizing
}

/// 摘要页 ViewModel：输入（粘贴/分享/口述）+ 长度选择（短/中/长）
/// + AI/本地双路摘要（AI 失败本地规则降级并诚实标注）+ 保存/分享/朗读。
@Observable
@MainActor
final class SummarizeViewModel {
    // MARK: - 依赖（现有语音栈/网关，只读引用）

    private let settingsStore: SettingsStore
    let store: SummarizerStore
    private let audioCapture = AudioCaptureManager()
    private var transcriptionService: (any TranscriptionService)?
    private var levelTimer: Timer?
    private var recordingStart: Date?

    // MARK: - UI 状态

    private(set) var state: SummarizePageState = .idle
    /// 输入文本（粘贴/分享/口述/手动输入）
    var text: String = ""
    /// 长度档位：短/中/长
    var length: SummaryLength = .medium
    /// 来源（最后一次填充方式；手动输入为 .input）
    private(set) var source: SummarySource = .input
    var audioLevel: Float = 0
    var errorMessage: String? {
        didSet {
            if let errorMessage {
                LogCollector.record(module: "长文摘要", errorMessage)
            }
        }
    }
    /// 摘要来源说明（诚实：AI 摘要 / 本地摘要（未接 AI）及原因）
    var summaryNotice: String?
    /// 分享自动预填提示
    var sharePrefillNotice: String?
    /// 当前生成结果（展示中，保存后进入 store 最近列表）
    private(set) var currentResult: SummaryResult?
    /// 结果是否已保存入库
    private(set) var isSaved = false
    /// 朗读状态
    private(set) var isSpeaking = false
    var speechError: String?

    private var speechService: (any SpeechService)?
    private var speechTask: Task<Void, Never>?
    private var audioPlayback = AudioPlaybackManager()
    /// 分享导出的 txt 临时文件（结果生成时刷新）
    private(set) var exportFileURL: URL?

    var isSummarizing: Bool {
        state == .summarizing
    }

    init(settingsStore: SettingsStore, store: SummarizerStore) {
        self.settingsStore = settingsStore
        self.store = store
    }

    // MARK: - 分享接收（App Group，只读预填）

    /// 页面出现时：输入区为空且有分享待发文本 → 自动预填（附件不参与摘要）。
    func checkSharedTextOnAppear() {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let shared = store.readSharedText() else { return }
        text = shared
        source = .share
        sharePrefillNotice = "已从系统分享自动带入 \(shared.count) 字文本（图片/文件附件不参与摘要）"
    }

    // MARK: - 粘贴板

    func pasteFromClipboard() {
        guard let pasted = UIPasteboard.general.string?
            .trimmingCharacters(in: .whitespacesAndNewlines), !pasted.isEmpty else {
            errorMessage = "剪贴板里没有可粘贴的文本"
            return
        }
        text = pasted
        source = .paste
        sharePrefillNotice = nil
    }

    // MARK: - 口述（按住说话，STT 与文档口述同链路）

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
                let recognized = try await stt.transcribe(audioSamples: samples)
                let trimmed = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    errorMessage = "没有识别到内容，请再试一次"
                    state = .idle
                    return
                }
                text = trimmed
                source = .dictation
                sharePrefillNotice = nil
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

    /// 设置里切换 STT 提供商后由外部调用，重建服务。
    func rebuildSTTService() {
        transcriptionService = nil
    }

    // MARK: - STT 服务工厂（与文档口述/会议纪要同规则）

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

    // MARK: - 生成摘要

    func generateSummary() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "还没有输入内容，先粘贴/分享一段长文或按住说话口述"
            return
        }
        guard state == .idle else { return }
        state = .summarizing
        errorMessage = nil
        summaryNotice = nil
        speechError = nil
        currentResult = nil
        isSaved = false
        exportFileURL = nil
        stopSpeaking()

        Task {
            let result = await store.summarize(
                text: trimmed,
                length: length,
                source: source,
                settings: settingsStore
            )
            currentResult = result
            exportFileURL = makeExportURL(for: result.record)
            if result.usedFallback {
                summaryNotice = result.fallbackReason.map { "\($0)，已改用本地规则摘要" }
                    ?? "本次为本地规则摘要（未接 AI）"
            } else {
                summaryNotice = "AI 摘要完成"
            }
            state = .idle
        }
    }

    // MARK: - 保存 / 清空

    func saveResult() {
        guard let result = currentResult, !isSaved else { return }
        store.add(result.record)
        isSaved = true
    }

    func clearAll() {
        stopSpeaking()
        text = ""
        source = .input
        sharePrefillNotice = nil
        summaryNotice = nil
        speechError = nil
        currentResult = nil
        isSaved = false
        exportFileURL = nil
        errorMessage = nil
    }

    // MARK: - 分享（txt 临时文件）

    private func makeExportURL(for record: SummaryRecord) -> URL? {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("clawtalk-summary-\(record.id.uuidString.prefix(8)).txt")
        do {
            try record.exportText.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - 朗读（SpeechService，与每日播报同链路）

    /// 每次朗读新建 TTS 服务实例：AppleTTSService.stop() 会把实例永久置 stopped，
    /// 复用旧实例会导致后续朗读静音，故不缓存（与 App 层按需重建同思路）。
    func startSpeaking() {
        guard let record = currentResult?.record, !record.summary.isEmpty else { return }
        stopSpeaking()

        let tts = makeSpeechService()
        speechService = tts
        do {
            try audioPlayback.start()
        } catch {
            speechError = "朗读启动失败：\(AppErrorText.localized(error.localizedDescription))"
            return
        }

        let spokenText = speakText(for: record)
        isSpeaking = true
        speechError = nil
        speechTask = Task { @MainActor in
            defer { isSpeaking = false }
            do {
                for try await chunk in tts.streamSpeech(text: spokenText) {
                    try Task.checkCancellation()
                    audioPlayback.enqueue(pcmData: chunk)
                }
                audioPlayback.markStreamingDone()
                await audioPlayback.waitUntilFinished()
            } catch is CancellationError {
                // 用户点了停止：静默结束
            } catch {
                LogCollector.record(module: "长文摘要", "朗读失败：\(AppErrorText.localized(error.localizedDescription))")
            }
            audioPlayback.stop()
        }
    }

    func stopSpeaking() {
        speechTask?.cancel()
        speechTask = nil
        speechService?.stop()
        speechService = nil
        audioPlayback.stop()
        isSpeaking = false
    }

    /// 朗读内容：摘要 + 要点（要点逐条读出）。
    private func speakText(for record: SummaryRecord) -> String {
        var parts = [record.summary]
        if !record.keyPoints.isEmpty {
            parts.append("要点：" + record.keyPoints.joined(separator: "。"))
        }
        return parts.joined(separator: "。")
    }

    /// 与 ClawTalkApp.configureServices 同规则：按设置选 Apple/Doubao/Edge，缺 key 回退 Apple。
    private func makeSpeechService() -> any SpeechService {
        let settings = settingsStore.settings
        switch settings.ttsProvider {
        case .apple:
            return AppleTTSService(speed: settings.ttsSpeed, pitch: settings.ttsPitch)
        case .doubao:
            if let key = SecureStorage.shared.doubaoAPIKey, !key.isEmpty {
                return DoubaoTTSService(apiKey: key, voiceID: settings.doubaoVoiceID)
            }
            return AppleTTSService(speed: settings.ttsSpeed, pitch: settings.ttsPitch)
        case .edge:
            return EdgeTTSService(voiceID: settings.edgeVoiceID, speed: settings.ttsSpeed, pitch: settings.ttsPitch)
        }
    }

    // MARK: - 录音电平轮询（驱动外圈脉冲动画）

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

/// 长文摘要页：输入区（文本框 + 粘贴 + 按住说话口述）+ 长度选择（短/中/长）
/// + 生成摘要（AI 优先，失败本地规则降级并诚实标注）+ 结果（保存/分享/朗读）
/// + 最近摘要列表（本地存储，可删除）。
struct SummarizeView: View {
    @State private var viewModel: SummarizeViewModel

    // 按住说话手势状态（参考 DictationRecorderView）
    @State private var isPressed = false
    @State private var holdTimer: Task<Void, Never>?
    @State private var isHolding = false
    @State private var showHoldHint = false

    private let settingsStore: SettingsStore
    private let hapticsEnabled: Bool
    private let recordButtonSize: CGFloat = 64
    /// 按住多久算开始录音（0.3 秒，与语音日记/会议纪要一致）
    private let holdThreshold: UInt64 = 300_000_000

    init(settingsStore: SettingsStore, store: SummarizerStore? = nil) {
        _viewModel = State(initialValue: SummarizeViewModel(
            settingsStore: settingsStore,
            store: store ?? SummarizerStore()
        ))
        self.settingsStore = settingsStore
        hapticsEnabled = settingsStore.settings.hapticsEnabled
    }

    var body: some View {
        VStack(spacing: 0) {
            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().opacity(0.3)
            bottomArea
        }
        .background(Color(.systemBackground))
        .navigationTitle("长文摘要")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { viewModel.checkSharedTextOnAppear() }
        .onDisappear { viewModel.discardActiveRecording() }
    }

    // MARK: - 内容区

    private var contentArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                inputSection
                lengthSection
                generateButton
                noticeSection
                if viewModel.currentResult != nil {
                    resultSection
                }
                recentSection
            }
            .padding(16)
        }
    }

    // MARK: - 输入区

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("输入长文")
                    .font(.headline)
                Spacer()
                Button {
                    viewModel.pasteFromClipboard()
                } label: {
                    Label("粘贴", systemImage: "doc.on.clipboard")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                if !viewModel.text.isEmpty {
                    Button("清空") { viewModel.clearAll() }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if viewModel.text.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("还没有摘要内容")
                        .font(.headline)
                    Text("粘贴文本、从其他 App 分享进来，\n或按住底部麦克风口述一段长文")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        viewModel.pasteFromClipboard()
                    } label: {
                        Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                }
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
            } else {
                TextEditor(text: $viewModel.text)
                    .frame(minHeight: 140)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
            }

            if let notice = viewModel.sharePrefillNotice {
                Label(notice, systemImage: "square.and.arrow.down")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if viewModel.text.count > SummarizerStore.maxCharacterCount {
                Label(
                    "原文超过 \(SummarizerStore.maxCharacterCount) 字，将截断前 8000 字生成摘要（原始全文仍完整保存）",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 长度选择

    private var lengthSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("摘要长度")
                .font(.headline)

            Picker("摘要长度", selection: $viewModel.length) {
                ForEach(SummaryLength.allCases) { length in
                    Text(length.label).tag(length)
                }
            }
            .pickerStyle(.segmented)

            Text(lengthHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var lengthHint: String {
        switch viewModel.length {
        case .short: return "短：约 60 字以内，只保留最核心信息"
        case .medium: return "中：约 150 字以内，覆盖主要信息"
        case .long: return "长：约 300 字以内，尽量覆盖关键信息"
        }
    }

    // MARK: - 生成按钮

    private var generateButton: some View {
        Button {
            viewModel.generateSummary()
        } label: {
            HStack(spacing: 8) {
                if viewModel.isSummarizing {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(viewModel.isSummarizing ? "摘要生成中…" : "生成摘要")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(viewModel.isSummarizing ? Color.gray : Color.orange)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .disabled(viewModel.isSummarizing || viewModel.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    // MARK: - 诚实标注

    @ViewBuilder
    private var noticeSection: some View {
        if let notice = viewModel.summaryNotice {
            Label(notice, systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let speechError = viewModel.speechError {
            Label(speechError, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 结果区

    @ViewBuilder
    private var resultSection: some View {
        if let result = viewModel.currentResult {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("摘要结果")
                        .font(.headline)
                    Spacer()
                    Text(result.record.summaryLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(result.record.usedFallback ? Color.orange : Color.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            (result.record.usedFallback ? Color.orange : Color.green).opacity(0.12),
                            in: Capsule()
                        )
                }

                Text(result.record.summary)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                if !result.record.keyPoints.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("要点")
                            .font(.subheadline.weight(.semibold))
                        ForEach(Array(result.record.keyPoints.enumerated()), id: \.offset) { _, point in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "star.fill")
                                    .font(.caption)
                                    .foregroundStyle(.yellow)
                                Text(point)
                                    .font(.subheadline)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                if let notice = result.record.truncationNotice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                actionRow(for: result)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
    }

    private func actionRow(for result: SummaryResult) -> some View {
        HStack(spacing: 10) {
            Button {
                viewModel.saveResult()
            } label: {
                Label(
                    viewModel.isSaved ? "已保存" : "保存",
                    systemImage: viewModel.isSaved ? "checkmark.circle.fill" : "bookmark"
                )
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    viewModel.isSaved ? Color.green.opacity(0.15) : Color(.systemGray5),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
            }
            .disabled(viewModel.isSaved)

            if let url = viewModel.exportFileURL {
                ShareLink(item: url, preview: SharePreview("长文摘要 · txt")) {
                    Label("分享", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            Color(.systemGray5),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                }
            } else {
                Label("分享（导出失败）", systemImage: "square.and.arrow.up")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }

            Button {
                if viewModel.isSpeaking {
                    viewModel.stopSpeaking()
                } else {
                    viewModel.startSpeaking()
                }
            } label: {
                Label(
                    viewModel.isSpeaking ? "停止" : "朗读",
                    systemImage: viewModel.isSpeaking ? "stop.circle.fill" : "speaker.wave.2.fill"
                )
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    Color(.systemGray5),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
            }
        }
    }

    // MARK: - 最近摘要（本地存储，可删除）

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("最近摘要")
                    .font(.headline)
                Spacer()
                if viewModel.store.totalCount > 0 {
                    Text("共 \(viewModel.store.totalCount) 条")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if viewModel.store.totalCount == 0 {
                Text("还没有摘要记录，生成第一条吧")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
            } else {
                ForEach(viewModel.store.recentRecords(limit: 5)) { record in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.summary)
                                .font(.subheadline)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Text("\(record.source.label) · \(record.length.label) · \(record.summaryLabel) · \(Self.shortDate(record.createdAt))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button {
                            viewModel.store.delete(id: record.id)
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("删除这条摘要")
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
                }
            }
        }
    }

    private static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - 底部：按住说话口述

    private var bottomArea: some View {
        GlobalVoiceInputEmbedded(settingsStore: settingsStore) { text, _ in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            viewModel.text = trimmed
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch viewModel.state {
        case .idle:
            Text(showHoldHint ? "按住说话，松开结束" : "按住说话，口述长文")
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
        case .summarizing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("摘要生成中…（AI 失败会自动用本地规则）")
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - 按住说话按钮（参考 DictationRecorderView）

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
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(width: recordButtonSize + 60, height: recordButtonSize + 60)
        .contentShape(Circle())
        .gesture(recordGesture)
        .animation(.spring(response: 0.25, dampingFraction: 0.65), value: isPressed)
        .disabled(viewModel.state == .transcribing || viewModel.state == .summarizing)
        .accessibilityLabel(accessibilityLabel)
    }

    private var recordingRingAngle: Double {
        viewModel.state == .recording ? 360 : 0
    }

    private var buttonColor: Color {
        switch viewModel.state {
        case .idle: return .openClawRed
        case .recording: return .red
        case .transcribing, .summarizing: return .openClawRed.opacity(0.5)
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
        case .transcribing, .summarizing:
            Image(systemName: "waveform")
        }
    }

    private var accessibilityLabel: String {
        switch viewModel.state {
        case .idle: return "按住说话，口述长文"
        case .recording: return "正在录音，松开结束"
        case .transcribing: return "正在转写"
        case .summarizing: return "正在生成摘要"
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