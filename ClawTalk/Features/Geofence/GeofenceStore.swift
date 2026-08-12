import Foundation
import CoreLocation
import Observation

/// 地理围栏存储：UserDefaults（JSON 序列化）增删改查 + CLCircularRegion 注册监听。
///
/// 职责：
/// - 增删改查围栏并持久化到本机；
/// - 授权状态处理：未授权时列表页引导申请，被拒绝后引导去系统设置；
/// - 通过 CLLocationManager.startMonitoring(for:) 注册启用中的围栏（幂等）；
/// - 作为 CLLocationManagerDelegate 接收 didEnterRegion / didExitRegion，
///   命中后复用 NotificationCapability 发本地通知（title = 围栏名，body = message）。
///
/// 授权说明：
/// - 前台定位（NSLocationWhenInUseUsageDescription，Info.plist 已存在）即可注册围栏，
///   围栏事件由系统级服务在 App 后台 / 被杀死后继续投递，无需额外后台定位配置。
/// - 如需更激进的后台表现（例如配合持续位置更新），需由主智能体在 Info.plist 增加
///   NSLocationAlwaysUsageDescription 并在 UIBackgroundModes 增加 location
///   （当前默认前台场景足够，见硬性要求）。
@Observable
@MainActor
final class GeofenceStore {

    /// 全局单例：App 启动 / 主页卡片 / 列表页共用同一数据与监听实例。
    static let shared = GeofenceStore()

    private(set) var regions: [GeofenceRegion] = []
    /// 当前定位授权状态（由 CLLocationManagerDelegate 回调维护，视图 onAppear 也会刷新）。
    private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    /// 通知权限被系统拒绝时置 true（列表页用于提示，不弹授权框）。
    private(set) var notificationPermissionDenied = false
    var errorMessage: String? {
        didSet {
            if let errorMessage {
                LogCollector.record(module: "位置提醒", errorMessage)
            }
        }
    }

    private let storageKey = "clawtalk_geofence_regions_v1"
    private let locationManager = CLLocationManager()
    /// 持有 delegate（CLLocationManager.delegate 是 weak，必须强引用保活）。
    private let monitorDelegate = GeofenceMonitorDelegate()
    /// 已注册监听的围栏标识集合，用于幂等 startMonitoring / stopMonitoring。
    private var monitoredIdentifiers: Set<String> = []

    init() {
        load()
        locationManager.delegate = monitorDelegate
        monitorDelegate.onEntry = { [weak self] identifier in
            Task { @MainActor [weak self] in
                self?.handleRegionEvent(identifier: identifier, isEntry: true)
            }
        }
        monitorDelegate.onExit = { [weak self] identifier in
            Task { @MainActor [weak self] in
                self?.handleRegionEvent(identifier: identifier, isEntry: false)
            }
        }
        monitorDelegate.onAuthorizationChange = { [weak self] status in
            Task { @MainActor [weak self] in
                self?.handleAuthorizationChange(status)
            }
        }
        monitorDelegate.onMonitoringFailure = { [weak self] identifier, error in
            Task { @MainActor [weak self] in
                self?.handleMonitoringFailure(identifier: identifier, error: error)
            }
        }
        refreshAuthorizationState()
    }

    // MARK: - 查询

    /// 已启用的围栏数（主页卡片角标）。
    var enabledRegionCount: Int {
        regions.filter { $0.enabled }.count
    }

    /// 定位服务是否可用（系统设置关闭 / 模拟器无定位时 false）。
    var isLocationServicesEnabled: Bool {
        CLLocationManager.locationServicesEnabled()
    }

    /// 当前设备是否支持圆形围栏监听（模拟器通常返回 false）。
    var isMonitoringAvailable: Bool {
        CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self)
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
    }

    var isDenied: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    // MARK: - 授权

    /// 刷新授权状态（视图 onAppear 调用，恢复自上次回调后的真实状态）。
    func refreshAuthorizationState() {
        authorizationStatus = locationManager.authorizationStatus
    }

    /// 未确定时申请前台定位授权；已拒绝不重复弹框（由列表页引导去系统设置）。
    func requestAuthorizationIfNeeded() {
        guard isLocationServicesEnabled else {
            errorMessage = "定位服务未开启，请先在系统设置里打开定位服务。"
            return
        }
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            break
        case .authorizedWhenInUse, .authorizedAlways:
            syncAllRegions()
        @unknown default:
            break
        }
    }

    private func handleAuthorizationChange(_ status: CLAuthorizationStatus) {
        authorizationStatus = status
        if isAuthorized {
            syncAllRegions()
        } else {
            // 权限变化（拒绝 / 受限）：停止所有监听，避免系统继续投递事件。
            stopAllMonitoring()
        }
    }

    // MARK: - 增删改查

    @discardableResult
    func add(_ region: GeofenceRegion) -> GeofenceRegion {
        regions.append(region)
        sortByCreatedAt()
        persist()
        syncRegionMonitoring(for: region)
        return region
    }

    func update(_ region: GeofenceRegion) {
        guard let index = regions.firstIndex(where: { $0.id == region.id }) else { return }
        regions[index] = region
        sortByCreatedAt()
        persist()
        syncRegionMonitoring(for: region)
    }

    func delete(id: String) {
        guard let region = regions.first(where: { $0.id == id }) else { return }
        stopMonitoring(for: region)
        regions.removeAll { $0.id == id }
        persist()
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        guard let index = regions.firstIndex(where: { $0.id == id }) else { return }
        regions[index].enabled = enabled
        persist()
        if enabled {
            syncRegionMonitoring(for: regions[index])
        } else {
            stopMonitoring(for: regions[index])
        }
    }

    /// 启动 / 进页面时调用：重新注册所有启用中的围栏（幂等，已注册的不重复 start）。
    func startMonitoringIfNeeded() {
        refreshAuthorizationState()
        syncAllRegions()
    }

    private func syncAllRegions() {
        let enabledIdentifiers = Set(regions.filter { $0.enabled }.map { Self.regionIdentifier(for: $0.id) })
        for identifier in monitoredIdentifiers where !enabledIdentifiers.contains(identifier) {
            stopMonitoring(identifier: identifier)
        }
        for region in regions where region.enabled {
            syncRegionMonitoring(for: region)
        }
    }

    // MARK: - 围栏注册 / 注销

    /// 按当前状态同步单个围栏：启用且已授权且设备支持则注册，否则注销。
    private func syncRegionMonitoring(for region: GeofenceRegion) {
        if region.enabled, isAuthorized, isMonitoringAvailable {
            registerMonitoring(for: region)
        } else {
            stopMonitoring(for: region)
        }
    }

    private func registerMonitoring(for region: GeofenceRegion) {
        guard isMonitoringAvailable else {
            LogCollector.record(module: "位置提醒", "设备不支持围栏监听，未注册「\(region.name)」")
            return
        }
        let identifier = Self.regionIdentifier(for: region.id)
        guard !monitoredIdentifiers.contains(identifier) else { return }
        let circular = CLCircularRegion(
            center: CLLocationCoordinate2D(latitude: region.latitude, longitude: region.longitude),
            radius: max(1, region.radius),
            identifier: identifier
        )
        circular.notifyOnEntry = region.event.monitorsEntry
        circular.notifyOnExit = region.event.monitorsExit
        locationManager.startMonitoring(for: circular)
        monitoredIdentifiers.insert(identifier)
    }

    private func stopMonitoring(for region: GeofenceRegion) {
        stopMonitoring(identifier: Self.regionIdentifier(for: region.id))
    }

    private func stopMonitoring(identifier: String) {
        guard monitoredIdentifiers.contains(identifier) else { return }
        for region in locationManager.monitoredRegions where region.identifier == identifier {
            locationManager.stopMonitoring(for: region)
        }
        monitoredIdentifiers.remove(identifier)
    }

    private func stopAllMonitoring() {
        for identifier in monitoredIdentifiers {
            stopMonitoring(identifier: identifier)
        }
    }

    // MARK: - 围栏事件 → 本地通知

    private func handleRegionEvent(identifier: String, isEntry: Bool) {
        guard let region = regions.first(where: { Self.regionIdentifier(for: $0.id) == identifier }) else { return }
        guard region.enabled else { return }
        let shouldNotify = isEntry ? region.event.monitorsEntry : region.event.monitorsExit
        guard shouldNotify else { return }

        let title = region.name
        let body = region.message.isEmpty
            ? (isEntry ? "已到达「\(region.name)」" : "已离开「\(region.name)」")
            : region.message

        Task {
            do {
                try await NotificationCapability.notify(title: title, body: body, sound: nil, priority: "urgent")
                notificationPermissionDenied = false
            } catch {
                if let notificationError = error as? NotificationCapability.NotificationError {
                    switch notificationError {
                    case .denied:
                        notificationPermissionDenied = true
                    case .failed(let message):
                        errorMessage = "围栏提醒通知发送失败：\(message)"
                    }
                } else {
                    errorMessage = "围栏提醒通知发送失败：\(error.localizedDescription)"
                }
            }
        }
        LogCollector.record(module: "位置提醒", "\(isEntry ? "进入" : "离开")「\(region.name)」触发提醒")
    }

    private func handleMonitoringFailure(identifier: String?, error: Error) {
        // 常见原因：未授权 / 超过系统围栏数量上限（单个 App 20 个）/ 设备不支持。
        errorMessage = "围栏监听失败：\(error.localizedDescription)"
        if let identifier {
            monitoredIdentifiers.remove(identifier)
        }
    }

    // MARK: - 本地持久化

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([GeofenceRegion].self, from: data)
        else {
            regions = []
            return
        }
        regions = decoded.sorted { $0.createdAt < $1.createdAt }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(regions) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func sortByCreatedAt() {
        regions.sort { $0.createdAt < $1.createdAt }
    }

    // MARK: - 标识

    static func regionIdentifier(for regionID: String) -> String {
        "clawtalk-geofence-\(regionID)"
    }
}

/// 围栏监听回调桥：把 CLLocationManager 的 delegate 回调转发给 store。
/// 系统回调本身在主线程到达，这里通过 Task { @MainActor } 再跳到 store 侧，
/// 避免并发隔离检查问题（Swift 5 模式也保持干净）。
private final class GeofenceMonitorDelegate: NSObject, CLLocationManagerDelegate {
    var onEntry: ((String) -> Void)?
    var onExit: ((String) -> Void)?
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?
    var onMonitoringFailure: ((String?, Error) -> Void)?

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        onEntry?(region.identifier)
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        onExit?(region.identifier)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorizationChange?(manager.authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        onMonitoringFailure?(region?.identifier, error)
    }
}
