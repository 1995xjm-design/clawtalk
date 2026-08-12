import SwiftUI

/// 差旅管家列表：进行中 / 即将出发 / 历史出行分组；
/// 顶部按住说话新建出行，右上角「+」手动新增（alert 表单）；
/// 每行展示目的地 + 日期 + 清单完成度，点击进入详情。
struct TravelListView: View {
    @State private var store: TravelStore
    @State private var settingsStore: SettingsStore
    @State private var careReminderStore: CareReminderStore
    @State private var voiceController: TravelVoiceController

    init(store: TravelStore? = nil, settings: SettingsStore? = nil, careReminderStore: CareReminderStore? = nil) {
        let resolvedSettings = settings ?? SettingsStore()
        _store = State(initialValue: store ?? TravelStore())
        _settingsStore = State(initialValue: resolvedSettings)
        _careReminderStore = State(initialValue: careReminderStore ?? CareReminderStore())
        _voiceController = State(initialValue: TravelVoiceController(settingsStore: resolvedSettings))
    }

    var body: some View {
        List {
            Section {
                holdToTalkRow
            } header: {
                Text(voiceController.isRecording ? "正在录音，松手识别" : "按住说话新建出行，松手识别")
            }

            if store.trips.isEmpty {
                ContentUnavailableView {
                    Label("暂无出行", systemImage: "airplane")
                } description: {
                    Text("点右上角「+」或按住上方按钮说「下周三去上海出差三天」。\n出行与清单数据只保存在本机。")
                } actions: {
                    Button("手动添加出行") {
                        openAddAlert()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            let ongoing = store.trips.filter { $0.travelStatus == .ongoing }
            let upcoming = store.trips.filter { $0.travelStatus == .upcoming }
            let history = store.trips.filter { $0.travelStatus == .history }

            if !ongoing.isEmpty {
                Section("进行中") {
                    ForEach(ongoing) { trip in
                        tripRow(trip)
                    }
                    .onDelete { offsets in deleteTrips(offsets, in: ongoing) }
                }
            }
            if !upcoming.isEmpty {
                Section("即将出发") {
                    ForEach(upcoming) { trip in
                        tripRow(trip)
                    }
                    .onDelete { offsets in deleteTrips(offsets, in: upcoming) }
                }
            }
            if !history.isEmpty {
                Section("历史出行") {
                    ForEach(history) { trip in
                        tripRow(trip)
                    }
                    .onDelete { offsets in deleteTrips(offsets, in: history) }
                }
            }
        }
        .navigationTitle("差旅管家")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    openAddAlert()
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            NavigationStack {
                List {
                    Section("目的地") {
                        TextField("如：上海", text: $draftDestination)
                    }
                    Section("日期") {
                        DatePicker("出发日期", selection: $draftDeparture, displayedComponents: [.date, .hourAndMinute])
                        Toggle("设置返程日期", isOn: $hasReturn)
                        if hasReturn {
                            DatePicker("返程日期", selection: $draftReturn, displayedComponents: [.date, .hourAndMinute])
                        }
                    }
                    Section("目的（可选）") {
                        TextField("如：出差", text: $draftPurpose)
                    }
                    Section {
                        Button("保存") { saveDraft() }
                            .frame(maxWidth: .infinity)
                        Button("取消", role: .cancel) { resetDraft() }
                            .frame(maxWidth: .infinity)
                    }
                }
                .navigationTitle("新增出行")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
        }
        .alert("提示", isPresented: $showNoticeAlert, presenting: noticeMessage) { _ in
            Button("好") { noticeMessage = nil }
        } message: { message in
            Text(message)
        }
        .onAppear {
            voiceController.restoreWakeListening()
        }
    }

    // MARK: - 出行行

    private func tripRow(_ trip: TravelTrip) -> some View {
        NavigationLink {
            TravelDetailView(
                tripID: trip.id,
                store: store,
                settings: settingsStore,
                careReminderStore: careReminderStore
            )
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(trip.destination)
                        .font(.headline)
                    Spacer(minLength: 8)
                    Text(statusBadgeText(trip))
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(statusBadgeColor(trip).opacity(0.15))
                        .clipShape(Capsule())
                        .foregroundStyle(statusBadgeColor(trip))
                }
                Text(dateRangeText(trip))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let purpose = trip.purpose, !purpose.isEmpty {
                    Text(purpose)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                let completion = store.checklistCompletion(for: trip)
                HStack(spacing: 6) {
                    ProgressView(value: completion.total > 0 ? Double(completion.done) / Double(completion.total) : 0)
                        .tint(completion.done == completion.total && completion.total > 0 ? Color.green : Color.accentColor)
                    Text(completion.total > 0 ? "\(completion.done)/\(completion.total)" : "暂无清单")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func statusBadgeText(_ trip: TravelTrip) -> String {
        switch trip.travelStatus {
        case .upcoming:
            let days = trip.daysUntilDeparture
            return days == 0 ? "今天出发" : "\(days) 天后"
        case .ongoing:
            return "出行中"
        case .history:
            return "已结束"
        }
    }

    private func statusBadgeColor(_ trip: TravelTrip) -> Color {
        switch trip.travelStatus {
        case .upcoming: return .blue
        case .ongoing: return .green
        case .history: return .secondary
        }
    }

    private func dateRangeText(_ trip: TravelTrip) -> String {
        let departure = TravelStore.shortDateText(trip.departureDate)
        guard let returnDate = trip.returnDate else {
            return "\(departure) 出发"
        }
        return "\(departure) — \(TravelStore.shortDateText(returnDate))"
    }

    private func deleteTrips(_ offsets: IndexSet, in group: [TravelTrip]) {
        for offset in offsets {
            store.delete(id: group[offset].id)
        }
    }

    // MARK: - 手动新增（alert 表单）

    private func openAddAlert() {
        resetDraft()
        showAddSheet = true
    }

    private func resetDraft() {
        draftDestination = ""
        draftDeparture = Date()
        hasReturn = false
        draftReturn = Date()
        draftPurpose = ""
    }

    private func saveDraft() {
        let destination = draftDestination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty else {
            noticeMessage = "请填写目的地"; showNoticeAlert = true
            return
        }
        let purpose = draftPurpose.trimmingCharacters(in: .whitespacesAndNewlines)
        if hasReturn, draftReturn < draftDeparture {
            noticeMessage = "返程日期不能早于出发日期"; showNoticeAlert = true
            return
        }
        let resolvedPurpose = purpose.isEmpty ? nil : purpose
        let trip = TravelTrip(
            destination: destination,
            departureDate: draftDeparture,
            returnDate: hasReturn ? draftReturn : nil,
            purpose: resolvedPurpose,
            checklist: TravelStore.defaultChecklist(destination: destination, purpose: resolvedPurpose)
        )
        store.add(trip)
        showAddSheet = false; noticeMessage = nil
    }

    // MARK: - 语音新建

    private var holdToTalkRow: some View {
        Button(action: {}) {
            HStack {
                Image(systemName: voiceController.isRecording ? "waveform" : "mic.fill")
                Text(voiceController.isTranscribing ? "识别中…" : (voiceController.isRecording ? "正在录音…" : "按住说话新建出行"))
                if voiceController.isTranscribing {
                    Spacer()
                    ProgressView()
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(voiceController.isTranscribing)
        .gesture(recordGesture)
    }

    private var recordGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !voiceController.isRecording, !voiceController.isTranscribing else { return }
                voiceController.start()
                if let message = voiceController.lastError {
                    noticeMessage = message; showNoticeAlert = true
                }
            }
            .onEnded { _ in
                guard voiceController.isRecording else { return }
                Task {
                    if let text = await voiceController.stopAndTranscribe() {
                        applyVoiceText(text)
                    } else if let message = voiceController.lastError {
                        noticeMessage = message; showNoticeAlert = true
                    }
                }
            }
    }

    /// 语音文本落库：解析出目的地 + 出发日期 → 直接新建；
    /// 解析不出（或不完整）→ 预填已识别字段，弹手动填。
    private func applyVoiceText(_ text: String) {
        let parsed = TravelStore.parseVoice(text)
        if parsed.isComplete, let destination = parsed.destination, let departure = parsed.departureDate {
            let purpose = parsed.purpose
            let trip = TravelTrip(
                destination: destination,
                departureDate: departure,
                returnDate: parsed.returnDate,
                purpose: purpose,
                checklist: TravelStore.defaultChecklist(destination: destination, purpose: purpose)
            )
            store.add(trip)
            noticeMessage = "已新建「去\(destination)」的出行，清单已自动生成"; showNoticeAlert = true
        } else {
            draftDestination = parsed.destination ?? ""
            if let departure = parsed.departureDate {
                draftDeparture = departure
            }
            draftReturn = parsed.returnDate ?? Date()
            hasReturn = parsed.returnDate != nil
            draftPurpose = parsed.purpose ?? ""
            showAddSheet = true
        }
    }


    // MARK: - 状态

    @State private var showAddSheet = false
    @State private var showNoticeAlert = false
    @State private var noticeMessage: String?


    @State private var draftDestination = ""
    @State private var draftDeparture = Date()
    @State private var hasReturn = false
    @State private var draftReturn = Date()
    @State private var draftPurpose = ""
}

/// 出行详情：清单勾选、行程日程（读日历该时间段事件）、出发前提醒、语音修改。
struct TravelDetailView: View {
    let tripID: UUID

    @State private var store: TravelStore
    @State private var settingsStore: SettingsStore
    @State private var careReminderStore: CareReminderStore
    @State private var voiceController: TravelVoiceController
    @State private var voiceNotice: String?
    @State private var reminderMessage: String?
    @State private var itineraryEvents: [CalendarCapability.CalendarEvent] = []
    @State private var itineraryState = ItineraryLoadState.idle

    init(tripID: UUID, store: TravelStore, settings: SettingsStore, careReminderStore: CareReminderStore) {
        self.tripID = tripID
        _store = State(initialValue: store)
        _settingsStore = State(initialValue: settings)
        _careReminderStore = State(initialValue: careReminderStore)
        _voiceController = State(initialValue: TravelVoiceController(settingsStore: settings))
    }

    private var trip: TravelTrip? {
        store.trip(id: tripID)
    }

    var body: some View {
        List {
            if let trip {
                headerSection(trip)
                reminderSection(trip)
                checklistSection(trip)
                itinerarySection(trip)
                notesSection(trip)
                voiceUpdateSection(trip)
            } else {
                Section {
                    ContentUnavailableView("出行不存在", systemImage: "questionmark.circle")
                }
            }
        }
        .navigationTitle(trip?.destination ?? "出行详情")
        .task(id: trip?.departureDate) {
            await loadItinerary()
        }
        .alert(
            "提示",
            isPresented: Binding(
                get: { voiceNotice != nil || reminderMessage != nil },
                set: { if !$0 { voiceNotice = nil; reminderMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {
                voiceNotice = nil
                reminderMessage = nil
            }
        } message: {
            Text(voiceNotice ?? reminderMessage ?? "")
        }
        .onAppear {
            voiceController.restoreWakeListening()
        }
    }

    // MARK: - 头部

    @ViewBuilder
    private func headerSection(_ trip: TravelTrip) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(trip.destination)
                        .font(.title3.bold())
                    Spacer()
                    Text(statusText(trip))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(dateRangeText(trip))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let purpose = trip.purpose, !purpose.isEmpty {
                    Text(purpose)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                let completion = store.checklistCompletion(for: trip)
                if completion.total > 0 {
                    HStack(spacing: 8) {
                        ProgressView(value: Double(completion.done) / Double(completion.total))
                            .tint(completion.done == completion.total ? Color.green : Color.accentColor)
                        Text("清单 \(completion.done)/\(completion.total)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func statusText(_ trip: TravelTrip) -> String {
        switch trip.travelStatus {
        case .upcoming:
            let days = trip.daysUntilDeparture
            return days == 0 ? "今天出发" : "还有 \(days) 天出发"
        case .ongoing:
            return "出行中"
        case .history:
            return "已结束"
        }
    }

    private func dateRangeText(_ trip: TravelTrip) -> String {
        let departure = TravelStore.fullDateText(trip.departureDate)
        guard let returnDate = trip.returnDate else {
            return "\(departure) 出发"
        }
        return "\(departure) — \(TravelStore.fullDateText(returnDate))"
    }

    // MARK: - 出发前提醒

    @ViewBuilder
    private func reminderSection(_ trip: TravelTrip) -> some View {
        Section("出发前提醒") {
            if trip.daysUntilDeparture < 0 {
                Text("出行已开始，不再设置出发提醒")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    let created = store.scheduleDepartureReminders(for: trip, into: careReminderStore)
                    reminderMessage = created > 0
                        ? "已添加 \(created) 条出发提醒（出发前一天 09:00 / 出发前 3 小时）"
                        : "出发提醒已设置过，无需重复添加"
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: store.departureRemindersComplete(for: trip, in: careReminderStore) ? "bell.badge.fill" : "bell.badge")
                            .foregroundStyle(.orange)
                        Text(store.departureRemindersComplete(for: trip, in: careReminderStore)
                             ? "出发提醒已设置（前一天 09:00 / 前 3 小时）"
                             : "设置出发前提醒")
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                }
                Text("提醒会写入「健康提醒」列表，由本地通知到点提醒；已过时间不会响铃。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 出行清单

    @ViewBuilder
    private func checklistSection(_ trip: TravelTrip) -> some View {
        Section("出行清单") {
            if trip.checklist.isEmpty {
                Text("暂无清单")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(trip.checklist) { item in
                    Button {
                        store.toggleChecklistItem(tripID: trip.id, itemID: item.id)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(item.done ? Color.green : Color.secondary)
                            Text(item.text)
                                .strikethrough(item.done)
                                .foregroundStyle(item.done ? Color.secondary : Color.primary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 行程日程（读日历）

    @ViewBuilder
    private func itinerarySection(_ trip: TravelTrip) -> some View {
        Section("行程日程") {
            switch itineraryState {
            case .idle, .loading:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在读取日历事件…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            case .denied(let message):
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Text("读取失败：\(message)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .loaded:
                if itineraryEvents.isEmpty {
                    Text("该时间段内暂无日历事件")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(itineraryEvents.enumerated()), id: \.offset) { _, event in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(event.title)
                                    .font(.subheadline)
                                Spacer()
                                Text(eventTimeText(event))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let location = event.location, !location.isEmpty {
                                Text("📍 \(location)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    @MainActor
    private func loadItinerary() async {
        guard let trip = store.trip(id: tripID) else { return }
        itineraryState = .loading

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let departureDay = calendar.startOfDay(for: trip.departureDate)
        let endDay = calendar.startOfDay(for: trip.periodEndDate)
        let daysBack = max(0, calendar.dateComponents([.day], from: today, to: departureDay).day ?? 0)
        let daysAhead = max(0, calendar.dateComponents([.day], from: today, to: endDay).day ?? 0) + 1

        do {
            let events = try await CalendarCapability.listEvents(daysAhead: daysAhead, daysBack: daysBack)
            itineraryEvents = events
                .filter { event in
                    guard let start = TravelStore.isoDateFormatter.date(from: event.startDate) else { return false }
                    return start >= trip.departureDate && start < trip.periodEndDate
                }
                .sorted { lhs, rhs in
                    let lhsDate = TravelStore.isoDateFormatter.date(from: lhs.startDate) ?? .distantPast
                    let rhsDate = TravelStore.isoDateFormatter.date(from: rhs.startDate) ?? .distantPast
                    return lhsDate < rhsDate
                }
            itineraryState = .loaded
        } catch let error as CalendarCapability.CalendarError {
            switch error {
            case .denied(let type):
                itineraryState = .denied("\(type)权限被拒绝，无法读取行程日程")
            case .failed(let message):
                itineraryState = .failed(message)
            }
        } catch {
            itineraryState = .failed(error.localizedDescription)
        }
    }

    private func eventTimeText(_ event: CalendarCapability.CalendarEvent) -> String {
        guard let start = TravelStore.isoDateFormatter.date(from: event.startDate) else { return event.startDate }
        return TravelStore.timeText(start)
    }

    // MARK: - 备注

    @ViewBuilder
    private func notesSection(_ trip: TravelTrip) -> some View {
        Section("备注") {
            if let flights = trip.flights, !flights.isEmpty {
                ForEach(Array(flights.enumerated()), id: \.offset) { _, text in
                    Text("✈️ \(text)")
                }
            }
            if let hotels = trip.hotels, !hotels.isEmpty {
                ForEach(Array(hotels.enumerated()), id: \.offset) { _, text in
                    Text("🏨 \(text)")
                }
            }
            if let notes = trip.notes, !notes.isEmpty {
                Text(notes)
            }
            if (trip.flights?.isEmpty ?? true) && (trip.hotels?.isEmpty ?? true) && (trip.notes?.isEmpty ?? true) {
                Text("暂无航班/酒店/备注信息")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 语音修改

    @ViewBuilder
    private func voiceUpdateSection(_ trip: TravelTrip) -> some View {
        Section {
            Button(action: {}) {
                HStack {
                    Image(systemName: voiceController.isRecording ? "waveform" : "mic.fill")
                    Text(voiceController.isTranscribing ? "识别中…" : (voiceController.isRecording ? "正在录音，松手识别" : "按住说话修改行程"))
                    if voiceController.isTranscribing {
                        Spacer()
                        ProgressView()
                    }
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(voiceController.isTranscribing)
            .gesture(detailRecordGesture)
        } header: {
            Text("语音修改")
        } footer: {
            Text("说「下周三去上海出差三天」可更新目的地 / 出发日期 / 返程 / 目的。")
        }
    }

    private var detailRecordGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !voiceController.isRecording, !voiceController.isTranscribing else { return }
                voiceController.start()
                if let message = voiceController.lastError {
                    voiceNotice = message
                }
            }
            .onEnded { _ in
                guard voiceController.isRecording else { return }
                Task {
                    if let text = await voiceController.stopAndTranscribe() {
                        applyVoiceUpdate(text)
                    } else if let message = voiceController.lastError {
                        voiceNotice = message
                    }
                }
            }
    }

    /// 语音修改当前行程：只更新解析出的字段，解析不出诚实提示。
    private func applyVoiceUpdate(_ text: String) {
        guard var trip = store.trip(id: tripID) else { return }
        let parsed = TravelStore.parseVoice(text)
        var changed: [String] = []

        if let destination = parsed.destination, destination != trip.destination {
            trip.destination = destination
            changed.append("目的地")
        }
        if let departure = parsed.departureDate, departure != trip.departureDate {
            trip.departureDate = departure
            changed.append("出发日期")
        }
        if let returnDate = parsed.returnDate, returnDate != trip.returnDate {
            trip.returnDate = returnDate
            changed.append("返程日期")
        }
        if let purpose = parsed.purpose, purpose != trip.purpose {
            trip.purpose = purpose
            changed.append("目的")
        }

        if changed.isEmpty {
            voiceNotice = "没听清要修改的内容，请重新说或手动编辑"
        } else {
            store.update(trip)
            voiceNotice = "已更新：\(changed.joined(separator: "、"))"
        }
    }

    // MARK: - 状态

    enum ItineraryLoadState: Equatable {
        case idle
        case loading
        case loaded
        case denied(String)
        case failed(String)
    }
}

/// 差旅语音输入：按住说话（AudioCaptureManager）→ 松开转写（按 SettingsStore.sttProvider 选 STT）。
/// 规则与 VoiceDiaryViewModel / HabitsView 一致（先停语音唤醒、0.5s 误触阈值、转写后恢复唤醒）。
@MainActor
final class TravelVoiceController {
    private let audioCapture = AudioCaptureManager()
    private let settingsStore: SettingsStore
    private var transcriptionService: (any TranscriptionService)?
    private(set) var isRecording = false
    private(set) var isTranscribing = false
    var lastError: String?

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    /// 按住说话：先停语音唤醒，避免两个音频引擎抢麦。
    func start() {
        guard !isRecording, !isTranscribing else { return }
        lastError = nil
        VoiceWakeCapability.shared.stopListening()
        do {
            try audioCapture.startRecording()
            isRecording = true
        } catch {
            lastError = "无法开始录音：\(AppErrorText.localized(error.localizedDescription))"
            restoreWakeListening()
        }
    }

    /// 松开：返回转写文本；录音太短 / 未识别 / STT 关闭时返回 nil 并设置 lastError。
    func stopAndTranscribe() async -> String? {
        guard isRecording else { return nil }
        isRecording = false
        let samples = audioCapture.stopRecording()
        defer { restoreWakeListening() }

        guard samples.count > 8000 else {
            lastError = samples.isEmpty ? nil : "录音太短，请按住说完整一句话"
            return nil
        }

        isTranscribing = true
        defer { isTranscribing = false }

        guard let stt = makeTranscriptionService() else {
            lastError = "语音输入已在设置中关闭，请到设置页开启后重试"
            return nil
        }

        do {
            let text = try await stt.transcribe(audioSamples: samples)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                lastError = "没有识别到内容，请再说一遍"
                return nil
            }
            return text
        } catch {
            lastError = "识别失败：\(AppErrorText.localized(error.localizedDescription))"
            return nil
        }
    }

    func restoreWakeListening() {
        NotificationCenter.default.post(name: .clawTalkWakeRestartRequested, object: nil)
    }

    /// 按 SettingsStore.sttProvider 创建 STT 服务（与 ClawTalkApp.configureServices 同规则）：
    /// - .apple → AppleSTTService(language: whisperLanguage)
    /// - .doubao → 有豆包 API Key 用 DoubaoSTTService，否则回退 Apple
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
}
