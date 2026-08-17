import SwiftUI
import UIKit

/// 网关连接状态页（任务 F）：当前网关地址/接口方式/令牌状态 + 网关（operator）与节点（node）连接状态 + 重连按钮。
/// nodeConnection 由主智能体接线传入；未接线时显示占位说明。
struct GatewayConnectionStatusView: View {
    @Bindable var store: SettingsStore
    var gatewayConnection: GatewayConnection
    var nodeConnection: NodeConnection?

    @State private var isReconnecting = false
    @State private var generatedSetupCode: String?
    @State private var isGeneratingSetupCode = false
    @State private var setupCodeError: String?

    var body: some View {
        List {
            Section("当前网关") {
                LabeledContent("网关地址", value: store.settings.gatewayURL.isEmpty ? "未配置" : store.settings.gatewayURL)
                if store.settings.useWebSocket {
                    LabeledContent("WebSocket 地址", value: store.settings.resolvedWebSocketURL.isEmpty ? "未配置" : store.settings.resolvedWebSocketURL)
                }
                LabeledContent("接口方式", value: store.settings.agentAPIMode.rawValue)
                LabeledContent("令牌", value: store.gatewayToken.isEmpty ? "未设置" : "已设置（••••）")
            }

            Section("网关（operator）连接") {
                statusRow(state: gatewayConnection.connectionState)
                if gatewayConnection.connectionState == .disconnected, let error = gatewayConnection.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("节点（node）连接") {
                if let nodeConnection {
                    statusRow(state: nodeConnection.connectionState)
                    if nodeConnection.connectionState == .disconnected, let error = nodeConnection.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } else {
                    Text("节点连接未接入本页面（由主智能体接线传入 nodeConnection 后显示）。")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if let code = generatedSetupCode {
                    LabeledContent("配对码", value: code)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = code
                    } label: {
                        Label("复制配对码", systemImage: "doc.on.doc")
                    }
                }
                if let setupCodeError {
                    Text(setupCodeError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Button {
                    generateSetupCode()
                } label: {
                    if isGeneratingSetupCode {
                        HStack {
                            ProgressView().scaleEffect(0.8)
                            Text("生成中...")
                        }
                    } else {
                        Label("生成配对码（手机端）", systemImage: "qrcode")
                    }
                }
                .disabled(gatewayConnection.connectionState != .connected || isGeneratingSetupCode)
            } header: {
                Text("配对工具")
            } footer: {
                Text("网关 operator 已连接时，由手机端生成 node 配对码（官方 device.pair.setupCode），可发给电脑/手表侧节点使用。")
            }

            Section {
                Button {
                    reconnect()
                } label: {
                    if isReconnecting {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("重连中...")
                        }
                    } else {
                        Label("重新连接", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(!store.isConfigured || isReconnecting)
            } footer: {
                Text("重连会同时重连网关（operator）与节点（node）WebSocket；需要先开启 WebSocket 模式并完成配置。")
            }
        }
        .navigationTitle("连接状态")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func statusRow(state: GatewayConnection.State) -> some View {
        switch state {
        case .connected:
            statusRow(label: "状态", text: "已连接", color: .green, busy: false)
        case .connecting:
            statusRow(label: "状态", text: "连接中...", color: .secondary, busy: true)
        case .disconnected:
            statusRow(label: "状态", text: "未连接", color: .red, busy: false)
        }
    }

    @ViewBuilder
    private func statusRow(state: NodeConnection.State) -> some View {
        switch state {
        case .connected:
            statusRow(label: "状态", text: "已连接", color: .green, busy: false)
        case .connecting:
            statusRow(label: "状态", text: "连接中...", color: .secondary, busy: true)
        case .disconnected:
            statusRow(label: "状态", text: "未连接", color: .red, busy: false)
        }
    }

    @ViewBuilder
    private func statusRow(label: String, text: String, color: Color, busy: Bool) -> some View {
        HStack {
            Text(label)
            Spacer()
            HStack(spacing: 6) {
                if busy {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                }
                Text(text)
                    .foregroundStyle(color)
            }
        }
    }

    private func generateSetupCode() {
        isGeneratingSetupCode = true
        setupCodeError = nil
        generatedSetupCode = nil
        Task {
            do {
                let code = try await gatewayConnection.generateNodeSetupCode()
                generatedSetupCode = code
            } catch {
                setupCodeError = error.localizedDescription
            }
            isGeneratingSetupCode = false
        }
    }

    private func reconnect() {
        guard store.isConfigured else { return }
        isReconnecting = true
        Task {
            await gatewayConnection.connect(
                resolvedURL: store.settings.resolvedWebSocketURL,
                token: store.gatewayToken
            )
            if let nodeConnection {
                await nodeConnection.connect(
                    resolvedURL: store.settings.resolvedWebSocketURL,
                    token: store.gatewayToken
                )
            }
            isReconnecting = false
        }
    }
}