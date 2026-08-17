import SwiftUI

/// 聊天模型切换菜单（对齐官方 ChatModelControlsMenuItems）：
/// 展示当前模型并切换 API 模式（openclaw 网关 / deepseek 直连）。
struct ChatModelControlsMenuItems: View {
    let currentLabel: String
    var onSelect: (String) -> Void

    var body: some View {
        Menu {
            Button {
                onSelect("openclaw:main")
            } label: {
                Label("OpenClaw 网关", systemImage: currentLabel == "openclaw:main" ? "checkmark" : "network")
            }
            Button {
                onSelect("deepseek")
            } label: {
                Label("DeepSeek 直连", systemImage: currentLabel == "deepseek" ? "checkmark" : "bolt")
            }
        } label: {
            HStack(spacing: 4) {
                Text(currentLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
