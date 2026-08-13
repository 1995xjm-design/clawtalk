import UIKit

/// ClawTalk 键盘/面板配色（跟随当前主题取色）
///
/// 激活主题由 `ClawPanelPalette.update(theme:userInterfaceStyle:)` 设置，
/// 来源为键盘当前配色（StandardKeyboardAppearance.hamsterColor() 解析后同步）。
/// 未激活主题（系统默认）时回落到苹果原生中性色。
public enum ClawPanelPalette {
  /// 当前激活主题；nil = 系统默认（苹果原生）
  public private(set) static var activeTheme: ClawTalkTheme?
  /// 当前界面样式（决定主题取浅/深变体）
  public private(set) static var activeUserInterfaceStyle: UIUserInterfaceStyle = .light

  /// 由键盘外观解析结果同步主题状态
  public static func update(theme: ClawTalkTheme?, userInterfaceStyle: UIUserInterfaceStyle) {
    activeTheme = theme
    activeUserInterfaceStyle = userInterfaceStyle
  }

  /// 由键盘上下文同步主题状态（面板/工具栏主动调用，不依赖外观先行计算）
  public static func sync(with keyboardContext: KeyboardContext) {
    let config = keyboardContext.hamsterConfiguration?.keyboard
    let schemaName = keyboardContext.hasDarkColorScheme
      ? (config?.useColorSchemaForDark ?? "")
      : (config?.useColorSchemaForLight ?? "")
    update(theme: ClawTalkThemePresets.theme(forSchemaName: schemaName), userInterfaceStyle: keyboardContext.colorScheme)
  }

  /// 当前主题取色
  public static var currentColors: ClawPanelThemeColors {
    if let theme = activeTheme {
      let preset = ClawTalkThemePresets.preset(for: theme)
      return preset.panelColors(userInterfaceStyle: activeUserInterfaceStyle)
    }
    return ClawPanelThemeColors.system(userInterfaceStyle: activeUserInterfaceStyle)
  }

  /// 键盘底色
  public static var keyboardBackground: UIColor { currentColors.keyboardBackground }
  /// 键帽底 / 白色卡片
  public static var keyWhite: UIColor { currentColors.keycapBase }
  /// 键帽次要文字
  public static var keyLabel: UIColor { currentColors.keycapText.withAlphaComponent(0.75) }
  /// 强调色（AI / 发送 / 选中态）
  public static var brandBlue: UIColor { currentColors.accent }
  /// AI 圆未选中底
  public static var aiCircle: UIColor { currentColors.accent.withAlphaComponent(0.22) }
  /// 胶囊选中底 = 选中高亮
  public static var capsuleSelected: UIColor { currentColors.selectedHighlight }
  /// 胶囊未选中底
  public static var capsuleNormal: UIColor { currentColors.keycapBase }
  /// 右侧装饰块
  public static var decoBlock: UIColor { currentColors.accent.withAlphaComponent(0.18) }
  /// 面板底
  public static var panelBackground: UIColor { currentColors.keyboardBackground }
  /// 输入框底
  public static var inputBackground: UIColor { currentColors.keycapBase }
  /// 输入框占位文字
  public static var inputPlaceholder: UIColor { currentColors.keycapText.withAlphaComponent(0.45) }
  /// 标题强调色
  public static var titleBlue: UIColor { currentColors.accent }
  /// 深色图标
  public static var deepBlue: UIColor { currentColors.accent }
  /// 工具栏/功能行背景
  public static var toolbarBackground: UIColor { currentColors.keyboardBackground }
  /// 发送禁用灰
  public static var sendDisabled: UIColor { currentColors.keycapText.withAlphaComponent(0.28) }
  /// 符号键灰底
  public static var symbolKeyGray: UIColor { currentColors.keycapPressed }
  /// 候选栏文字
  public static var candidateText: UIColor { currentColors.keycapText }
  /// 遮罩半透明
  public static let overlayMask = UIColor.black.withAlphaComponent(0.25)
}
