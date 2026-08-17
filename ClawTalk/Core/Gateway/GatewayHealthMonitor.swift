import Foundation

/// 网关健康监控（对齐官方 GatewayHealthMonitor）：
/// 周期心跳检查，连续失败 maxFailures 次触发 onFailure，直到恢复。
@MainActor
final class GatewayHealthMonitor {
    struct Config {
        var intervalSeconds: Double
        var timeoutSeconds: Double
        var maxFailures: Int

        static let `default` = Config(intervalSeconds: 15, timeoutSeconds: 5, maxFailures: 3)
    }

    private let config: Config
    private var check: (@MainActor () async throws -> Bool)?
    private var onFailure: (@MainActor (_ failureCount: Int) async -> Void)?
    private var task: Task<Void, Never>?
    private(set) var failureCount = 0
    private(set) var isRunning = false

    init(config: Config = .default) {
        self.config = config
    }

    func start(
        check: @escaping @MainActor () async throws -> Bool,
        onFailure: @escaping @MainActor (_ failureCount: Int) async -> Void
    ) {
        self.check = check
        self.onFailure = onFailure
        isRunning = true
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let ok = try await check()
                    if !Task.isCancelled {
                        self.failureCount = ok ? 0 : self.failureCount + 1
                        if !ok, self.failureCount >= self.config.maxFailures {
                            await self.onFailure?(self.failureCount)
                        }
                    }
                } catch {
                    if !Task.isCancelled {
                        self.failureCount += 1
                        if self.failureCount >= self.config.maxFailures {
                            await self.onFailure?(self.failureCount)
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: UInt64(self.config.intervalSeconds * 1_000_000_000))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }
}