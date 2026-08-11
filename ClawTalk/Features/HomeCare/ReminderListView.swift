import SwiftUI

/// 提醒列表页：按时间排序，每条显示时间 / 标题 / 类别徽章 / 启用开关。
/// 右上角「+」快捷添加（标题 + 时间 + 类别 + 重复方式），存入 CareReminderStore 并安排本地通知。
/// 空列表显示诚实空状态；通知权限被拒时列表底部提示（不重复弹授权）。
struct ReminderListView: View {
    @State private var store: CareReminderStore
    @State private var showAdd = false
    @State private var draftTitle = ""
    @State private var draftTime = Date()
    @State private var draftCategory: CareReminderCategory = .sedentary
    @State private var draftRepeat: CareReminderRepeat = .daily

    init(store: CareReminderStore? = nil) {
        _store = State(initialValue: store ?? CareReminderStore())
    }

    var body: some View {
        List {
            if store.reminders.isEmpty {
                ContentUnavailableView {
                    Label("暂无提醒", systemImage: "bell.badge")
                } description: {
                    Text("点右上角「+」添加久坐、喝水或用药提醒，到点手机会响铃。\n提醒只保存在本机，不会上传。")
                } actions: {
                    Button("添加提醒") {
                        showAdd = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            ForEach(store.reminders) { reminder in
                reminderRow(reminder)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            store.delete(id: reminder.id)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("提醒")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAdd = true
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(Color.openClawRed)
                }
            }
        }
        .alert("新建提醒", isPresented: $showAdd) {
            TextField("提醒内容", text: $draftTitle)
            DatePicker("时间", selection: $draftTime, displayedComponents: .hourAndMinute)
            Picker("类别", selection: $draftCategory) {
                ForEach(CareReminderCategory.allCases) { category in
                    Text(category.rawValue).tag(category)
                }
            }
            Picker("重复", selection: $draftRepeat) {
                ForEach(CareReminderRepeat.allCases) { repeatType in
                    Text(repeatType.displayName).tag(repeatType)
                }
            }
            Button("保存") {
                saveDraft()
            }
            .disabled(draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("取消", role: .cancel) {}
        } message: {
            Text("到点通过本地通知响铃提醒")
        }
        .safeAreaInset(edge: .bottom) {
            if store.notificationPermissionDenied {
                Text("通知权限被关闭，提醒不会响铃。请在系统设置里允许通知。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
                    .background(.bar)
            }
        }
    }

    // MARK: - 行

    private func reminderRow(_ reminder: CareReminder) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(timeText(reminder.time))
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    CareReminderBadge(category: reminder.category)
                }
                Text(reminder.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(reminder.repeatType.displayName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: enabledBinding(for: reminder))
                .labelsHidden()
                .tint(.openClawRed)
        }
        .padding(.vertical, 4)
    }

    private func enabledBinding(for reminder: CareReminder) -> Binding<Bool> {
        Binding(
            get: { reminder.enabled },
            set: { store.setEnabled($0, for: reminder.id) }
        )
    }

    // MARK: - 快捷添加

    private func saveDraft() {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        store.add(
            CareReminder(
                title: title,
                time: draftTime,
                category: draftCategory,
                repeatType: draftRepeat
            )
        )
        draftTitle = ""
        draftTime = Date()
        draftCategory = .sedentary
        draftRepeat = .daily
        showAdd = false
    }

    private func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - 类别徽章

/// 提醒类别徽章：类别名 + 图标 + 主题色胶囊背景。
struct CareReminderBadge: View {
    let category: CareReminderCategory

    var body: some View {
        Label(category.rawValue, systemImage: category.iconName)
            .font(.caption2.weight(.medium))
            .foregroundStyle(category.themeColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(category.themeColor.opacity(0.14), in: Capsule())
    }
}

extension CareReminderCategory {
    /// 类别图标（SF Symbols）
    var iconName: String {
        switch self {
        case .sedentary: return "figure.seated.side"
        case .water: return "drop.fill"
        case .medication: return "pills.fill"
        case .custom: return "bell.fill"
        }
    }

    /// 类别主题色（浅色/深色下均有对比度）
    var themeColor: Color {
        switch self {
        case .sedentary: return .orange
        case .water: return .blue
        case .medication: return .red
        case .custom: return .purple
        }
    }
}
