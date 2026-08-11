import SwiftUI
import WidgetKit

private let clawTalkRed = Color(red: 0.85, green: 0.18, blue: 0.15)

struct ClawTalkHomeScreenView: View {
    let entry: ClawTalkWidgetEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "waveform.circle.fill")
                    .font(.headline)
                    .foregroundStyle(clawTalkRed)
                Text(displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 2)
            statusRow
            sessionRow
            reminderRow
            if family == .systemMedium {
                Spacer(minLength: 0)
                Text("每 15 分钟自动刷新")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .containerBackground(for: .widget) {
            Color(uiColor: .systemBackground)
        }
        .widgetURL(WidgetAppGroup.widgetURL(for: entry))
    }

    private var displayTitle: String {
        entry.channelName.isEmpty ? "ClawTalk" : entry.channelName
    }

    private var statusText: String {
        entry.gatewayStatus.isEmpty ? "未连接" : entry.gatewayStatus
    }

    private var sessionText: String {
        entry.recentSession.isEmpty ? "暂无会话，打开 ClawTalk 同步" : entry.recentSession
    }

    private var reminderText: String {
        entry.nextReminder.isEmpty ? "暂无提醒" : entry.nextReminder
    }

    private var statusRow: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }

    private var sessionRow: some View {
        Text(sessionText)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var reminderRow: some View {
        HStack(spacing: 5) {
            Image(systemName: "bell")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(reminderText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var statusColor: Color {
        let lower = entry.gatewayStatus.lowercased()
        if lower.contains("已连接") || lower.contains("connected") {
            return .green
        }
        if lower.contains("未连接") || lower.contains("disconnected") || entry.gatewayStatus.isEmpty {
            return .gray
        }
        return .orange
    }
}
