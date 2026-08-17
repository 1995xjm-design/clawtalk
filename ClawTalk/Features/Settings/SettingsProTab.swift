import SwiftUI

/// 设置 Pro（对齐官方 SettingsProTab 精简）：把 Pro 级设置聚合到一个入口，
/// 包含连接/高级面板/隐私/健康/频道/技能/系统代理聊天等分区。
struct SettingsProTab: View {
    var gatewayConnection: GatewayConnection
    var settingsStore: SettingsStore

    var body: some View {
        List {
            Section("连接") {
                NavigationLink {
                    GatewayConnectionStatusView(store: settingsStore, gatewayConnection: gatewayConnection, nodeConnection: nil)
                } label: {
                    Label("连接状态", systemImage: "antenna.radiowaves.left.and.right")
                }
                NavigationLink {
                    GatewayProfilesView(store: settingsStore, profileStore: GatewayProfileStore())
                } label: {
                    Label("网关管理", systemImage: "server.rack")
                }
                NavigationLink {
                    AgentProPanelView(gatewayConnection: gatewayConnection)
                } label: {
                    Label("网关高级面板", systemImage: "chart.bar.fill")
                }
            }
            Section("Pro 功能") {
                NavigationLink {
                    SettingsChannelsDestination(gatewayConnection: gatewayConnection)
                } label: {
                    Label("频道设置", systemImage: "rectangle.3.group")
                }
                NavigationLink {
                    SettingsSkillsDestination(gatewayConnection: gatewayConnection)
                } label: {
                    Label("技能设置", systemImage: "puzzlepiece.fill")
                }
                NavigationLink {
                    SettingsSystemAgentChatScreen(gatewayConnection: gatewayConnection)
                } label: {
                    Label("系统代理聊天", systemImage: "person.crop.circle.badge.checkmark")
                }
                NavigationLink {
                    PrivacyAccessSectionView()
                } label: {
                    Label("隐私访问", systemImage: "hand.raised.fill")
                }
                NavigationLink {
                    AppleHealthAccessSectionView()
                } label: {
                    Label("健康访问", systemImage: "heart.fill")
                }
            }
            Section("关于") {
                NavigationLink {
                    DocsLicenseView()
                } label: {
                    Label("文档与许可", systemImage: "book.closed")
                }
            }
        }
        .navigationTitle("设置 Pro")
        .navigationBarTitleDisplayMode(.inline)
    }
}
