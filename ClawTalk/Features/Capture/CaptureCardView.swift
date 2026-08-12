import SwiftUI

/// 主页「随手捕捉」卡：图标 + 「说一句，自动归档」摘要，点击进入捕捉页。
///
/// 接线说明（主智能体）：
/// 1. 在 `HomeTabView` 的快捷卡片网格（LazyVGrid）中加一格：
///    `CaptureCardView(settings: settings)`（该卡自带 NavigationLink，依赖副主页已有 NavigationStack）。
/// 2. 工程用 XcodeGen（project.yml sources 已含整个 ClawTalk 目录），新增文件在
///    重新生成工程后自动进 target，无需改 project.yml。
struct CaptureCardView: View {
    private let settings: SettingsStore
    private let careReminderStore: CareReminderStore?
    private let memoryProfileStore: MemoryProfileStore?
    private let expenseStore: ExpenseStore?

    init(
        settings: SettingsStore,
        careReminderStore: CareReminderStore? = nil,
        memoryProfileStore: MemoryProfileStore? = nil,
        expenseStore: ExpenseStore? = nil
    ) {
        self.settings = settings
        self.careReminderStore = careReminderStore
        self.memoryProfileStore = memoryProfileStore
        self.expenseStore = expenseStore
    }

    var body: some View {
        NavigationLink {
            CaptureView(
                settingsStore: settings,
                careReminderStore: careReminderStore,
                memoryProfileStore: memoryProfileStore,
                expenseStore: expenseStore
            )
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Color.teal)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 3) {
                    Text("随手捕捉")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("说一句，自动归档")
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
    }
}
