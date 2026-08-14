import SwiftUI
import Observation
import UserNotifications

/// 会议纪要列表页：按日期分组，每条显示标题/议题数/待办数，点击看详情。
struct MeetingListView: View {
    @State private var store: MeetingStore
    @State private var careReminderStore: CareReminderStore
    private let settingsStore: SettingsStore

    init(
        settingsStore: SettingsStore = SettingsStore(),
        store: MeetingStore? = nil,
        careReminderStore: CareReminderStore? = nil
    ) {
        self.settingsStore = settingsStore
        _store = State(initialValue: store ?? MeetingStore())
        _careReminderStore = State(initialValue: careReminderStore ?? CareReminderStore())
    }

    var body: some View {
        Group {
            if store.notes.isEmpty {
                emptyState
            } else {
                noteList
            }
        }
        .navigationTitle("会议纪要")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    MeetingRecorderView(settingsStore: settingsStore, meetingStore: store)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("新建会议纪要")
            }
        }
    }

    // MARK: - 列表（按日期分组）

    private var noteList: some View {
        List {
            ForEach(store.groupedByDay) { group in
                Section(header: Text(Self.dayHeader(for: group.day))) {
                    ForEach(group.notes) { note in
                        NavigationLink {
                            MeetingDetailView(note: note, store: store, careReminderStore: careReminderStore)
                        } label: {
                            MeetingListRow(note: note)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    /// 日期分组标题：今天 / 昨天 / M月d日 EEEE。
    private static func dayHeader(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "今天" }
        if calendar.isDateInYesterday(day) { return "昨天" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEEE"
        return formatter.string(from: day)
    }

    // MARK: - 空状态（诚实，不塞假数据）

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.3.sequence")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("还没有会议纪要")
                .font(.headline)
            Text("点右上角 + 录一段会议，AI 会自动整理成议题、决定和待办。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 列表行：标题（本地降级带标注）+ 议题数/待办数。
private struct MeetingListRow: View {
    let note: MeetingNote

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(note.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !note.organizedByAI {
                    Text("本地整理")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15), in: Capsule())
                }
            }
            HStack(spacing: 12) {
                Label("\(note.topics.count) 个议题", systemImage: "list.bullet")
                Label("\(note.actionItems.count) 项待办", systemImage: "checklist")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// 纪要详情页：标题/日期/整理来源/参与者 + 摘要 + 议题 + 决定 + 待办（可一键加提醒）+ 原始转写。
struct MeetingDetailView: View {
    private let store: MeetingStore
    @State private var currentNote: MeetingNote
    @State private var careReminderStore: CareReminderStore
    @State private var reminderNotice: String?
    @State private var showRawTranscript = false
    @Environment(\.dismiss) private var dismiss

    init(note: MeetingNote, store: MeetingStore, careReminderStore: CareReminderStore? = nil) {
        self.store = store
        _currentNote = State(initialValue: note)
        _careReminderStore = State(initialValue: careReminderStore ?? CareReminderStore())
    }

    var body: some View {
        List {
            headerSection
            if !currentNote.summary.isEmpty {
                summarySection
            }
            if !currentNote.topics.isEmpty {
                topicsSection
            }
            if !currentNote.decisions.isEmpty {
                decisionsSection
            }
            if !currentNote.actionItems.isEmpty {
                actionItemsSection
            }
            rawTranscriptSection
            deleteSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("纪要详情")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 头部

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text(currentNote.title)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Label(
                        currentNote.organizationLabel,
                        systemImage: currentNote.organizedByAI ? "sparkles" : "exclamationmark.triangle"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(currentNote.organizedByAI ? .indigo : .orange)

                    Spacer()

                    Text(Self.dateTimeText(currentNote.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !currentNote.participants.isEmpty {
                    Text("参与者：" + currentNote.participants.joined(separator: "、"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var summarySection: some View {
        Section {
            Text(currentNote.summary)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("摘要")
        }
    }

    private var topicsSection: some View {
        Section {
            ForEach(Array(currentNote.topics.enumerated()), id: \.offset) { index, topic in
                Text("\(index + 1). \(topic)")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("议题")
        }
    }

    private var decisionsSection: some View {
        Section {
            ForEach(Array(currentNote.decisions.enumerated()), id: \.offset) { index, decision in
                Text("\(index + 1). \(decision)")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("决定")
        }
    }

    // MARK: - 待办（一键加入提醒，失败不阻塞）

    private var actionItemsSection: some View {
        Section {
            ForEach(Array(currentNote.actionItems.enumerated()), id: \.element.id) { index, item in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(index + 1). \(item.text)")
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        if let assignee = item.assignee, !assignee.isEmpty {
                            Text("负责人：\(assignee)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let dueDate = item.dueDate {
                            Text("截止：\(Self.dateText(dueDate))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if currentNote.hasLinkedReminder(for: item.id) {
                            Label("已加入提醒", systemImage: "bell.fill")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.green)
                        } else {
                            Button {
                                addReminder(for: item)
                            } label: {
                                Label("加入提醒", systemImage: "bell.badge.plus")
                                    .font(.caption.weight(.medium))
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            if let reminderNotice {
                Label(reminderNotice, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("待办")
        }
    }

    /// 待办 → CareReminderStore.add（一次性提醒）：有截止日期用截止日期，
    /// 没有就 1 小时后提醒（与语音日记「无时间词 +1 小时」同策略）。
    /// 通知未授权时提醒仍会存入列表，但到点不响铃——诚实提示，不阻塞。
    private func addReminder(for item: ActionItem) {
        guard !currentNote.hasLinkedReminder(for: item.id) else { return }
        let fallbackTime = Date().addingTimeInterval(3600)
        let reminder = CareReminder(
            title: item.text,
            time: item.dueDate ?? fallbackTime,
            category: .custom,
            repeatType: .none,
            enabled: true,
            scheduledDate: item.dueDate ?? fallbackTime,
            createdAt: Date()
        )
        let added = careReminderStore.add(reminder)

        var updated = currentNote
        updated.linkedReminderIDs.append(added.id)
        currentNote = updated
        store.update(updated)

        reminderNotice = "「\(item.text)」已加入提醒"
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                break
            case .denied:
                reminderNotice = "「\(item.text)」已保存为提醒，但通知权限未开启，到点不会响铃。"
            case .notDetermined:
                reminderNotice = "「\(item.text)」已保存为提醒，通知权限尚未开启。"
            @unknown default:
                break
            }
        }
    }

    // MARK: - 原始转写 / 删除

    private var rawTranscriptSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showRawTranscript) {
                Text(currentNote.rawTranscript)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } label: {
                Label("原始转写", systemImage: "text.quote")
            }
        }
    }

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                store.delete(id: currentNote.id)
                dismiss()
            } label: {
                HStack {
                    Spacer()
                    Text("删除这条纪要")
                    Spacer()
                }
            }
        }
    }

    // MARK: - 工具

    private static func dateTimeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }

    private static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }
}
