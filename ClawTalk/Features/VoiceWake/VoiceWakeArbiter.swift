import Foundation
import Observation

/// 唤醒源（优先级从低到高：AppIntents < 唤醒词 < 耳机 < 手表）。
enum VoiceWakeSource: Int, Comparable, CaseIterable, Sendable {
    case appIntent = 0
    case wakeWord = 1
    case headphones = 2
    case watch = 3

    var displayName: String {
        switch self {
        case .appIntent: return "App Intents"
        case .wakeWord: return "唤醒词"
        case .headphones: return "耳机控制"
        case .watch: return "手表"
        }
    }

    static func < (lhs: VoiceWakeSource, rhs: VoiceWakeSource) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 唤醒请求裁定结果。
enum VoiceWakeDecision: Equatable {
    case granted
    /// 冷却期内拒绝再次唤醒（防误触），remaining 为剩余冷却秒数。
    case deniedCooldown(remaining: TimeInterval)
    /// 已有其他源/手动对讲占用中。
    case deniedBusy(active: String)
    /// 同一源重复激活。
    case deniedDuplicate
}

/// 语音唤醒仲裁器：统一管理多个唤醒源（唤醒词/多唤醒词/耳机控制/AppIntents/手表）
/// 与手动对讲（聊天按住说话、实时语音、免提对话）的麦克风占用冲突。
///
/// 规则（任务要求）：
/// 1. 同一时刻只有一个源能激活对讲；激活时停掉所有其他源监听（避免多个音频引擎抢麦）。
/// 2. 优先级：手表 > 耳机 > 唤醒词 > AppIntents；高优先级可抢占低优先级，抢占不受冷却限制。
/// 3. 冷却时间：激活后 N 秒内不再响应同源/低优先级的再次唤醒（防误触），默认 5 秒。
/// 4. 手动对讲（用户主动操作）始终优先：持有期间一切唤醒源都被拒绝。
///
/// 本类是包装层，不改动 VoiceWakeCapability 的既有实现；接线方把唤醒源请求改为
/// 走 `requestActivation`，把手动对讲开始/结束改为 `holdIntercom`/`releaseIntercom`。
@Observable
@MainActor
final class VoiceWakeArbiter {

    static let shared = VoiceWakeArbiter()
    private init() {}

    // MARK: - 状态

    /// 当前由哪个唤醒源激活了对讲（nil = 无唤醒源占用）。
    private(set) var activeSource: VoiceWakeSource?
    /// 最近一次成功激活时间（用于冷却计算）。
    private(set) var lastActivationAt: Date?
    /// 手动对讲占用中（聊天按住说话/实时语音/免提对话等用户主动操作）。
    private(set) var intercomHeld = false
    /// 激活后冷却时间（秒）：N 秒内不响应再次唤醒，防误触。
    var cooldownInterval: TimeInterval = 5

    /// 激活回调（接线方在此启动对讲/免提对话）。
    var onActivation: ((VoiceWakeSource) -> Void)?
    /// 释放回调（接线方在此收尾对讲）。
    var onDeactivation: ((VoiceWakeSource) -> Void)?

    /// 是否有任何占用（唤醒源激活或手动对讲持有）。
    var isBusy: Bool {
        activeSource != nil || intercomHeld
    }

    /// 距下次允许唤醒的剩余冷却秒数（0 = 不在冷却期）。
    func remainingCooldown() -> TimeInterval {
        guard let last = lastActivationAt else { return 0 }
        return max(0, cooldownInterval - Date().timeIntervalSince(last))
    }

    // MARK: - 唤醒源请求

    /// 唤醒源请求激活对讲。返回裁定结果；granted 时回调 onActivation 并停止其他源监听。
    @discardableResult
    func requestActivation(from source: VoiceWakeSource, reason: String = "") -> VoiceWakeDecision {
        // 手动对讲占用中：任何唤醒源一律拒绝
        if intercomHeld {
            return .deniedBusy(active: "手动对讲占用中")
        }

        // 已有唤醒源激活：同源拒绝重复；低优先级拒绝；高优先级抢占（抢占不受冷却限制）
        if let active = activeSource {
            if source > active {
                deactivate(source: active)
                return grant(source: source, reason: reason)
            }
            return source == active ? .deniedDuplicate : .deniedBusy(active: active.displayName)
        }

        // 冷却期内拒绝再次唤醒（防误触）
        let remaining = remainingCooldown()
        if remaining > 0 {
            return .deniedCooldown(remaining: remaining)
        }

        return grant(source: source, reason: reason)
    }

    /// 唤醒源结束对讲（由接线方在对讲结束时调用）。
    func deactivate(source: VoiceWakeSource) {
        guard activeSource == source else { return }
        activeSource = nil
        onDeactivation?(source)
        LogCollector.record(module: "语音唤醒仲裁", "已释放 \(source.displayName)")
    }

    // MARK: - 手动对讲占用

    /// 手动对讲开始：持有麦克风占用，停掉一切唤醒监听，唤醒源请求一律拒绝。
    @discardableResult
    func holdIntercom() -> Bool {
        if let active = activeSource {
            deactivate(source: active)
        }
        intercomHeld = true
        VoiceWakeCapability.shared.stopListening()
        LogCollector.record(module: "语音唤醒仲裁", "手动对讲占用麦克风")
        return true
    }

    /// 手动对讲结束：释放占用（是否重启唤醒词监听由接线方的看门狗决定）。
    func releaseIntercom() {
        guard intercomHeld else { return }
        intercomHeld = false
        LogCollector.record(module: "语音唤醒仲裁", "手动对讲已释放")
    }

    /// 看门狗/接线方判断是否可以启动唤醒词监听：
    /// 无占用且不在冷却期时才允许，避免与对讲抢麦、避免误触后立刻重新监听。
    func shouldStartWakeListening() -> Bool {
        !isBusy && remainingCooldown() == 0
    }

    // MARK: - 内部

    private func grant(source: VoiceWakeSource, reason: String) -> VoiceWakeDecision {
        activeSource = source
        lastActivationAt = Date()
        // 激活对讲 = 麦克风被占用：停掉所有其他源监听，避免两个音频引擎抢麦
        VoiceWakeCapability.shared.stopListening()
        onActivation?(source)
        LogCollector.record(
            module: "语音唤醒仲裁",
            "已激活 \(source.displayName)\(reason.isEmpty ? "" : "（\(reason)）")"
        )
        return .granted
    }
}
