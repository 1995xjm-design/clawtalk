import Foundation
import Network
import UIKit

/// 设备信息/状态能力（官方协议对齐）：device.info / device.status。
/// 数据层真实读取设备信息；invoke 收发由 NodeConnection 完成，
/// 返回结构与官方 OpenClawDeviceInfoPayload / OpenClawDeviceStatusPayload 一致。
/// 宿主无独立状态能力文件，device.status 并入本文件（官方同款）。
enum DeviceInfoCapability {

    /// device.info 响应（官方 OpenClawDeviceInfoPayload 结构）。
    struct Info: Encodable {
        let deviceName: String
        let modelIdentifier: String
        let systemName: String
        let systemVersion: String
        let appVersion: String
        let appBuild: String
        let locale: String
    }

    /// device.status 响应（官方 OpenClawDeviceStatusPayload 结构）。
    struct Status: Encodable {
        let battery: BatteryStatus
        let thermal: ThermalStatus
        let storage: StorageStatus
        let network: NetworkStatus
        let uptimeSeconds: Double
    }

    struct BatteryStatus: Encodable {
        let level: Double?
        let state: String
        let lowPowerModeEnabled: Bool
    }

    struct ThermalStatus: Encodable {
        let state: String
    }

    struct StorageStatus: Encodable {
        let totalBytes: Int64
        let freeBytes: Int64
        let usedBytes: Int64
    }

    struct NetworkStatus: Encodable {
        let status: String
        let isExpensive: Bool
        let isConstrained: Bool
        let interfaces: [String]
    }

    /// device.info：设备名/型号标识/系统/版本/语言，全部真实读取。
    @MainActor
    static func getInfo() -> Info {
        let device = UIDevice.current
        let bundle = Bundle.main
        let locale = Locale.preferredLanguages.first ?? Locale.current.identifier

        return Info(
            deviceName: device.name,
            modelIdentifier: Self.modelIdentifier(),
            systemName: device.systemName,
            systemVersion: device.systemVersion,
            appVersion: bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            appBuild: (bundle.infoDictionary?["CFBundleVersion"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            locale: locale
        )
    }

    /// device.status：电量/发热/存储/网络/运行时长，全部真实读取。
    @MainActor
    static func getStatus() async -> Status {
        Status(
            battery: batteryStatus(),
            thermal: thermalStatus(),
            storage: storageStatus(),
            network: await networkStatus(),
            uptimeSeconds: ProcessInfo.processInfo.systemUptime
        )
    }

    // MARK: - Private

    @MainActor
    private static func batteryStatus() -> BatteryStatus {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let level = device.batteryLevel >= 0 ? Double(device.batteryLevel) : nil
        let state: String = switch device.batteryState {
        case .charging: "charging"
        case .full: "full"
        case .unplugged: "unplugged"
        case .unknown: "unknown"
        @unknown default: "unknown"
        }
        return BatteryStatus(
            level: level,
            state: state,
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    private static func thermalStatus() -> ThermalStatus {
        let state: String = switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "nominal"
        }
        return ThermalStatus(state: state)
    }

    private static func storageStatus() -> StorageStatus {
        let attributes = (try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())) ?? [:]
        let total = (attributes[.systemSize] as? NSNumber)?.int64Value ?? 0
        let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let used = max(0, total - free)
        return StorageStatus(totalBytes: total, freeBytes: free, usedBytes: used)
    }

    /// 官方 NetworkStatusService 同款：NWPathMonitor + 1.5s 超时 + 失败兜底。
    private static func networkStatus() async -> NetworkStatus {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "com.openclaw.clawtalk.network-status")
            let state = NetworkStatusState()

            monitor.pathUpdateHandler = { path in
                guard state.markCompleted() else { return }
                monitor.cancel()
                continuation.resume(returning: Self.networkPayload(from: path))
            }
            monitor.start(queue: queue)

            queue.asyncAfter(deadline: .now() + .milliseconds(1500)) {
                guard state.markCompleted() else { return }
                monitor.cancel()
                continuation.resume(returning: Self.fallbackNetworkPayload())
            }
        }
    }

    private static func networkPayload(from path: NWPath) -> NetworkStatus {
        let status: String = switch path.status {
        case .satisfied: "satisfied"
        case .requiresConnection: "requiresConnection"
        case .unsatisfied: "unsatisfied"
        @unknown default: "unsatisfied"
        }

        var interfaces: [String] = []
        if path.usesInterfaceType(.wifi) { interfaces.append("wifi") }
        if path.usesInterfaceType(.cellular) { interfaces.append("cellular") }
        if path.usesInterfaceType(.wiredEthernet) { interfaces.append("wired") }
        if interfaces.isEmpty { interfaces.append("other") }

        return NetworkStatus(
            status: status,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained,
            interfaces: interfaces
        )
    }

    private static func fallbackNetworkPayload() -> NetworkStatus {
        NetworkStatus(status: "unsatisfied", isExpensive: false, isConstrained: false, interfaces: ["other"])
    }

    /// 机器型号标识（如 iPhone15,2）；官方 InstanceIdentity.mobileMachineIdentifier 同款实现。
    private static func modelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { pointer in
            String(bytes: pointer.prefix { $0 != 0 }, encoding: .utf8)
        }
        let trimmed = machine?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "unknown" : trimmed
    }
}

/// NWPathMonitor 一次请求只允许完成一次（官方 NetworkStatusState 同款）。
private final class NetworkStatusState: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func markCompleted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if completed { return false }
        completed = true
        return true
    }
}
