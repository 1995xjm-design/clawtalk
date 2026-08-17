import SwiftUI
import UIKit

/// Talk 运行期问题横幅（对齐官方 TalkRuntimeIssueBanner）：
/// Realtime 启动失败降级时展示提示，可展开技术细节并复制诊断信息。
struct TalkRuntimeIssueBanner: View {
    let issue: TalkRuntimeIssue
    var onOpenSettings: (() -> Void)?

    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation { showDetails.toggle() }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.fallbackBannerTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(issue.fallbackBannerMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(showDetails ? nil : 2)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: showDetails ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if showDetails {
                VStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: issue.technicalDetails)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 12) {
                        if let onOpenSettings {
                            Button("打开设置", action: onOpenSettings)
                                .font(.caption.weight(.semibold))
                                .buttonStyle(.bordered)
                                .tint(.orange)
                        }
                        Button {
                            UIPasteboard.general.string = issue.technicalDetails
                        } label: {
                            Label("复制诊断", systemImage: "doc.on.doc")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        }
    }
}
