import Foundation

/// 面板输入桥接：键盘按键（字符/退格/候选上屏）在面板输入框聚焦时直输进面板输入框。
///
/// - 控制器在键盘启动时注册 `sendText`（建议条/面板「发送」直接写入外部输入框）。
/// - 面板输入框聚焦/失焦时注册/注销 `panelInsert` / `panelDelete`。
public final class ClawPanelInputBridge {
  public static let shared = ClawPanelInputBridge()

  /// 面板输入框插入回调（由 ClawPanelOverlayView 注册）
  public var panelInsert: ((String) -> Void)?
  /// 面板输入框退格回调（由 ClawPanelOverlayView 注册）
  public var panelDelete: (() -> Void)?
  /// 完整文本发送回调（由 KeyboardInputViewController 注册：直接写入外部输入框）
  public var sendText: ((String) -> Void)?

  /// 键盘按键字符/候选上屏 → 面板输入框
  public func insertIntoPanel(_ text: String) {
    panelInsert?(text)
  }

  /// 键盘退格 → 面板输入框
  public func deleteFromPanel() {
    panelDelete?()
  }

  /// 发送一段完整文本（建议条点击 / 面板「发送」按钮）：
  /// 直接写入外部输入框（textDocumentProxy），不经过面板输入框聚焦路由。
  public func send(_ text: String) {
    sendText?(text)
  }
}
