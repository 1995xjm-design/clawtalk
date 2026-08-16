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
            try await store.requestAuthorization(
                toShare: [],
                read: [stepType]
            )
            guard store.authorizationStatus(for: stepType) == .sharingAuthorized else { throw HealthError.denied }
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

    struct Summary: Encodable {
        let period: String
        let startISO: String
        let endISO: String
        let timeZoneIdentifier: String
        let stepCount: Int?
        let sleepDurationMinutes: Int?
        let restingHeartRateBpm: Double?
        let workoutCount: Int?
        let workoutDurationMinutes: Int?
    }

    /// health.summary: official OpenClawHealthSummaryPayload for the current day.
    static func summary(period: String = "today") async throws -> Summary {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthError.unavailable("此设备不支持健康数据")
        }

        let now = Date()
        let start = Calendar.current.startOfDay(for: now)

        var readTypes = Set<HKObjectType>()
        if let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) {
            readTypes.insert(stepType)
        }
        if let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            readTypes.insert(sleepType)
        }
        if let heartRateType = HKQuantityType.quantityType(forIdentifier: .restingHeartRate) {
            readTypes.insert(heartRateType)
        }
        readTypes.insert(HKObjectType.workoutType())
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
        } catch {
            // Continue best-effort; individual queries may fail below.
        }

        let stepCount = (try? await steps(days: 1))?.steps
        let sleepDurationMinutes = (try? await sumCategorySleepMinutes(start: start, end: now))
        let restingHeartRateBpm = (try? await averageRestingHeartRate(start: start, end: now))
        let workout = (try? await workoutStats(start: start, end: now))

        return Summary(
            period: period,
            startISO: formatter.string(from: start),
            endISO: formatter.string(from: now),
            timeZoneIdentifier: TimeZone.current.identifier,
            stepCount: stepCount,
            sleepDurationMinutes: sleepDurationMinutes,
            restingHeartRateBpm: restingHeartRateBpm,
            workoutCount: workout?.count,
            workoutDurationMinutes: workout?.minutes
        )
    }

    // MARK: - Summary Queries

    private static func sumCategorySleepMinutes(start: Date, end: Date) async throws -> Int {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return 0 }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let samples: [HKCategorySample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (samples as? [HKCategorySample]) ?? [])
            }
            store.execute(query)
        }
        let asleepValues: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleep.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
        ]
        let total = samples
            .filter { asleepValues.contains($0.value) }
            .reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
        return Int(total / 60)
    }

    private static func averageRestingHeartRate(start: Date, end: Date) async throws -> Double? {
        guard let heartRateType = HKQuantityType.quantityType(forIdentifier: .restingHeartRate) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: heartRateType,
                quantitySamplePredicate: predicate,
                options: .discreteAverage
            ) { _, statistics, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let unit = HKUnit.count().unitDivided(by: .minute())
                continuation.resume(returning: statistics?.averageQuantity()?.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    private static func workoutStats(start: Date, end: Date) async throws -> (count: Int, minutes: Int) {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let samples: [HKWorkout] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            store.execute(query)
        }
        let total = samples.reduce(0.0) { $0 + $1.duration }
        return (samples.count, Int(total / 60))
    }
}