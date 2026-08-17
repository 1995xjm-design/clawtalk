import SwiftUI

/// 连接问题横幅（对齐官方 GatewayProblemView 精简版）：
/// 按问题类型三色样式 + 详情展开（复制 Request ID / 复制修复命令）。
struct GatewayProblemBanner: View {
    let issue: GatewayConnectionIssue
    @State private var showDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation { showDetail.toggle() }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: issue.kind.symbol)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(bannerColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(issue.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(showDetail ? nil : 2)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: showDetail ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if showDetail {
                VStack(alignment: .leading, spacing: 10) {
                    if let command = issue.repairCommand, !command.isEmpty {
                        HStack(spacing: 8) {
                            Text(command)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                UIPasteboard.general.string = command
                            } label: {
                                Label("复制命令", systemImage: "doc.on.doc")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .tint(bannerColor)
                        }
                        .padding(10)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    if let requestID = issue.requestID, !requestID.isEmpty {
                        HStack(spacing: 8) {
                            Text("Request ID: \(requestID)")
                                .font(.caption.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                UIPasteboard.general.string = requestID
                            } label: {
                                Label("复制 ID", systemImage: "doc.on.doc")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .tint(bannerColor)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(bannerColor.opacity(0.10))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(bannerColor.opacity(0.35), lineWidth: 1)
        }
    }

    private var bannerColor: Color {
        switch issue.kind {
        case .pairing, .network: return .orange
        case .identity: return .red
        case .unknown: return .secondary
        }
    }
}