import Foundation
import HealthKit
import Observation

/// 健康数据 ViewModel：步数摘要 + 近 7 天每日粒度数据。
///
/// 数据流：
/// 1. 设备可用性检查 / requestAuthorization / 拒绝检测 / 近 7 天总量，
///    统一走 HealthCapability.steps(days:)（Core/Node 已有实现，本文件不改动）。
/// 2. HealthCapability 只返回区间总量、不含逐日拆分；本类用 HKStatisticsQuery
///    按自然日补齐「今日步数 + 近 7 天每日列表」，权限已由第 1 步统一申请。
/// 3. 未授权 / 设备不支持 / 读取失败均落入明确状态，UI 显示诚实空状态，不造假。
@Observable
@MainActor
final class HealthViewModel {

    /// 健康数据访问状态（UI 分支用）
    enum AccessState: Equatable {
        case unknown      // 尚未加载
        case authorized   // 已授权，可展示真实数据
        case denied       // 权限被拒 → 引导去设置开启
        case unavailable  // 设备不支持健康数据
        case failed       // 其他读取失败
    }

    /// 单日步数（按自然日，含 0 步）
    struct DaySteps: Identifiable, Equatable {
        let date: Date
        let steps: Int
        var id: Date { date }
    }

    private(set) var accessState: AccessState = .unknown
    /// 近 7 天每日步数（日期升序，最后一项为今天）
    private(set) var dailySteps: [DaySteps] = []
    /// 近 7 天总步数（来自 HealthCapability 汇总）
    private(set) var weeklyTotal: Int?
    /// 错误/提示文案（denied / unavailable / failed 时使用）
    private(set) var errorMessage: String?
    private(set) var isLoading = false

    private var hasLoaded = false
    private let store = HKHealthStore()

    /// 今日步数（dailySteps 中对应今天的条目；无则 nil）
    var todaySteps: Int? {
        guard let last = dailySteps.last,
              Calendar.current.isDate(last.date, inSameDayAs: Date())
        else { return nil }
        return last.steps
    }

    /// 首次加载（卡片/详情页 onAppear 用）；失败后可下拉刷新重试。
    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await load()
    }

    /// 加载健康数据；可重复调用（详情页下拉刷新 / 失败重试）。
    func load() async {
        isLoading = true
        defer { isLoading = false }

        // 第 1 步：设备可用性 + 授权申请 + 近 7 天总量。
        // HealthCapability 内部已 requestAuthorization，拒绝时抛 .denied。
        do {
            let result = try await HealthCapability.steps(days: 7)
            weeklyTotal = result.steps
            accessState = .authorized
        } catch let error as HealthCapability.HealthError {
            switch error {
            case .denied:
                accessState = .denied
                errorMessage = "请在设置-健康中开启步数读取权限"
            case .unavailable(let message):
                accessState = .unavailable
                errorMessage = message
            case .failed(let message):
                accessState = .failed
                errorMessage = "读取健康数据失败：\(message)"
            }
            dailySteps = []
            return
        } catch {
            accessState = .failed
            errorMessage = "读取健康数据失败：\(error.localizedDescription)"
            dailySteps = []
            return
        }

        // 第 2 步：逐日粒度（自然日 7 天，含今天）。
        do {
            dailySteps = try await Self.fetchDailySteps(days: 7, store: store)
        } catch {
            accessState = .failed
            errorMessage = "读取每日步数失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 每日步数查询

    /// 近 days 天每日步数：每天一次 HKStatisticsQuery（cumulativeSum），自然日对齐。
    private static func fetchDailySteps(days: Int, store: HKHealthStore) async throws -> [DaySteps] {
        guard let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) else {
            throw HealthCapability.HealthError.unavailable("步数数据类型不可用")
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var result: [DaySteps] = []
        result.reserveCapacity(days)

        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let dayStart = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? Date()
            let predicate = HKQuery.predicateForSamples(
                withStart: dayStart,
                end: dayEnd,
                options: .strictStartDate
            )
            let steps = try await Self.sumSteps(type: stepType, predicate: predicate, store: store)
            result.append(DaySteps(date: dayStart, steps: Int(steps.rounded())))
        }
        return result
    }

    private static func sumSteps(
        type: HKQuantityType,
        predicate: NSPredicate,
        store: HKHealthStore
    ) async throws -> Double {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Double, Error>) in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, statistics, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: statistics?.sumQuantity()?.doubleValue(for: .count()) ?? 0)
            }
            store.execute(query)
        }
    }
}
