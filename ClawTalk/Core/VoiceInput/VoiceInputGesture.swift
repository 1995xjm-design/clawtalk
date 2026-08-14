import CoreGraphics

/// 语音输入手势判定（统一几何规则）：
/// - 微信弧形选择层：上滑进入 + 按「角度 + 距离」命中左右弧（取消/转文字）；
/// - 内嵌/悬浮麦：上滑切长录音。
/// 所有入口共用同一套阈值与命中算法，保证行为一致。
enum VoiceInputGestureEvaluator {
    /// 微信弧形选择层：上滑进入选择区的距离（pt）。
    static let arcSlideUpThreshold: CGFloat = 50
    /// 弧形命中最小/最大距离（pt）。
    static let arcMinDistance: CGFloat = 35
    static let arcMaxDistance: CGFloat = 160
    /// 弧形命中角度（0° = 正上方；左右弧各占 20° 以上）。
    static let arcSideAngle: CGFloat = 20
    /// 内嵌/悬浮麦：上滑切长录音的距离（pt）。
    static let longModeSwipeUpThreshold: CGFloat = 70

    /// 是否已上滑进入微信弧形选择区。
    static func didSlideUpToArc(_ translation: CGSize) -> Bool {
        translation.height < -arcSlideUpThreshold
    }

    /// 是否已上滑（内嵌/悬浮麦切长录音阈值）。
    static func didSwipeUpForLongMode(_ translation: CGSize) -> Bool {
        translation.height < -longModeSwipeUpThreshold
    }

    /// 微信弧形命中：按「角度 + 距离」返回落点动作（nil = 中间/无命中）。
    static func arcAction(for translation: CGSize) -> VoiceInputGestureAction? {
        let dx = Double(translation.width)
        let dy = Double(translation.height)
        let distance = sqrt(dx * dx + dy * dy)
        guard distance >= Double(arcMinDistance), distance <= Double(arcMaxDistance) else {
            return nil
        }
        let angle = atan2(dx, -dy) * 180 / .pi
        if angle <= -Double(arcSideAngle) {
            return .cancel
        } else if angle >= Double(arcSideAngle) {
            return .transcribe
        }
        return nil
    }
}
