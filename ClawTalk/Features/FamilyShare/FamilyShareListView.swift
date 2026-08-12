import SwiftUI

/// 家庭共享提醒列表：
/// - 家人发来的提醒：状态徽章 + 确认/完成按钮（状态流转本地先行，回写网关待确认）
/// - 我共享的提醒：状态徽章 + 「未同步」标记 + 重试按钮
/// - 共享本机提醒：读 CareReminderStore 现有提醒，一键转成 FamilyReminder 发给家人
/// 诚实空状态：没有收到/没有共享时如实显示，不造假。
struct FamilyShareListView: View {
    @State private var familyStore: FamilyShareStore
    @State private var careStore: CareReminderStore

    @State private var showShareAlert = false
    @State private var sharingReminder: CareReminder?
    @State private var assigneeDraft = "家人"

    init(
        settings: SettingsStore? = nil,
        familyStore: FamilyShareStore? = nil,
        careStore: CareReminderStore? = nil
    ) {
        _familyStore = State(initialValue: familyStore ?? FamilyShareStore(settings: settings))
        _careStore = State(initialValue: careStore ?? CareReminderStore())
    }

    var body: some View {
        List {
            receivedSection
            sentSection
            localRemindersSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("家庭共享")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    familyStore.readInbox()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .onAppear {
            familyStore.readInbox()
        }
        .alert("共享给家人", isPresented: $showShareAlert) {
            TextField("家人称呼（如：妈妈）", text: $assigneeDraft)
            Button("共享") {
                if let sharingReminder {
                    familyStore.share(careReminder: sharingReminder, assignee: assigneeDraft)
                }
                self.sharingReminder = nil
            }
            Button("取消", role: .cancel) {
                sharingReminder = nil
            }
        } message: {
            if let sharingReminder {
                Text("「\(sharingReminder.title)」\n时间：\(careTimeLabel(sharingReminder))")
            }
        }
    }

    // MARK: - 家人发来的

    private var receivedSection: some View {
        Section {
            if familyStore.receivedReminders.isEmpty {
                Text("还没有收到家人提醒。点右上角刷新检查收件箱。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(familyStore.receivedReminders) { reminder in
                    familyRow(reminder)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                familyStore.delete(id: reminder.id)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
            }
        } header: {
            Text("家人发来的")
        } footer: {
            if !familyStore.receivedReminders.isEmpty {
                Text("确认或完成后，状态回写家人端（回写端点待网关侧确认）。")
            }
        }
    }

    // MARK: - 我共享的

    private var sentSection: some View {
        Section {
            if familyStore.sentReminders.isEmpty {
                Text("还没有共享过提醒。下方可把本机提醒一键共享给家人。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(familyStore.sentReminders) { reminder in
                    familyRow(reminder)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                familyStore.delete(id: reminder.id)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
            }
        } header: {
            Text("我共享的")
        }
    }

    // MARK: - 共享本机提醒

    private var localRemindersSection: some View {
        Section {
            if careStore.reminders.isEmpty {
                Text("本机还没有提醒。先去「提醒」里创建，再回来共享给家人。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(careStore.reminders) { reminder in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(reminder.title)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                            Text("\(reminder.category.rawValue) · \(careTimeLabel(reminder))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button {
                            assigneeDraft = "家人"
                            sharingReminder = reminder
                            showShareAlert = true
                        } label: {
                            Label("共享", systemImage: "person.2")
                                .font(.caption2)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("共享本机提醒")
        } footer: {
            Text("共享后家人能看到这条提醒并确认。网关未连接时本地先记录为「未同步」，不会丢失。")
        }
    }

    // MARK: - 行

    private func familyRow(_ reminder: FamilyReminder) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(familyTimeLabel(reminder))
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    FamilyStatusBadge(status: reminder.status)
                }
                Text(reminder.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                HStack(spacing: 4) {
                    Text("负责人：\(reminder.assignee)")
                    if reminder.direction == .sent && !reminder.synced {
                        Text("· 未同步")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            trailingActions(for: reminder)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func trailingActions(for reminder: FamilyReminder) -> some View {
        if reminder.direction == .received {
            switch reminder.status {
            case .pending:
                HStack(spacing: 6) {
                    Button("确认") {
                        familyStore.confirm(id: reminder.id)
                    }
                    .buttonStyle(.bordered)
                    Button("完成") {
                        familyStore.complete(id: reminder.id)
                    }
                    .buttonStyle(.bordered)
                }
                .font(.caption2)
            case .confirmed:
                Button("标记完成") {
                    familyStore.complete(id: reminder.id)
                }
                .buttonStyle(.bordered)
                .font(.caption2)
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        } else if !reminder.synced {
            Button("重试") {
                familyStore.retrySync(id: reminder.id)
            }
            .buttonStyle(.bordered)
            .font(.caption2)
        }
    }

    // MARK: - 时间文案

    private func familyTimeLabel(_ reminder: FamilyReminder) -> String {
        dateLabel(reminder.time)
    }

    private func careTimeLabel(_ reminder: CareReminder) -> String {
        reminder.scheduledDate.map(dateLabel) ?? timeText(reminder.time)
    }

    private func dateLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "今天 \(timeText(date))"
        }
        if calendar.isDateInTomorrow(date) {
            return "明天 \(timeText(date))"
        }
        let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        return "\(weekdays[calendar.component(.weekday, from: date) - 1]) \(timeText(date))"
    }

    private func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

/// 状态徽章：待确认(橙) / 已确认(蓝) / 已完成(绿)。
struct FamilyStatusBadge: View {
    let status: FamilyReminderStatus

    var body: some View {
        Text(status.displayName)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(badgeColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(badgeColor.opacity(0.14), in: Capsule())
    }

    private var badgeColor: Color {
        switch status {
        case .pending: return .orange
        case .confirmed: return .blue
        case .completed: return .green
        }
    }
}
