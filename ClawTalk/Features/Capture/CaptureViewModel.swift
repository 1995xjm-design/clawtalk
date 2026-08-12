import Foundation
import SwiftUI
import UserNotifications

/// 随手捕捉：统一归档去向。
/// - 自动判断会产出 .reminder / .expense / .memory / .diary；
/// - 手动改去向只提供四选一（日记/记忆/待办/记账），提醒去向仅由自动判断产出。
enum CaptureDestination: String, CaseIterable, Identifiable, Equatable {
    case reminder = "提醒"
    case diary = "日记"
    case memory = "记忆"
    case todo = "待办"
    case expense = "记账"

    var id: String { rawValue }

    /// 手动改去向的四选一（提醒由自动判断专用，不提供手动选）。
    static let manualChoices: [CaptureDestination] = [.diary, .memory, .todo, .expense]

    var systemImage: String {
        switch self {
        case .reminder: return "bell.fill"
        case .diary: return "book.fill"
        case .memory: return "brain.fill"
        case .todo: return "checklist"
        case .expense: return "yensign.circle.fill"
        }
    }
}

/// 归档结果反馈：成功（绿色横幅）/ 失败（橙色横幅，不静默）。
struct CaptureFeedback: Equatable {
    enum Tone: Equatable {
        case success
        case failure
    }

    let tone: Tone
    let destination: CaptureDestination?
    let title: String
    /// 补充说明（如「已加入提醒」「通知权限未开启」）；异步权限检查后可能被更新。
    var detail: String?
}

/// 捕捉页状态。
enum CaptureState: Equatable {
    case idle
    case recording
    case transcribing
}

/// 随手捕捉 ViewModel：
/// 按住说话（AudioCaptureManager）→ STT 转写（按 SettingsStore.sttProvider 选服务）
/// → 自动判断去向并归档（提醒/记忆/记账/日记）→ 顶部横幅反馈，失败不静默。
///
/// 归档目标接口（已按现有真实签名接线）：
/// - CareReminderStore.add(_ reminder: CareReminder) -> CareReminder（提醒/待办联动）
/// - MemoryProfileStore.addProfileEntry(category:summary:source:date:) -> MemoryProfile（记忆）
/// - DiaryEntry + DiaryCategory.classify（日记，独立本地暂存，见 diaryDefaultsKey 的 TODO）
/// - ExpenseVoiceParser.parse + ExpenseStore.add(amount:type:category:note:date:)（记账）
@Observable
@MainActor
final class CaptureViewModel {
    // MARK: - 依赖（与 VoiceDiaryViewModel 同款，可注入共享实例）

    private let settingsStore: SettingsStore
    private let careReminderStore: CareReminderStore
    private let memoryProfileStore: MemoryProfileStore
    private let expenseStore: ExpenseStore
    private let audioCapture = AudioCaptureManager()
    /// 按 SettingsStore.sttProvider 懒创建，规则与 VoiceDiaryViewModel.makeTranscriptionService 一致
    private var transcriptionService: (any TranscriptionService)?
    private var levelTimer: Timer?
    private var recordingStart: Date?

    // MARK: - UI 状态

    private(set) var state: CaptureState = .idle
    /// 最近一次识别/输入的文本（识别结果）
    private(set) var transcript: String = ""
    /// 最近一次自动判断的去向
    private(set) var detectedDestination: CaptureDestination?
    /// 归档反馈（页面顶部横幅）
    private(set) var feedback: CaptureFeedback?
    /// 录音实时电平（驱动按住录音的外圈脉冲动画）
    var audioLevel: Float = 0
    var errorMessage: String? {
        didSet {
            if let errorMessage {
                LogCollector.record(module: "随手捕捉", errorMessage)
            }
        }
    }

    /// 本次捕捉已保存的日记条目（最新在前，供后续接线读取）
    private(set) var savedDiaryEntries: [DiaryEntry] = []

    private static let diaryDefaultsKey = "capture_diary_entries_v1"

    init(
        settingsStore: SettingsStore,
        careReminderStore: CareReminderStore? = nil,
        memoryProfileStore: MemoryProfileStore? = nil,
        expenseStore: ExpenseStore? = nil
    ) {
        self.settingsStore = settingsStore
        self.careReminderStore = careReminderStore ?? CareReminderStore()
        self.memoryProfileStore = memoryProfileStore ?? MemoryProfileStore()
        self.expenseStore = expenseStore ?? ExpenseStore()
        loadDiaryEntries()
    }

    // MARK: - 录音（与语音日记同款：先停语音唤醒，避免两个音频引擎抢麦）

    /// 开始录音（按住说话达到阈值时调用）。
    func startRecording() {
        guard state == .idle else { return }
        VoiceWakeCapability.shared.stopListening()
        errorMessage = nil
        feedback = nil
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

    /// 结束录音并转写、自动归档（松开时调用）。过短的误触录音直接丢弃。
    func stopRecordingAndCapture() {
        guard state == .recording else { return }
        stopLevelTimer()
        let samples = audioCapture.stopRecording()

        // 与语音日记同阈值：<0.5s 或样本过少视为误触
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
                let transcriptText = try await stt.transcribe(audioSamples: samples)
                let trimmed = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    errorMessage = "没有识别到内容，请再试一次"
                    state = .idle
                    return
                }
                state = .idle
                process(trimmed)
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

    // MARK: - 文本输入

    /// 文本框提交：空内容不发。
    func submitText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "请输入内容或按住按钮说话"
            return
        }
        process(trimmed)
    }

    // MARK: - 统一处理：判断去向 + 自动归档

    private func process(_ text: String) {
        transcript = text
        errorMessage = nil
        feedback = nil

        let destination = Self.detectDestination(for: text)
        detectedDestination = destination
        archive(text: text, to: destination, isManual: false)
    }

    /// 手动改去向（四选一）：追加归档一条到所选位置，原自动归档保留。
    func archiveManually(to destination: CaptureDestination) {
        guard !transcript.isEmpty else { return }
        archive(text: transcript, to: destination, isManual: true)
    }

    // MARK: - 自动判断规则

    /// 去向判断优先级：提醒 > 记账 > 灵感(记忆) > 日记。
    /// - 提醒：提醒我/记得/帮我设…（与 DiaryCategory.classify 的待办词表同源）
    /// - 记账：含金额（XX元 / XX块 / 十块钱）
    /// - 记忆：灵感/想法/点子/脑洞/突然想到/我想/主意/创意
    /// - 其他：日记（DiaryCategory.classify 继续细分待办/灵感，联动照旧）
    static func detectDestination(for text: String) -> CaptureDestination {
        if Self.hasReminderIntent(text) { return .reminder }
        if Self.hasAmount(text) { return .expense }
        if Self.hasInspirationSignal(text) { return .memory }
        return .diary
    }

    private static func hasReminderIntent(_ text: String) -> Bool {
        let keywords = [
            "提醒我", "提醒一下", "记得", "别忘了", "别忘", "要记得",
            "帮我设", "帮我设置", "帮我定", "设个提醒", "设置提醒", "设提醒",
            "定个提醒", "安排个提醒", "安排提醒"
        ]
        return keywords.contains { text.contains($0) }
    }

    private static func hasInspirationSignal(_ text: String) -> Bool {
        let keywords = ["灵感", "想法", "点子", "脑洞", "突然想到", "我想", "主意", "创意"]
        return keywords.contains { text.contains($0) }
    }

    /// 金额判断：与语音记账共用 ExpenseVoiceParser（金额规则以它为准，
    /// 支持 元/块/块钱、¥ 前缀、花钱动词后裸数字、收入词 + 裸数字）。
    private static func hasAmount(_ text: String) -> Bool {
        // 与语音记账同一解析器：金额判断以 ExpenseVoiceParser 为准
        return ExpenseVoiceParser.parse(text) != nil
    }

    // MARK: - 归档执行

    private func archive(text: String, to destination: CaptureDestination, isManual: Bool) {
        switch destination {
        case .reminder:
            archiveToReminder(text)
        case .memory:
            archiveToMemory(text)
        case .expense:
            archiveToExpense()
        case .diary:
            archiveToDiary(text, forceDiaryCategory: isManual)
        case .todo:
            archiveToTodo(text)
        }
    }

    /// 提醒：VoiceReminderParser 解析时间/类别；解析不出时间时兜底 1 小时后（与语音日记一致）。
    private func archiveToReminder(_ text: String) {
        let reminder: CareReminder
        let fallbackNote: String?
        switch VoiceReminderParser.parse(text) {
        case .success(let draft):
            reminder = CareReminder(
                title: draft.title,
                time: draft.time,
                category: draft.category,
                repeatType: draft.repeatType,
                enabled: true,
                scheduledDate: draft.scheduledDate
            )
            fallbackNote = nil
        case .failure:
            reminder = CareReminder(
                title: VoiceReminderParser.extractTitle(from: text),
                time: Date().addingTimeInterval(3600),
                category: .custom,
                repeatType: .none,
                enabled: true
            )
            fallbackNote = "没识别出时间，默认 1 小时后提醒"
        }

        let added = careReminderStore.add(reminder)
        feedback = CaptureFeedback(
            tone: .success,
            destination: .reminder,
            title: "已归档到：提醒",
            detail: ["已加入提醒", fallbackNote].compactMap { $0 }.joined(separator: "，")
        )
        Task { await notifyReminderPermissionNote(title: added.title) }
    }

    /// 记忆：自动（灵感信号）与手动共用——复用 MemoryProfileStore 现有分类规则定类，
    /// 归不出类时存为「事实」，不瞎猜分类。
    private func archiveToMemory(_ text: String) {
        let category = MemoryProfileStore.classify(text)?.category ?? .fact
        memoryProfileStore.addProfileEntry(
            category: category,
            summary: text,
            source: "随手捕捉"
        )
        feedback = CaptureFeedback(
            tone: .success,
            destination: .memory,
            title: "已归档到：记忆",
            detail: "已存入记忆中心（\(category.rawValue)）"
        )
    }

    /// 记账：与语音记账同一套解析（ExpenseVoiceParser）→ ExpenseStore 落库。
    /// 解析不出金额/金额无效时诚实橙色失败并保留原文，不假装归档成功。
    private func archiveToExpense() {
        guard let draft = ExpenseVoiceParser.parse(transcript) else {
            feedback = CaptureFeedback(
                tone: .failure,
                destination: .expense,
                title: "归档失败：没有识别出金额",
                detail: "请带上金额，如「今天买咖啡花了28」「打车35块」；原文已保留在识别结果里。"
            )
            return
        }
        guard expenseStore.add(
            amount: draft.amount,
            type: draft.type,
            category: draft.category,
            note: draft.note,
            date: Date()
        ) != nil else {
            feedback = CaptureFeedback(
                tone: .failure,
                destination: .expense,
                title: "归档失败：金额无效",
                detail: "金额必须大于 0，原文已保留在识别结果里。"
            )
            return
        }
        feedback = CaptureFeedback(
            tone: .success,
            destination: .expense,
            title: "已归档到：记账",
            detail: "已记一笔\(draft.type.rawValue) \(draft.amount.expenseAmountText)元（\(draft.category.rawValue)）"
        )
    }

    /// 日记：自动走 DiaryCategory.classify 细分（待办/灵感联动照旧，与语音日记一致）；
    /// 手动选「日记」则强制存为 .diary，不做联动。
    private func archiveToDiary(_ text: String, forceDiaryCategory: Bool) {
        let category: DiaryCategory = forceDiaryCategory ? .diary : DiaryCategory.classify(text)
        var entry = DiaryEntry(text: text, category: category)
        savedDiaryEntries.insert(entry, at: 0)
        persistDiaryEntries()

        switch category {
        case .todo:
            // 防御分支：提醒词表已覆盖 DiaryCategory 全部待办词，正常流程走不到这里
            let reminder = makeReminder(from: entry)
            let added = careReminderStore.add(reminder)
            entry.linkedReminderID = added.id
            updateSavedEntry(entry)
            feedback = CaptureFeedback(
                tone: .success,
                destination: .diary,
                title: "已归档到：日记",
                detail: "已加入提醒「\(added.title)」"
            )
            Task { await notifyReminderPermissionNote(title: added.title) }
        case .inspiration:
            memoryProfileStore.addProfileEntry(
                category: .inspiration,
                summary: entry.text,
                source: "随手捕捉",
                date: entry.date
            )
            entry.linkedToMemory = true
            updateSavedEntry(entry)
            feedback = CaptureFeedback(
                tone: .success,
                destination: .diary,
                title: "已归档到：日记",
                detail: "已存入记忆中心（灵感）"
            )
        case .diary:
            feedback = CaptureFeedback(
                tone: .success,
                destination: .diary,
                title: "已归档到：日记",
                detail: nil
            )
        }
    }

    /// 待办：手动选「待办」= 存 DiaryEntry(.todo) + 联动 CareReminderStore（与语音日记的待办一致）。
    private func archiveToTodo(_ text: String) {
        var entry = DiaryEntry(text: text, category: .todo)
        savedDiaryEntries.insert(entry, at: 0)
        persistDiaryEntries()

        let reminder = makeReminder(from: entry)
        let added = careReminderStore.add(reminder)
        entry.linkedReminderID = added.id
        updateSavedEntry(entry)

        feedback = CaptureFeedback(
            tone: .success,
            destination: .todo,
            title: "已归档到：待办",
            detail: "已加入提醒「\(added.title)」"
        )
        Task { await notifyReminderPermissionNote(title: added.title) }
    }

    /// 待办/日记中的待办 → CareReminder：优先 VoiceReminderParser 解析；
    /// 解析不出时间兜底录音时间 + 1 小时（与语音日记的兜底一致）。
    private func makeReminder(from entry: DiaryEntry) -> CareReminder {
        switch VoiceReminderParser.parse(entry.text) {
        case .success(let draft):
            return CareReminder(
                title: draft.title,
                time: draft.time,
                category: draft.category,
                repeatType: draft.repeatType,
                enabled: true,
                scheduledDate: draft.scheduledDate,
                createdAt: entry.createdAt
            )
        case .failure:
            return CareReminder(
                title: VoiceReminderParser.extractTitle(from: entry.text),
                time: entry.createdAt.addingTimeInterval(3600),
                category: .custom,
                repeatType: .none,
                enabled: true,
                createdAt: entry.createdAt
            )
        }
    }

    /// 联动成功后回写条目并持久化。
    private func updateSavedEntry(_ entry: DiaryEntry) {
        if let index = savedDiaryEntries.firstIndex(where: { $0.id == entry.id }) {
            savedDiaryEntries[index] = entry
            persistDiaryEntries()
        }
    }

    /// 提醒存入后检查通知权限：未授权时补一句诚实提示（不弹授权框）。
    private func notifyReminderPermissionNote(title: String) async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            break
        case .denied:
            feedback?.detail = "「\(title)」已保存为提醒，但通知权限未开启，到点不会响铃。请到系统设置开启 ClawTalk 通知。"
        case .notDetermined:
            feedback?.detail = "「\(title)」已保存为提醒，通知权限尚未开启，授权后到点才会响铃。"
        @unknown default:
            break
        }
    }

    // MARK: - STT 服务工厂

    /// 按 SettingsStore.sttProvider 创建 STT 服务（与 VoiceDiaryViewModel 同规则）：
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

    // MARK: - 日记条目本地暂存（UserDefaults JSON）

    // TODO(主智能体接线)：语音日记条目暂存在 VoiceDiaryViewModel（私有 key
    // voice_diary_entries_v1，无公开写入接口）。为避免双写互相覆盖，随手捕捉的
    // 日记条目先用独立 key capture_diary_entries_v1 暂存；待日记组提供共享
    // DiaryStore（或 VoiceDiaryViewModel 暴露 add(entry:)）后改为写入同一数据源。
    private func persistDiaryEntries() {
        if let data = try? JSONEncoder().encode(savedDiaryEntries) {
            UserDefaults.standard.set(data, forKey: Self.diaryDefaultsKey)
        }
    }

    private func loadDiaryEntries() {
        if let data = UserDefaults.standard.data(forKey: Self.diaryDefaultsKey),
           let decoded = try? JSONDecoder().decode([DiaryEntry].self, from: data) {
            savedDiaryEntries = decoded
        }
    }
}
