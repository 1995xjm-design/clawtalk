import SwiftUI

/// 主页「文件保险箱」卡：到期未检查数角标 + 诚实摘要，点击进入重要文件列表。
///
/// 主智能体接线：在 HomeTabView 的快捷入口 LazyVGrid 里加一行
///   FileVaultCardView()
/// （与 ReminderCardView() 等卡片并列；自带 NavigationLink → 列表页）。
struct FileVaultCardView: View {
    @State private var store: FileVaultStore

    init(store: FileVaultStore) {
        _store = State(initialValue: store)
    }

    var body: some View {
        NavigationLink {
            FileVaultView(store: store)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Color.indigo)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Spacer(minLength: 0)

                    // 到期未检查数角标：0 不显示（摘要里有诚实文案）
                    if store.dueCount > 0 {
                        Text("\(store.dueCount) 待检查")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.orange, in: Capsule())
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 3) {
                    Text("文件保险箱")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    FileVaultCardSummary(store: store)
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
            _ = store.checkDue()
        }
    }
}

/// 文件保险箱卡摘要（诚实空态，不造假）。
struct FileVaultCardSummary: View {
    let store: FileVaultStore

    var body: some View {
        Text(summaryText)
    }

    private var summaryText: String {
        if store.files.isEmpty {
            return "暂无重要文件，点这里登记防丢"
        }
        if store.dueCount > 0 {
            return "有 \(store.dueCount) 个文件到期未检查"
        }
        return "已登记 \(store.files.count) 个重要文件，定期提醒检查"
    }
}