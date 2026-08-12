import SwiftUI

/// agent 当前状态（驻守中 / 思考中 / 回复中 / 空闲）
enum AgentDisplayStatus: Equatable {
    case offline   // 空闲（未连接网关）
    case onDuty    // 驻守中
    case thinking  // 思考中
    case replying  // 回复中

    var label: String {
        switch self {
        case .offline: "空闲"
        case .onDuty: "驻守中"
        case .thinking: "思考中"
        case .replying: "回复中"
        }
    }

    var color: Color {
        switch self {
        case .offline: .gray
        case .onDuty: .green
        case .thinking: .yellow
        case .replying: .orange
        }
    }

    var icon: String {
        switch self {
        case .offline: "zzz"
        case .onDuty: "antenna.radiowaves.left.and.right"
        case .thinking: "brain"
        case .replying: "bubble.left.and.bubble.right.fill"
        }
    }
}

/// 全局 agent 状态常驻指示条：
/// 优先订阅网关推送的 agentStatus（GatewayConnection.agentStatus），
/// 网关没推 agent 事件时，用 session_status 状态文本每 5 秒轮询兜底推断。
struct AgentStatusIndicator: View {
    let gatewayConnection: GatewayConnection
    let settings: SettingsStore

    private let client = OpenClawClient()
    @State private var fallbackText: String?

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(displayStatus.color)
                .frame(width: 8, height: 8)

            Image(systemName: displayStatus.icon)
                .font(.caption2)
                .foregroundStyle(displayStatus.color)

            Text("Agent · \(displayStatus.label)")
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            if isBusy {
                ProgressView()
                    .controlSize(.mini)
            }

            Spacer()

            if gatewayConnection.connectionState == .disconnected {
                Text("未连接")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.systemGray6).opacity(0.8))
        )
        .task { await pollLoop() }
    }

    private var isBusy: Bool {
        displayStatus == .thinking || displayStatus == .replying
    }

    /// 优先用网关推送的 agentStatus；未推送时用 session_status 文本兜底推断
    private var displayStatus: AgentDisplayStatus {
        if gatewayConnection.connectionState != .connected {
            return .offline
        }
        if let raw = gatewayConnection.agentStatus?.status?.lowercased() {
            if ["think"].contains(where: { raw.contains($0) }) { return .thinking }
            if ["reply", "stream", "work", "busy", "run", "speak"].contains(where: { raw.contains($0) }) {
                return .replying
            }
            if ["idle", "standby", "wait", "ready"].contains(where: { raw.contains($0) }) {
                return .onDuty
            }
        }
        // 兜底：网关没推 agent 事件时，用 session_status 状态文本推断
        if let text = fallbackText?.lowercased() {
            if text.contains("思考") || text.contains("think") { return .thinking }
            if text.contains("回复") || text.contains("reply")
                || text.contains("工作") || text.contains("work")
                || text.contains("忙碌") || text.contains("busy") {
                return .replying
            }
        }
        return .onDuty
    }

    @MainActor
    private func pollLoop() async {
        while !Task.isCancelled {
            await updateFallbackStatus()
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    /// 网关已推送 agent 状态时不再轮询；未推送且已连接时才轮询 session_status
    @MainActor
    private func updateFallbackStatus() async {
        guard settings.isConfigured,
              gatewayConnection.connectionState == .connected,
              gatewayConnection.agentStatus == nil
        else {
            fallbackText = nil
            return
        }
        do {
            let token = OpenClawClient.resolveHTTPToken(
                settingsToken: settings.gatewayToken,
                gatewayURL: settings.settings.gatewayURL
            )
            let data = try await client.invokeTool(
                tool: "session_status",
                gatewayURL: settings.settings.gatewayURL,
                token: token
            )
            let wrapper = try JSONDecoder().decode(ToolResultWrapper<SessionStatusResult.StatusDetails>.self, from: data)
            fallbackText = wrapper.details?.statusText ?? wrapper.content?.first?.text
        } catch {
            fallbackText = nil
        }
    }
}
