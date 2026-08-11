import ActivityKit
import SwiftUI
import WidgetKit

/// ClawTalk 品牌红（与主 App Theme.openClawRed 一致）。
private let clawTalkRed = Color(red: 0.85, green: 0.18, blue: 0.15)

struct ClawTalkLiveActivityWidget: Widget {
    let kind: String = "ClawTalkLiveActivity"

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ClawTalkLiveActivityAttributes.self) { context in
            LiveActivityLockScreenView(
                channelName: context.attributes.channelName,
                statusText: context.state.statusText
            )
            .activityBackgroundTint(clawTalkRed.opacity(0.18))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.attributes.channelName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.title3)
                        .foregroundStyle(clawTalkRed)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.statusText)
                        .font(.headline)
                        .lineLimit(2)
                }
            } compactLeading: {
                CompactLeadingView(statusText: context.state.statusText)
            } compactTrailing: {
                Image(systemName: "waveform")
                    .font(.caption2)
                    .foregroundStyle(clawTalkRed)
            } minimal: {
                Image(systemName: "waveform")
                    .foregroundStyle(clawTalkRed)
            }
        }
    }
}

/// 锁屏 / 横幅视图：状态文案 + 频道名（小字）。
private struct LiveActivityLockScreenView: View {
    let channelName: String
    let statusText: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.circle.fill")
                .font(.title2)
                .foregroundStyle(clawTalkRed)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusText)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(channelName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// 灵动岛 compact 左侧：取状态文案前 2-4 个字，空文案时退化为图标。
private struct CompactLeadingView: View {
    let statusText: String

    var body: some View {
        if let short = shortStatusText {
            Text(short)
                .font(.caption2)
                .foregroundStyle(clawTalkRed)
                .lineLimit(1)
        } else {
            Image(systemName: "waveform")
                .foregroundStyle(clawTalkRed)
        }
    }

    private var shortStatusText: String? {
        let trimmed = statusText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(min(4, trimmed.count)))
    }
}