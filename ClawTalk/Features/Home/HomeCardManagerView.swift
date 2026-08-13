import SwiftUI

/// 主页卡片管理（主页「常用卡片」标题行「管理」按钮弹出）：
/// 列出全部可配置卡，点按在主页显示 / 移除；支持一键恢复默认、清空。
/// 读写同一 UserDefaults key（HomeCardRegistry），主页 @AppStorage 自动同步。
struct HomeCardManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var enabled: [HomeCardKind]

    init() {
        let storage = UserDefaults.standard.string(forKey: HomeCardRegistry.storageKey)
            ?? HomeCardRegistry.defaultStorageValue
        _enabled = State(initialValue: HomeCardRegistry.enabledKinds(from: storage))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(HomeCardKind.allCases) { kind in
                        Button {
                            toggle(kind)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: kind.icon)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 32, height: 32)
                                    .background(
                                        kind.tint,
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(kind.title)
                                        .foregroundStyle(.primary)
                                    Text(kind.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: enabled.contains(kind) ? "checkmark.circle.fill" : "plus.circle")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(enabled.contains(kind) ? .green : .orange)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("主页卡片")
                } footer: {
                    Text("点按在主页显示 / 移除。移除后仍可从本页加回，功能不丢失。")
                }

                Section {
                    Button("恢复默认卡片") {
                        enabled = HomeCardKind.allCases
                        apply()
                    }
                    Button("清空主页卡片", role: .destructive) {
                        enabled = []
                        apply()
                    }
                }
            }
            .navigationTitle("管理卡片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func toggle(_ kind: HomeCardKind) {
        if let index = enabled.firstIndex(of: kind) {
            enabled.remove(at: index)
        } else {
            enabled.append(kind)
        }
        apply()
    }

    private func apply() {
        HomeCardRegistry.setEnabledKinds(enabled)
    }
}
