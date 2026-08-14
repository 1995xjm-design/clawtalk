import SwiftUI

/// 主页卡片管理（主页「常用卡片」标题行「管理」按钮弹出；工具页「主页卡片管理」入口共用）：
/// 列出全部可配置卡，点按在主页显示 / 移除；支持一键恢复默认、清空。
/// 读写同一 UserDefaults key（HomeCardRegistry），主页 @AppStorage 自动同步，本页变更即时生效。
struct HomeCardManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(HomeCardRegistry.storageKey) private var storage = HomeCardRegistry.defaultStorageValue

    /// 当前启用的卡片（顺序即主页排布顺序）。
    private var enabled: [HomeCardKind] {
        HomeCardRegistry.enabledKinds(from: storage)
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
                    Text("已显示 \(enabled.count) / \(HomeCardKind.allCases.count) 张。点按在主页显示 / 移除，移除后仍可从本页加回，功能不丢失。")
                }

                Section {
                    Button("恢复默认卡片") {
                        storage = HomeCardRegistry.defaultStorageValue
                    }
                    Button("清空主页卡片", role: .destructive) {
                        storage = ""
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
        var list = enabled
        if let index = list.firstIndex(of: kind) {
            list.remove(at: index)
        } else {
            list.append(kind)
        }
        storage = HomeCardRegistry.storageValue(for: list)
    }
}
