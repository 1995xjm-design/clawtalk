import Foundation
import SwiftUI
import UserNotifications

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
///
/// 第 4 层联动：待办 → CareReminderStore 自动加提醒；灵感 → MemoryProfileStore 自动入档案；
/// 联动状态回写条目（linkedReminderID / linkedToMemory），失败经 linkageNotice 在列表顶部提示。
@Observable
@MainActor
final class VoiceDiaryViewModel {
    // MARK: - 依赖（现有语音栈，只读引用）

    private let settingsStore: SettingsStore
    /// 提醒存储（待办联动）；入口可注入共享实例，默认自建
    private let careReminderStore: CareReminderStore
    /// 记忆档案存储（灵感联动）；入口可注入共享实例，默认自建
    private let memoryProfileStore: MemoryProfileStore
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

    /// 联动提示（如通知未授权导致提醒不响铃），显示在日记列表顶部；nil = 无提示
    private(set) var linkageNotice: String?

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

    init(
        settingsStore: SettingsStore,
        careReminderStore: CareReminderStore? = nil,
        memoryProfileStore: MemoryProfileStore? = nil
    ) {
        self.settingsStore = settingsStore
        self.careReminderStore = careReminderStore ?? CareReminderStore()
        self.memoryProfileStore = memoryProfileStore ?? MemoryProfileStore()
        loadFromDefaults()
    }

    // MARK: - 录音

    /// 开始录音（按住说话达到阈值时调用）。
    /// 与聊天页一致：先停语音唤醒，避免两个音频引擎抢麦。
    func startRecording() {
        guard state == .idle else { return }
        VoiceWakeCapability.shared.stopListening()
        errorMessage = nil
        linkageNotice = nil
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
                // 第 4 层联动：待办 → 提醒；灵感 → 记忆中心档案
                await performLinkage(for: entry)
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

    // MARK: - 第 4 层联动（待办→提醒 / 灵感→记忆）

    /// 按分类执行联动。失败不静默：写 linkageNotice，由列表顶部提示。
    private func performLinkage(for entry: DiaryEntry) async {
        switch entry.category {
        case .todo:
            await linkTodoToReminder(entry)
        case .inspiration:
            linkInspirationToMemory(entry)
        case .diary:
            break
        }
    }

    /// 待办 → CareReminderStore.add：标题 + 从文本提取的时间（简单规则）。
    /// 通知未授权时提醒仍会存入列表，但到点不响铃——经 linkageNotice 诚实提示。
    private func linkTodoToReminder(_ entry: DiaryEntry) async {
        let intent = Self.extractReminderIntent(from: entry.text, recordedAt: entry.date)
        let reminder = CareReminder(
            title: intent.title,
            time: intent.time,
            category: .custom,
            repeatType: intent.repeatType,
            enabled: true,
            createdAt: entry.createdAt
        )
        let added = careReminderStore.add(reminder)
        updateEntry(entry.id) { $0.linkedReminderID = added.id }

        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            break
        case .denied:
            linkageNotice = "「\(intent.title)」已保存为提醒，但通知权限未开启，到点不会响铃。请到系统设置开启 ClawTalk 通知。"
        case .notDetermined:
            linkageNotice = "「\(intent.title)」已保存为提醒，通知权限尚未开启，授权后到点才会响铃。"
        @unknown default:
            break
        }
    }

    /// 灵感 → MemoryProfileStore：作为独立档案条目（category = 灵感）写入。
    private func linkInspirationToMemory(_ entry: DiaryEntry) {
        memoryProfileStore.addProfileEntry(
            category: .inspiration,
            summary: entry.text,
            source: "语音日记",
            date: entry.date
        )
        updateEntry(entry.id) { $0.linkedToMemory = true }
    }

    /// 联动成功后回写条目状态（entries 与 pendingEntries 同步）并持久化。
    private func updateEntry(_ id: UUID, mutate: (inout DiaryEntry) -> Void) {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            mutate(&entries[index])
        }
        if let index = pendingEntries.firstIndex(where: { $0.id == id }) {
            mutate(&pendingEntries[index])
        }
        persist()
    }

    // MARK: - 待办提醒时间提取（简单规则，后续可换 LLM）

    /// 从待办文本提取提醒标题 / 时间 / 重复方式。
    ///
    /// 时间规则（粗规则）：
    /// - 天：今天/今晚 → 当天；明天/明早/明晚 → 次日；后天 → +2 天；
    ///   「周X/星期X」→ 未来最近一个该日（不含今天，避免歧义）。
    /// - 时段默认：凌晨 6 点 / 早上·上午 9 点 / 中午 12 点 / 下午 15 点 / 晚上·今晚·明晚 20 点。
    /// - 时刻：3点 / 3点半 / 3点15分 / 15:00 / 15：00。
    /// - 无任何时间词：录音时刻 + 1 小时（例如「记得买牛奶」→ 1 小时后提醒）。
    /// - 重复：含「每天/每日/天天」→ 每天；否则一次性。
    private static func extractReminderIntent(
        from text: String,
        recordedAt date: Date
    ) -> (title: String, time: Date, repeatType: CareReminderRepeat) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.count > 30 ? String(trimmed.prefix(30)) + "…" : trimmed
        let calendar = Calendar.current

        var dayOffset = 0
        if text.contains("后天") {
            dayOffset = 2
        } else if text.contains("明天") || text.contains("明早") || text.contains("明晚") {
            dayOffset = 1
        } else if text.contains("今天") || text.contains("今晚") {
            dayOffset = 0
        }
        if let weekday = Self.weekdayNumber(in: text) {
            let today = calendar.component(.weekday, from: date)
            var diff = weekday - today
            if diff <= 0 { diff += 7 }
            dayOffset = diff
        }

        var defaultHour: Int?
        if text.contains("凌晨") {
            defaultHour = 6
        } else if text.contains("早上") || text.contains("上午") || text.contains("明早") {
            defaultHour = 9
        } else if text.contains("中午") {
            defaultHour = 12
        } else if text.contains("下午") {
            defaultHour = 15
        } else if text.contains("晚上") || text.contains("今晚") || text.contains("明晚") {
            defaultHour = 20
        }

        var hour: Int?
        var minute: Int?
        if let match = Self.firstMatch(#"(\d{1,2})\s*点(半|(\d{1,2})\s*分)?"#, in: text),
           let parsedHour = Int(match.groups[1]) {
            hour = parsedHour
            if match.groups[2] == "半" {
                minute = 30
            } else if let minuteText = match.groups[3], let parsedMinute = Int(minuteText) {
                minute = parsedMinute
            }
        }
        if hour == nil, let match = Self.firstMatch(#"(\d{1,2})[:：](\d{2})"#, in: text),
           let parsedHour = Int(match.groups[1]), let parsedMinute = Int(match.groups[2]) {
            hour = parsedHour
            minute = parsedMinute
        }

        let dayBase = calendar.date(byAdding: .day, value: dayOffset, to: date) ?? date
        let time: Date
        if let hour {
            var components = calendar.dateComponents([.year, .month, .day], from: dayBase)
            components.hour = hour
            components.minute = minute ?? 0
            time = calendar.date(from: components) ?? dayBase.addingTimeInterval(3600)
        } else if let defaultHour {
            var components = calendar.dateComponents([.year, .month, .day], from: dayBase)
            components.hour = defaultHour
            components.minute = 0
            time = calendar.date(from: components) ?? dayBase.addingTimeInterval(3600)
        } else {
            time = dayBase.addingTimeInterval(3600)
        }

        let repeatType: CareReminderRepeat =
            text.contains("每天") || text.contains("每日") || text.contains("天天") ? .daily : .none
        return (title, time, repeatType)
    }

    /// 「周X/星期X」→ Calendar weekday（1=周日 … 7=周六）。
    private static func weekdayNumber(in text: String) -> Int? {
        let numbers: [String: Int] = ["日": 1, "一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7, "天": 1]
        guard let match = Self.firstMatch(#"[周星期]([一二三四五六日天])"#, in: text) else { return nil }
        return numbers[match.groups[1]]
    }

    /// 正则首个匹配：整体 + 捕获组；无匹配返回 nil。
    private static func firstMatch(_ pattern: String, in text: String) -> (whole: String, groups: [String])? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsText = text as NSString
        guard let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: nsText.length)) else {
            return nil
        }
        var groups: [String] = []
        for index in 0..<match.numberOfRanges {
            let range = match.range(at: index)
            groups.append(range.location == NSNotFound ? "" : nsText.substring(with: range))
        }
        return (groups[0], groups)
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
