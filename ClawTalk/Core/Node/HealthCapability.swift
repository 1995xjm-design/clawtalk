import Foundation
import HealthKit

/// 健康数据能力（任务 G）：读取健康步数，返回结构化结果；权限不足返回明确错误。
/// 接线：Info.plist 需增加 NSHealthShareUsageDescription（由主智能体补充）。
enum HealthCapability {

    struct StepsResult: Encodable {
        let steps: Int
        let startDate: String
        let endDate: String
        let unit: String
    }

    enum HealthError: LocalizedError {
        case unavailable(String)
        case denied
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let message): return message
            case .denied: return "健康数据权限被拒绝"
            case .failed(let message): return message
            }
        }
    }

    private static let store = HKHealthStore()

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// 读取最近 days 天的总步数（含当日）。
    static func steps(days: Int = 7) async throws -> StepsResult {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthError.unavailable("此设备不支持健康数据")
        }
        guard let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) else {
            throw HealthError.unavailable("步数数据类型不可用")
        }

        do {
            let granted = try await store.requestAuthorization(
                toShare: [],
                read: [stepType]
            )
            guard granted else { throw HealthError.denied }
        } catch let error as HealthError {
            throw error
        } catch {
            throw HealthError.failed(error.localizedDescription)
        }

        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: .strictStartDate)

        let totalSteps = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Double, Error>) in
            let query = HKStatisticsQuery(
                quantityType: stepType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, statistics, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let value = statistics?.sumQuantity()?.doubleValue(for: .count()) ?? 0
                continuation.resume(returning: value)
            }
            store.execute(query)
        }

        return StepsResult(
            steps: Int(totalSteps.rounded()),
            startDate: formatter.string(from: start),
            endDate: formatter.string(from: now),
            unit: "步"
        )
    }
}