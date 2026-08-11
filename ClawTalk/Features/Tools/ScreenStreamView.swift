import SwiftUI
import UIKit

/// 远程屏幕（任务：远程屏幕流式）：周期拉取截图帧。
/// - 远程桌面：经网关 agent 会话让电脑端截屏并回传 base64（每 4 秒一帧）；
///   网关未提供连续屏幕流，本页为「轮询帧」模式，连续失败时诚实降级为「手动单帧」。
/// - 本机屏幕：调用 ScreenCapability 直接截取本机屏幕。
/// 入口：已加在设置页「系统集成」分组；也可由主智能体在工具页/ToolsView 增加入口。
struct ScreenStreamView: View {
    @Bindable var store: SettingsStore

    enum StreamSource: String, CaseIterable, Identifiable {
        case remote = "远程桌面"
        case local = "本机屏幕"
        var id: String { rawValue }
    }

    enum StreamMode: Equatable {
        case idle
        case auto
        case manual
    }

    @State private var source: StreamSource = .remote
    @State private var mode: StreamMode = .idle
    @State private var frame: UIImage?
    @State private var lastUpdated: Date?
    @State private var isFetching = false
    @State private var errorMessage: String?

    private let pollInterval: Duration = .seconds(4)
    private let sessionKey = "agent:main:clawtalk-user:screen-stream"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            Text(transportNote)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .navigationTitle("远程屏幕")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: mode) {
            guard mode == .auto else { return }
            while !Task.isCancelled {
                await fetchFrame()
                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    // MARK: - 头部：来源 / 状态 / 更新时间 / 刷新

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("截图来源", selection: $source) {
                ForEach(StreamSource.allCases) { source in
                    Text(source.rawValue).tag(source)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await fetchFrame() }
                } label: {
                    if isFetching {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isFetching)
            }

            if let lastUpdated {
                Text("最近更新 \(lastUpdated.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
    }

    private var statusColor: Color {
        switch mode {
        case .idle: return .secondary
        case .auto: return .green
        case .manual: return .orange
        }
    }

    private var statusText: String {
        switch mode {
        case .idle: return "就绪：点击刷新获取第一帧"
        case .auto: return "自动轮询：每 4 秒拉取一帧"
        case .manual: return "手动模式：网关不支持连续截屏，仅单帧获取"
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if let frame {
            ScrollView([.vertical, .horizontal]) {
                Image(uiImage: frame)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
            }
        } else {
            ContentUnavailableView(
                "远程屏幕",
                systemImage: "display",
                description: Text(emptyDescription)
            )
        }
    }

    private var emptyDescription: String {
        switch source {
        case .remote: return "点击「刷新」经网关拉取远程桌面截图。"
        case .local: return "点击「刷新」截取本机屏幕。"
        }
    }

    /// 接入方式说明（诚实标注：无连续流，轮询帧；失败降级手动单帧）。
    private var transportNote: String {
        switch source {
        case .remote:
            return "接入方式：网关未提供连续屏幕流，本页通过网关 agent 会话每 4 秒轮询拉取一帧；连续失败自动降级为手动刷新单帧。"
        case .local:
            return "接入方式：本机屏幕使用系统截图能力（ScreenCapability），每 4 秒刷新一帧。"
        }
    }

    // MARK: - 拉帧

    private func fetchFrame() async {
        guard !isFetching else { return }
        guard store.isConfigured || source == .local else {
            errorMessage = "尚未配置网关，请先在设置中填写网关地址与令牌。"
            mode = .manual
            return
        }

        isFetching = true
        defer { isFetching = false }

        do {
            let image: UIImage
            switch source {
            case .local:
                let snapshot = try await ScreenCapability.snapshot(maxWidth: 1024, quality: 0.7)
                guard let data = Data(base64Encoded: snapshot.imageBase64),
                      let decoded = UIImage(data: data) else {
                    throw ScreenStreamError.decodeFailed
                }
                image = decoded
                mode = .auto
            case .remote:
                image = try await fetchRemoteFrame()
                if mode == .idle {
                    mode = .auto
                }
            }
            frame = image
            lastUpdated = Date()
            errorMessage = nil
        } catch {
            let message = "获取截图失败：\(AppErrorText.localized(error.localizedDescription))"
            if mode == .auto && source == .remote {
                // 连续获取不可用：诚实降级为手动单帧
                mode = .manual
                errorMessage = "网关连续截屏不可用，已切换为手动刷新模式。\(message)"
            } else {
                errorMessage = message
            }
            LogCollector.record(module: "远程屏幕", message)
        }
    }

    /// 经网关 agent 会话让电脑端截屏并回传 base64（与工具页桌面截图同一思路）。
    private func fetchRemoteFrame() async throws -> UIImage {
        let baseURL = store.settings.gatewayURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let instruction = "请截取电脑当前屏幕：用 PowerShell（Add-Type -AssemblyName System.Windows.Forms,System.Drawing；Graphics.CopyFromScreen 截取全屏；保存为 JPEG，宽约 1280，质量约 60%）；转成 base64；只回复完整 base64 字符串，不要解释、不要省略、不要加任何前缀。"
        let reply = try await OpenClawClient().chat(
            messages: [Message(role: .user, content: instruction)],
            gatewayURL: baseURL,
            token: store.gatewayToken,
            sessionKey: sessionKey
        )
        guard let base64 = Self.extractBase64(from: reply),
              let data = Data(base64Encoded: base64),
              let image = UIImage(data: data) else {
            throw ScreenStreamError.noImageInReply
        }
        return image
    }

    private static func extractBase64(from text: String) -> String? {
        let pattern = #"[A-Za-z0-9+/=]{1000,}"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[range])
    }

    private enum ScreenStreamError: LocalizedError {
        case noImageInReply
        case decodeFailed

        var errorDescription: String? {
            switch self {
            case .noImageInReply: return "未从网关回复中解析到截图数据"
            case .decodeFailed: return "截图数据解码失败"
            }
        }
    }
}