import Foundation
import SwiftUI

/// 语音日记录音状态。
enum DiaryRecordingState: Equatable {
    case idle
    case recording
    case transcribing
}

/// 语音日记 ViewModel：
/// 按住说话（AudioCaptureManager）→ 松开后 STT 转写（按 SettingsStore.sttProvider 选服务）
/// → 简单规则分类（DiaryCategory.classify）→ 本地暂存（UserDefaults，诚实空状态）。
///
/// 记忆沉淀接口：`pendingEntries` 暴露尚未同步的条目；后续接入记忆中心
/// （网关 memory.add / LOVA memory-extract 等）时，把已上报条目的 id 传给
/// `markEntriesSynced(_:)` 标记已沉淀，避免重复上报。
@Observable
@MainActor
final class VoiceDiaryViewModel {
    // MARK: - 依赖（现有语音栈，只读引用）

    private let settingsStore: SettingsStore
    private let audioCapture = AudioCaptureManager()
    /// 按 SettingsStore.sttProvider 懒创建，规则与 ClawTalkApp.configureServices 一致
    private var transcriptionService: (any TranscriptionService)?
    private var levelTimer: Timer?
    private var recordingStart: Date?

    // MARK: - UI 状态

    /// 全部日记条目（本地暂存，最新在前）
    private(set) var entries: [DiaryEntry] = []
    var state: DiaryRecordingState = .idle
    /// 录音实时电平（驱动按住录音的外圈脉冲动画）
    var audioLevel: Float = 0
    var errorMessage: String? {
        didSet {
            if let errorMessage {
                LogCollector.record(module: "语音日记", errorMessage)
            }
        }
    }

    // MARK: - 记忆沉淀接口

    /// 尚未同步到记忆中心的条目（接入记忆中心后从这里取数据）
    private(set) var pendingEntries: [DiaryEntry] = []
    /// pendingEntries 变化回调（供记忆中心/外部模块监听，替换轮询）
    var onPendingEntriesChanged: (([DiaryEntry]) -> Void)?
    /// 已沉淀条目的 id 集合（持久化，避免重复上报）
    private var syncedEntryIDs: Set<UUID> = []

    // MARK: - 本地暂存

    private static let entriesDefaultsKey = "voice_diary_entries_v1"
    private static let syncedIDsDefaultsKey = "voice_diary_synced_ids_v1"

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        loadFromDefaults()
    }

    // MARK: - 录音

    /// 开始录音（按住说话达到阈值时调用）。
    /// 与聊天页一致：先停语音唤醒，避免两个音频引擎抢麦。
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

    /// 结束录音并开始转写（松开时调用）。过短的误触录音直接丢弃。
    func stopRecordingAndProcess() {
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
        let recordingDate = recordingStart ?? Date()

        Task {
            defer { restoreWakeListening() }
            guard let stt = makeTranscriptionService() else {
                errorMessage = "语音输入已在设置中关闭，请到设置页开启后重试"
                state = .idle
                return
            }
            do {
                let transcript = try await stt.transcribe(audioSamples: samples)
                let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    errorMessage = "没有识别到内容，请再试一次"
                    state = .idle
                    return
                }

                let entry = DiaryEntry(
                    date: recordingDate,
                    text: trimmed,
                    category: DiaryCategory.classify(trimmed)
                )
                entries.insert(entry, at: 0)
                pendingEntries.append(entry)
                onPendingEntriesChanged?(pendingEntries)
                persist()
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

    // MARK: - 记忆沉淀

    /// 把已上报记忆中心的条目标记为已同步（不再出现在 pendingEntries）。
    func markEntriesSynced(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        syncedEntryIDs.formUnion(ids)
        pendingEntries = entries.filter { !syncedEntryIDs.contains($0.id) }
        onPendingEntriesChanged?(pendingEntries)
        persist()
    }

    /// 设置里切换 STT 提供商后由外部调用，重建服务（等价于 App 层 reconfigureServices）。
    func rebuildSTTService() {
        transcriptionService = nil
    }

    // MARK: - STT 服务工厂

    /// 按 SettingsStore.sttProvider 创建 STT 服务（与 ClawTalkApp.configureServices 同规则）：
    /// - .apple → AppleSTTService(language: whisperLanguage)
    /// - .doubao → 有豆包 API Key 用 DoubaoSTTService，否则回退 Apple
    /// - voiceInputEnabled 关闭 → 返回 nil（页面提示去设置开启）
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

    // MARK: - 本地暂存（UserDefaults JSON）

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.entriesDefaultsKey)
        }
        UserDefaults.standard.set(syncedEntryIDs.map(\.uuidString), forKey: Self.syncedIDsDefaultsKey)
    }

    private func loadFromDefaults() {
        if let data = UserDefaults.standard.data(forKey: Self.entriesDefaultsKey),
           let decoded = try? JSONDecoder().decode([DiaryEntry].self, from: data) {
            entries = decoded
        }
        if let ids = UserDefaults.standard.stringArray(forKey: Self.syncedIDsDefaultsKey) {
            syncedEntryIDs = Set(ids.compactMap(UUID.init(uuidString:)))
        }
        pendingEntries = entries.filter { !syncedEntryIDs.contains($0.id) }
    }
}
