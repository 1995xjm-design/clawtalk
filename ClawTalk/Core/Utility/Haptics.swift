import UIKit

/// 统一触感入口：全 App 的 UIImpactFeedbackGenerator / UINotificationFeedbackGenerator
/// 调用收敛到此处，避免散落直接创建系统反馈器。
/// 标准语义触感：selection（选择）/ success（成功）/ warning（警告）/ failure（失败）；
/// impact(_:) 透传 light/medium/heavy，保持录音开始/停止/取消等原有强度语义。
enum Haptics {
    /// 选择：轻量点按反馈
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// 成功
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// 警告
    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    /// 失败
    static func failure() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    /// 冲击强度透传：light / medium / heavy
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}
