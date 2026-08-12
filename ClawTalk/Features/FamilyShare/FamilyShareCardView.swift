import SwiftUI

/// 副主页「家庭共享」卡片：待确认数角标 + 摘要，点击进入家庭共享列表。
///
/// 主智能体接线：在 HomeTabView 的 LazyVGrid 里与 ReminderCardView() 并排加一行：
///     FamilyShareCardView(settings: settings)
/// settings 传入后网关共享才会生效；不传则网关静默跳过，本地记录「未同步」。
struct FamilyShareCardView: View {
    @State private var familyStore: FamilyShareStore
    @State private var careStore: CareReminderStore

    init(settings: SettingsStore? = nil, familyStore: FamilyShareStore? = nil) {
        _familyStore = State(initialValue: familyStore ?? FamilyShareStore(settings: settings))
        _careStore = State(initialValue: CareReminderStore())
    }

    var body: some View {
        NavigationLink {
            FamilyShareListView(familyStore: familyStore, careStore: careStore)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Color.teal)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Spacer(minLength: 0)

                    // 待确认角标：0 条不显示（摘要里有诚实文案）
                    if familyStore.pendingCount > 0 {
                        Text("待确认 \(familyStore.pendingCount)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.teal, in: Capsule())
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 3) {
                    Text("家庭共享")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    FamilyShareCardSummary(store: familyStore)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 128, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
        .buttonStyle(.plain)
        .onAppear {
            familyStore.readInbox()
        }
        .contextMenu {
            NavigationLink {
                FamilyShareListView(familyStore: familyStore, careStore: careStore)
            } label: {
                Label("查看全部", systemImage: "list.bullet")
            }
        }
    }
}

/// 家庭共享卡摘要：待确认/收到/未同步数量 + 诚实空态。
struct FamilyShareCardSummary: View {
    let store: FamilyShareStore

    var body: some View {
        Text(summaryText)
    }

    private var summaryText: String {
        if store.reminders.isEmpty {
            return "暂无共享提醒，点这里把提醒发给家人"
        }
        let parts: [String] = [
            store.pendingCount > 0 ? "待确认 \(store.pendingCount)" : nil,
            store.receivedReminders.isEmpty ? nil : "收到 \(store.receivedReminders.count)",
            store.sentReminders.contains { !$0.synced } ? "有未同步" : nil
        ].compactMap { $0 }
        return parts.isEmpty ? "共 \(store.reminders.count) 条共享提醒" : parts.joined(separator: " · ")
    }
}
