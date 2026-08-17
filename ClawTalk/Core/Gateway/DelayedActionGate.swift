import Foundation

/// 延迟动作门（对齐官方 DelayedActionGate）：调度一次性延迟动作并支持取消。
@MainActor
final class DelayedActionGate {
    private var task: Task<Void, Never>?

    func schedule(delay: TimeInterval, action: @escaping @MainActor () -> Void) {
        cancel()
        task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
