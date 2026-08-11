import Foundation
import Observation
import SwiftUI

/// 单次健康采样（持久化到 UserDefaults，环形保留最近 2880 条 = 24 小时 @ 30s）。
struct HealthSample: Codable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let success: Bool
    let latencyMs: Double?
    let statusCode: Int?
}

/// 最近 N 小时统计。
struct HealthStats: Sendable {
    let sampleCount: Int
    let successCount: Int
    let successRate: Double
    let avgLatencyMs: Double?
    let disconnectCount: Int
}

/// 每小时聚合桶（用于 24h 柱状图）。
struct HealthBucket: Identifiable, Equatable {
    let hour: Date
    let successCount: Int
    let totalCount: Int
    let avgLatencyMs: Double?

    var id: Date { hour }
    var successRate: Double { totalCount == 0 ? 0 : Double(successCount) / Double(totalCount) }
}

/// 连接健康监控（「连接与状态」功能组）。
///
/// 每 30 秒 GET 网关 /health：记录成功率/延迟/断连次数；
/// 连接状态变化（正常→异常 / 异常→恢复）时发本地通知（复用 NotificationCapability）。
@MainActor
@Observable
final class ConnectionHealthMonitor {

    static let intervalSeconds: TimeInterval = 30
    private static let maxSamples = 2880
    private static let storageKey = "connection_health_samples_v1"

    private(set) var samples: [HealthSample] = []
    private(set) var isMonitoring = false
    private(set) var lastPingError: String?
    private(set) var lastPingDate: Date?

    nonisolated(unsafe) private var pingTask: Task<Void, Never>?
    private var lastHealthy: Bool?

    init() {
        samples = Self.load()
    }

    deinit {
        pingTask?.cancel()
    }

    // MARK: - 启停

    func start(gatewayURL: String) {
        guard !isMonitoring else { return }
        isMonitoring = true
        lastPingError = nil
        pingTask = Task { [weak self] in
            await self?.runLoop(gatewayURL: gatewayURL)
        }
    }

    func stop() {
        pingTask?.cancel()
        pingTask = nil
        isMonitoring = false
    }

    private func runLoop(gatewayURL: String) async {
        while !Task.isCancelled {
            await pingOnce(gatewayURL: gatewayURL)
            try? await Task.sleep(nanoseconds: UInt64(Self.intervalSeconds * 1_000_000_000))
        }
    }

    // MARK: - 探测

    /// 立即检测一次网关 /health。
    func pingOnce(gatewayURL: String) async {
        let base = gatewayURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty, let url = URL(string: "\(base)/health") else {
            lastPingError = "未配置网关地址"
            lastPingDate = Date()
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let start = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let latencyMs = Date().timeIntervalSince(start) * 1000
            lastPingError = nil
            record(gatewayURL: base, success: true, latencyMs: latencyMs, statusCode: status)
        } catch {
            let latencyMs = Date().timeIntervalSince(start) * 1000
            lastPingError = "请求失败：\(AppErrorText.localized(error.localizedDescription))"
            record(gatewayURL: base, success: false, latencyMs: latencyMs, statusCode: nil)
        }
        lastPingDate = Date()
    }

    private func record(gatewayURL: String, success: Bool, latencyMs: Double, statusCode: Int?) {
        samples.append(HealthSample(id: UUID(), timestamp: Date(), success: success, latencyMs: latencyMs, statusCode: statusCode))
        if samples.count > Self.maxSamples {
            samples.removeFirst(samples.count - Self.maxSamples)
        }
        Self.persist(samples)

        // 状态变化时发本地通知（首条采样不通知，避免开机即打扰）
        let healthy = success
        if let last = lastHealthy, last != healthy {
            let title = healthy ? "网关连接已恢复" : "网关连接异常"
            let body = healthy
                ? "\(gatewayURL) 已恢复可达。"
                : "\(gatewayURL) 无法访问，请检查网络或网关状态。"
            Task {
                try? await NotificationCapability.notify(
                    title: title,
                    body: body,
                    sound: nil,
                    priority: healthy ? "low" : "high"
                )
            }
        }
        lastHealthy = healthy
    }

    // MARK: - 统计与图表

    /// 最近 hours 小时内的统计。
    func stats(since hours: Double = 24) -> HealthStats {
        let cutoff = Date().addingTimeInterval(-hours * 3600)
        let recent = samples.filter { $0.timestamp >= cutoff }
        guard !recent.isEmpty else {
            return HealthStats(sampleCount: 0, successCount: 0, successRate: 0, avgLatencyMs: nil, disconnectCount: 0)
        }
        let successCount = recent.filter(\.success).count
        let latencies = recent.compactMap(\.latencyMs)
        let sorted = recent.sorted { $0.timestamp < $1.timestamp }
        var disconnects = 0
        for index in 1..<sorted.count where sorted[index - 1].success && !sorted[index].success {
            disconnects += 1
        }
        return HealthStats(
            sampleCount: recent.count,
            successCount: successCount,
            successRate: Double(successCount) / Double(recent.count),
            avgLatencyMs: latencies.isEmpty ? nil : latencies.reduce(0, +) / Double(latencies.count),
            disconnectCount: disconnects
        )
    }

    /// 最近 24 小时逐小时聚合（旧 → 新）。
    func buckets24h() -> [HealthBucket] {
        let calendar = Calendar.current
        let now = Date()
        let startOfCurrentHour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        var buckets: [HealthBucket] = []
        for offset in (0..<24).reversed() {
            guard let hourStart = calendar.date(byAdding: .hour, value: -offset, to: startOfCurrentHour) else { continue }
            let hourEnd = calendar.date(byAdding: .hour, value: 1, to: hourStart) ?? now
            let inHour = samples.filter { $0.timestamp >= hourStart && $0.timestamp < hourEnd }
            let successCount = inHour.filter(\.success).count
            let latencies = inHour.compactMap(\.latencyMs)
            buckets.append(HealthBucket(
                hour: hourStart,
                successCount: successCount,
                totalCount: inHour.count,
                avgLatencyMs: latencies.isEmpty ? nil : latencies.reduce(0, +) / Double(latencies.count)
            ))
        }
        return buckets
    }

    // MARK: - 持久化

    private static func persist(_ samples: [HealthSample]) {
        if let data = try? JSONEncoder().encode(Array(samples.suffix(maxSamples))) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private static func load() -> [HealthSample] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([HealthSample].self, from: data) else { return [] }
        return Array(decoded.suffix(maxSamples))
    }
}

/// 健康监控页：开关 + 24h 统计 + 柱状曲线 + 最近记录。
/// DiagnosticsView 已内置入口；主智能体如需全局监控可另行接线。
struct ConnectionHealthMonitorView: View {
    let settings: SettingsStore

    @State private var monitor = ConnectionHealthMonitor()

    var body: some View {
        List {
            Section {
                Toggle("开启健康监控", isOn: Binding(
                    get: { monitor.isMonitoring },
                    set: { newValue in
                        if newValue {
                            monitor.start(gatewayURL: settings.settings.gatewayURL)
                        } else {
                            monitor.stop()
                        }
                    }
                ))

                Button {
                    Task { await monitor.pingOnce(gatewayURL: settings.settings.gatewayURL) }
                } label: {
                    Label("立即检测一次", systemImage: "bolt")
                }
                .disabled(settings.settings.gatewayURL.isEmpty)

                if let lastPingDate = monitor.lastPingDate {
                    LabeledContent("最近检测", value: lastPingDate.formatted(date: .omitted, time: .standard))
                }
                if let lastPingError = monitor.lastPingError {
                    Text(lastPingError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("监控")
            } footer: {
                Text("每 30 秒请求一次网关 /health。连接状态变化时会发送本地通知（需通知权限）。离开本页自动停止监控。")
            }

            let stats = monitor.stats()
            Section("最近 24 小时") {
                LabeledContent("检测次数", value: "\(stats.sampleCount)")
                LabeledContent("成功率", value: stats.sampleCount == 0 ? "—" : "\(Int((stats.successRate * 100).rounded()))%")
                LabeledContent("平均延迟", value: stats.avgLatencyMs.map { "\(Int($0.rounded()))ms" } ?? "—")
                LabeledContent("断连次数", value: "\(stats.disconnectCount)")
            }

            Section("24h 健康曲线") {
                if stats.sampleCount == 0 {
                    Text("暂无监控数据，开启后每 30 秒记录一次。")
                        .foregroundStyle(.secondary)
                } else {
                    HealthBarChart(buckets: monitor.buckets24h())
                        .frame(height: 110)
                }
            }

            Section("最近记录") {
                if monitor.samples.isEmpty {
                    Text("暂无记录")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(monitor.samples.suffix(10).reversed())) { sample in
                        HStack(spacing: 8) {
                            Image(systemName: sample.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(sample.success ? .green : .red)
                            Text(sample.timestamp.formatted(date: .omitted, time: .standard))
                                .font(.caption)
                            Spacer()
                            if let statusCode = sample.statusCode {
                                Text("HTTP \(statusCode)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("超时/错误")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let latency = sample.latencyMs {
                                Text("\(Int(latency.rounded()))ms")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("连接健康监控")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            monitor.stop()
        }
    }
}

/// 简单的 24 根柱状图（每小时一根）：绿=正常，橙=部分失败，红=全部失败，灰=无数据。
struct HealthBarChart: View {
    let buckets: [HealthBucket]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(buckets) { bucket in
                RoundedRectangle(cornerRadius: 2)
                    .fill(barColor(bucket))
                    .frame(height: barHeight(bucket))
            }
        }
        .padding(.top, 4)
    }

    private var maxCount: Int {
        max(buckets.map(\.totalCount).max() ?? 0, 1)
    }

    private func barHeight(_ bucket: HealthBucket) -> CGFloat {
        guard bucket.totalCount > 0 else { return 3 }
        return 8 + (92 * CGFloat(bucket.totalCount) / CGFloat(maxCount))
    }

    private func barColor(_ bucket: HealthBucket) -> Color {
        guard bucket.totalCount > 0 else { return Color.gray.opacity(0.25) }
        if bucket.successRate >= 0.9 { return .green }
        if bucket.successRate >= 0.5 { return .orange }
        return .red
    }
}
