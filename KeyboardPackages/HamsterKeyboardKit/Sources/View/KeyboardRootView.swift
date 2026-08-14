//
//  KeyboardRootView.swift
//
//
//  Created by morse on 2023/8/14.
//

import Combine
import HamsterKit
import HamsterUIKit
import OSLog
import UIKit

/**
 键盘根视图（ClawTalk IOS原生）
 */
class KeyboardRootView: NibLessView {
  public typealias KeyboardWidth = CGFloat
  public typealias KeyboardItemWidth = CGFloat

  // MARK: - Properties

  private let keyboardLayoutProvider: KeyboardLayoutProvider
  private let actionHandler: KeyboardActionHandler
  private let appearance: KeyboardAppearance
  private let layoutConfig: KeyboardLayoutConfiguration
  private var actionCalloutContext: ActionCalloutContext
  private var calloutContext: KeyboardCalloutContext
  private var inputCalloutContext: InputCalloutContext
  private var keyboardContext: KeyboardContext
  private var rimeContext: RimeContext

  private var subscriptions = Set<AnyCancellable>()

  /// 当前键盘类型
  private var currentKeyboardType: KeyboardType

  /// 当前屏幕方向
  private var interfaceOrientation: InterfaceOrientation

  /// 当前界面样式
  private var userInterfaceStyle: UIUserInterfaceStyle

  /// 键盘是否浮动
  private var isKeyboardFloating: Bool

  /// 工具栏收起时约束
  private var toolbarCollapseDynamicConstraints = [NSLayoutConstraint]()

  /// 工具栏展开时约束
  private var toolbarExpandDynamicConstraints = [NSLayoutConstraint]()

  /// 工具栏高度约束
  private var toolbarHeightConstraint: NSLayoutConstraint?

  /// 候选文字视图状态
  private var candidateViewState: CandidateBarView.State

  // MARK: - subview

  /// 26键键盘，包含默认中文26键及英文26键
  private var standerSystemKeyboard: StanderSystemKeyboard {
    let view = StanderSystemKeyboard(
      keyboardLayoutProvider: keyboardLayoutProvider,
      appearance: appearance,
      actionHandler: actionHandler,
      keyboardContext: keyboardContext,
      rimeContext: rimeContext,
      calloutContext: calloutContext
    )
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }

  /// 中文九宫格键盘（IOS原生，新样式）
  private var chineseNineGridKeyboardView: ChineseNineGridIOSKeyboard {
    let view = ChineseNineGridIOSKeyboard(
      keyboardLayoutProvider: keyboardLayoutProvider,
      actionHandler: actionHandler,
      appearance: appearance,
      keyboardContext: keyboardContext,
      calloutContext: calloutContext,
      rimeContext: rimeContext
    )
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }

  /// 中文九宫格键盘（Hamster 原版，旧样式）
  private var legacyChineseNineGridKeyboardView: ChineseNineGridKeyboard {
    let view = ChineseNineGridKeyboard(
      keyboardLayoutProvider: keyboardLayoutProvider,
      actionHandler: actionHandler,
      appearance: appearance,
      keyboardContext: keyboardContext,
      calloutContext: calloutContext,
      rimeContext: rimeContext
    )
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }

  /// 数字九宫格键盘（数字页）
  private var numericNineGridKeyboardView: UIView {
    let view = NumericNineGridKeyboard(
      actionHandler: actionHandler,
      appearance: appearance,
      keyboardContext: keyboardContext,
      calloutContext: calloutContext,
      rimeContext: rimeContext
    )
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }

  /// 扩展符号键盘（符号页）
  private var classifySymbolicKeyboardView: ClassifySymbolicKeyboard {
    let view = ClassifySymbolicKeyboard(
      actionHandler: actionHandler,
      appearance: appearance,
      layoutProvider: keyboardLayoutProvider,
      keyboardContext: keyboardContext,
      rimeContext: rimeContext
    )
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }

  /// 英文 QWERTY 键盘（英文大写/小写页）
  private var clawEnglishKeyboardView: ClawEnglishKeyboard {
    let view = ClawEnglishKeyboard(
      actionHandler: actionHandler,
      appearance: appearance,
      keyboardContext: keyboardContext,
      calloutContext: calloutContext,
      rimeContext: rimeContext
    )
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }

  /// 数字-更多符号子面板
  private var numericMoreSymbolsKeyboardView: NumericMoreSymbolsKeyboard {
    let view = NumericMoreSymbolsKeyboard(
      actionHandler: actionHandler,
      appearance: appearance,
      keyboardContext: keyboardContext,
      calloutContext: calloutContext,
      rimeContext: rimeContext
    )
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }

  /// 中文拓展符号子面板
  private var classifySymbolicMoreKeyboardView: ClassifySymbolicMoreKeyboard {
    let view = ClassifySymbolicMoreKeyboard(
      actionHandler: actionHandler,
      appearance: appearance,
      keyboardContext: keyboardContext,
      calloutContext: calloutContext,
      rimeContext: rimeContext
    )
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }

  /// 英文数字页
  private var englishNumericKeyboardView: EnglishNumericKeyboard {
    let view = EnglishNumericKeyboard(
      actionHandler: actionHandler,
      appearance: appearance,
      keyboardContext: keyboardContext,
      calloutContext: calloutContext,
      rimeContext: rimeContext
    )
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }

  /// 英文符号更多页
  private var englishSymbolsMoreKeyboardView: EnglishSymbolsMoreKeyboard {
    let view = EnglishSymbolsMoreKeyboard(
      actionHandler: actionHandler,
      appearance: appearance,
      keyboardContext: keyboardContext,
      calloutContext: calloutContext,
      rimeContext: rimeContext
    )
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }

  /// emoji键盘（表情面板，完全原生不改内部）
  private var emojisKeyboardView: UIView {
    let view = EmojisKeyboard(
      keyboardContext: keyboardContext,
      actionHandler: actionHandler,
      appearance: appearance
    )
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }

  /// 底部系统栏（🌐 地球 + 🎤 麦克风，高 50pt）
  private lazy var bottomSystemBarView: ClawBottomSystemBarView = {
    let view = ClawBottomSystemBarView(keyboardContext: keyboardContext)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  /// 工具栏（候选栏 + 业务面板 + 建议条）
  private lazy var toolbarView: UIView = {
    let view = KeyboardToolbarView(appearance: appearance, actionHandler: actionHandler, keyboardContext: keyboardContext, rimeContext: rimeContext)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  /// 主键盘
  private lazy var primaryKeyboardView: UIView = {
    if let view = chooseKeyboard(keyboardType: keyboardContext.keyboardType) {
      return view
    }
    return standerSystemKeyboard
  }()

  // MARK: - Initializations

  public init(
    keyboardLayoutProvider: KeyboardLayoutProvider,
    appearance: KeyboardAppearance,
    actionHandler: KeyboardActionHandler,
    keyboardContext: KeyboardContext,
    calloutContext: KeyboardCalloutContext?,
    rimeContext: RimeContext
  ) {
    self.keyboardLayoutProvider = keyboardLayoutProvider
    self.layoutConfig = .standard(for: keyboardContext)
    self.actionHandler = actionHandler
    self.appearance = appearance
    self.keyboardContext = keyboardContext
    self.calloutContext = calloutContext ?? .disabled
    self.actionCalloutContext = calloutContext?.action ?? .disabled
    self.inputCalloutContext = calloutContext?.input ?? .disabled
    self.rimeContext = rimeContext
    self.candidateViewState = keyboardContext.candidatesViewState
    self.currentKeyboardType = keyboardContext.keyboardType
    self.interfaceOrientation = keyboardContext.interfaceOrientation
    self.isKeyboardFloating = keyboardContext.isKeyboardFloating
    self.userInterfaceStyle = keyboardContext.colorScheme

    super.init(frame: .zero)

    constructViewHierarchy()
    activateViewConstraints()
    setupAppearance()

    combine()
  }

  deinit {
    subviews.forEach { $0.removeFromSuperview() }
  }

  override func setupAppearance() {
    backgroundColor = appearance.backgroundStyle.backgroundColor
    contentMode = .redraw
  }

  // MARK: - Layout

  /// 构建视图层次
  override func constructViewHierarchy() {
    addSubview(bottomSystemBarView)
    if keyboardContext.enableToolbar {
      addSubview(toolbarView)
      addSubview(primaryKeyboardView)
    } else {
      addSubview(primaryKeyboardView)
    }
  }

  /// 激活约束
  override func activateViewConstraints() {
    // 底部系统栏固定
    NSLayoutConstraint.activate([
      bottomSystemBarView.bottomAnchor.constraint(equalTo: bottomAnchor),
      bottomSystemBarView.leadingAnchor.constraint(equalTo: leadingAnchor),
      bottomSystemBarView.trailingAnchor.constraint(equalTo: trailingAnchor),
      bottomSystemBarView.heightAnchor.constraint(equalToConstant: ClawIOSNativePalette.bottomBarHeight),
    ])

    if keyboardContext.enableToolbar {
      // 工具栏高度约束，可随配置调整高度
      toolbarHeightConstraint = toolbarView.heightAnchor.constraint(equalToConstant: keyboardContext.clawCandidateBarHeight)

      // 工具栏静态约束
      let toolbarStaticConstraint = createToolbarStaticConstraints()

      // 工具栏收缩时动态约束
      toolbarCollapseDynamicConstraints = createToolbarCollapseDynamicConstraints()

      // 工具栏展开时动态约束
      toolbarExpandDynamicConstraints = createToolbarExpandDynamicConstraints()

      NSLayoutConstraint.activate(toolbarStaticConstraint + toolbarCollapseDynamicConstraints + [toolbarHeightConstraint!])
    } else {
      NSLayoutConstraint.activate(createNoToolbarConstraints())
    }
  }

  /// 工具栏静态约束（不会发生变动）
  func createToolbarStaticConstraints() -> [NSLayoutConstraint] {
    return [
      toolbarView.topAnchor.constraint(equalTo: topAnchor),
      toolbarView.leadingAnchor.constraint(equalTo: leadingAnchor),
      toolbarView.trailingAnchor.constraint(equalTo: trailingAnchor)
    ]
  }

  /// 工具栏展开时动态约束
  func createToolbarExpandDynamicConstraints() -> [NSLayoutConstraint] {
    return [
      toolbarView.bottomAnchor.constraint(equalTo: bottomSystemBarView.topAnchor)
    ]
  }

  /// 工具栏收缩时动态约束
  func createToolbarCollapseDynamicConstraints() -> [NSLayoutConstraint] {
    return [
      primaryKeyboardView.topAnchor.constraint(equalTo: toolbarView.bottomAnchor),
      primaryKeyboardView.bottomAnchor.constraint(equalTo: bottomSystemBarView.topAnchor),
      primaryKeyboardView.leadingAnchor.constraint(equalTo: leadingAnchor),
      primaryKeyboardView.trailingAnchor.constraint(equalTo: trailingAnchor)
    ]
  }

  /// 无工具栏时约束
  func createNoToolbarConstraints() -> [NSLayoutConstraint] {
    return [
      primaryKeyboardView.topAnchor.constraint(equalTo: topAnchor),
      primaryKeyboardView.bottomAnchor.constraint(equalTo: bottomSystemBarView.topAnchor),
      primaryKeyboardView.leadingAnchor.constraint(equalTo: leadingAnchor),
      primaryKeyboardView.trailingAnchor.constraint(equalTo: trailingAnchor)
    ]
  }

  func combine() {
    // 在开启工具栏的状态下，根据候选状态调节候选栏区域大小
    if keyboardContext.enableToolbar {
      keyboardContext.$candidatesViewState
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in
          guard let self = self else { return }
          guard candidateViewState != $0 else { return }
          setNeedsLayout()
        }
        .store(in: &subscriptions)

      // ClawTalk 业务面板：展开时工具栏高度增加（候选栏收起状态下生效）
      keyboardContext.$clawPanelTab
        .receive(on: DispatchQueue.main)
        .sink { [weak self] tab in
          guard let self = self else { return }
          guard let heightConstraint = self.toolbarHeightConstraint else { return }
          if self.keyboardContext.candidatesViewState.isCollapse() {
            let panelHeight: CGFloat = tab >= 0 ? ClawPanelOverlayView.panelHeight : 0
            heightConstraint.constant = self.keyboardContext.clawCandidateBarHeight + panelHeight
          }
        }
        .store(in: &subscriptions)
    }

    // 跟踪 UIUserInterfaceStyle 变化
    keyboardContext.$traitCollection
      .receive(on: DispatchQueue.main)
      .sink { [weak self] in
        guard let self = self else { return }
        guard userInterfaceStyle != $0.userInterfaceStyle else { return }
        userInterfaceStyle = $0.userInterfaceStyle
        setupAppearance()
        if keyboardContext.enableToolbar {
          toolbarView.setNeedsLayout()
        }
        primaryKeyboardView.setNeedsLayout()
      }
      .store(in: &subscriptions)

    // 屏幕方向改变调整按键高度及按键内距
    keyboardContext.$interfaceOrientation
      .receive(on: DispatchQueue.main)
      .sink { [weak self] in
        guard let self = self else { return }
        guard $0 != self.interfaceOrientation else { return }
        self.interfaceOrientation = $0
        self.primaryKeyboardView.setNeedsLayout()
      }
      .store(in: &subscriptions)

    // iPad 浮动模式开启
    keyboardContext.$isKeyboardFloating
      .receive(on: DispatchQueue.main)
      .sink { [weak self] in
        guard let self = self else { return }
        guard self.isKeyboardFloating != $0 else { return }
        self.isKeyboardFloating = $0
        self.primaryKeyboardView.setNeedsLayout()
      }
      .store(in: &subscriptions)

    // 跟踪键盘类型变化
    keyboardContext.keyboardTypePublished
      .receive(on: DispatchQueue.main)
      .sink { [weak self] in
        guard let self = self else { return }
        guard $0 != currentKeyboardType else { return }
        currentKeyboardType = $0

        Logger.statistics.debug("KeyboardRootView keyboardType combine: \($0.yamlString)")

        guard let keyboardView = chooseKeyboard(keyboardType: $0) else {
          Logger.statistics.error("\($0.yamlString) cannot find keyboardView.")
          return
        }

        if keyboardContext.enableToolbar {
          // 候选栏高度随键盘类型变化（中文主页双层 88pt / 其余单层 44pt）
          let panelHeight: CGFloat = keyboardContext.clawPanelTab >= 0 ? ClawPanelOverlayView.panelHeight : 0
          toolbarHeightConstraint?.constant = keyboardContext.clawCandidateBarHeight + panelHeight

          toolbarCollapseDynamicConstraints.removeAll(keepingCapacity: true)
          toolbarExpandDynamicConstraints.removeAll(keepingCapacity: true)

          primaryKeyboardView.subviews.forEach { $0.removeFromSuperview() }
          primaryKeyboardView.removeFromSuperview()

          primaryKeyboardView = keyboardView
          addSubview(primaryKeyboardView)

          // 工具栏收缩时约束
          toolbarCollapseDynamicConstraints = createToolbarCollapseDynamicConstraints()

          // 工具栏展开时约束
          toolbarExpandDynamicConstraints = createToolbarExpandDynamicConstraints()

          NSLayoutConstraint.activate(toolbarCollapseDynamicConstraints)
        } else {
          NSLayoutConstraint.deactivate(constraints)
          primaryKeyboardView.removeFromSuperview()
          primaryKeyboardView = keyboardView
          addSubview(primaryKeyboardView)
          NSLayoutConstraint.activate(createNoToolbarConstraints())
        }
      }
      .store(in: &subscriptions)
  }

  override func layoutSubviews() {
    super.layoutSubviews()

    // 检测候选栏状态是否发生变化
    guard candidateViewState != keyboardContext.candidatesViewState else { return }
    candidateViewState = keyboardContext.candidatesViewState

    // 候选栏收起
    if candidateViewState.isCollapse() {
      // 键盘显示
      let panelHeight: CGFloat = keyboardContext.clawPanelTab >= 0 ? ClawPanelOverlayView.panelHeight : 0
      toolbarHeightConstraint?.constant = keyboardContext.clawCandidateBarHeight + panelHeight
      addSubview(primaryKeyboardView)
      NSLayoutConstraint.deactivate(toolbarExpandDynamicConstraints)
      NSLayoutConstraint.activate(toolbarCollapseDynamicConstraints)
    } else {
      // 键盘隐藏
      let toolbarHeight = primaryKeyboardView.bounds.height + keyboardContext.clawCandidateBarHeight
      primaryKeyboardView.removeFromSuperview()

      toolbarHeightConstraint?.constant = toolbarHeight
      NSLayoutConstraint.deactivate(toolbarCollapseDynamicConstraints)
      NSLayoutConstraint.activate(toolbarExpandDynamicConstraints)
    }
  }

  /// 根据键盘类型选择键盘
  func chooseKeyboard(keyboardType: KeyboardType) -> UIView? {
    var tempKeyboardView: UIView? = nil
    switch keyboardType {
    case .numericNineGrid:
      tempKeyboardView = numericNineGridKeyboardView
    case .classifySymbolic:
      tempKeyboardView = classifySymbolicKeyboardView
    case .emojis:
      tempKeyboardView = emojisKeyboardView
    case .alphabetic:
      // ClawTalk IOS原生模式：英文页 = QWERTY 全键盘；其余 = 标准 26 键
      tempKeyboardView = keyboardContext.isClawIOSNativeMode ? clawEnglishKeyboardView : standerSystemKeyboard
    case .numeric, .symbolic, .chinese, .chineseNumeric, .chineseSymbolic, .custom:
      tempKeyboardView = standerSystemKeyboard
    case .chineseNineGrid:
      // 旧中文九宫格：Hamster 原版（左侧符号列表 + 原版按键排布 + 原版候选栏）
      tempKeyboardView = legacyChineseNineGridKeyboardView
    case .chineseNineGridIOS:
      // 新中文九宫格：IOS原生（文档布局）
      tempKeyboardView = chineseNineGridKeyboardView
    case .englishT9:
      tempKeyboardView = clawEnglishKeyboardView
    case .numericMoreSymbols:
      tempKeyboardView = numericMoreSymbolsKeyboardView
    case .classifySymbolicMore:
      tempKeyboardView = classifySymbolicMoreKeyboardView
    case .englishNumeric:
      tempKeyboardView = englishNumericKeyboardView
    case .englishSymbolsMore:
      tempKeyboardView = englishSymbolsMoreKeyboardView
    default:
      Logger.statistics.error("keyboardType: \(keyboardType.yamlString) not match tempKeyboardType")
      return nil
    }
    return tempKeyboardView
  }
}