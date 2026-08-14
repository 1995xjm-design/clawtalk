//
//  EnglishSymbolsMoreKeyboard.swift
//
//  ClawTalk「IOS原生」英文符号更多页（英文数字页「#+=」进入，按文档）。
//

import HamsterKit
import HamsterUIKit
import UIKit

/// 英文符号更多页（ClawTalk IOS原生，按文档）
/// 行1：[|]|{|}|#|%|^|*|+|=
/// 行2：_|\||~|<|>|€|£|¥|•
/// 行3：°|¢|£|¥|・|…|—|删除
/// 行4：ABC 52 | 123 52 | 空格弹性 | send 52
class EnglishSymbolsMoreKeyboard: KeyboardTouchView {
  private let keyboardContext: KeyboardContext
  private let actionHandler: KeyboardActionHandler
  private let appearance: KeyboardAppearance
  private let rimeContext: RimeContext

  private var interfaceOrientation: InterfaceOrientation
  private var userInterfaceStyle: UIUserInterfaceStyle
  private var isKeyboardFloating: Bool

  private var keyboardRows: [[KeyboardButton]] = []
  private var staticConstraints: [NSLayoutConstraint] = []
  private var dynamicConstraints: [NSLayoutConstraint] = []

  // MARK: - 计算属性

  private var layoutConfig: KeyboardLayoutConfiguration {
    .standard(for: keyboardContext)
  }

  /// 发送/换行键（跟随外部输入框 returnKeyType，键盘不自行判断）
  private var primaryAction: KeyboardAction {
    let proxy = keyboardContext.textDocumentProxy
    let returnType = proxy.returnKeyType?.keyboardReturnKeyType
    if let returnType { return .primary(returnType) }
    return .primary(.return)
  }

  private var actionRows: KeyboardActionRows {
    [
      [.symbol(Symbol(char: "[")), .symbol(Symbol(char: "]")), .symbol(Symbol(char: "{")), .symbol(Symbol(char: "}")), .symbol(Symbol(char: "#")), .symbol(Symbol(char: "%")), .symbol(Symbol(char: "^")), .symbol(Symbol(char: "*")), .symbol(Symbol(char: "+")), .symbol(Symbol(char: "="))],
      [.symbol(Symbol(char: "_")), .symbol(Symbol(char: "\\")), .symbol(Symbol(char: "|")), .symbol(Symbol(char: "~")), .symbol(Symbol(char: "<")), .symbol(Symbol(char: ">")), .symbol(Symbol(char: "€")), .symbol(Symbol(char: "£")), .symbol(Symbol(char: "¥")), .symbol(Symbol(char: "•"))],
      [.symbol(Symbol(char: "°")), .symbol(Symbol(char: "¢")), .symbol(Symbol(char: "£")), .symbol(Symbol(char: "¥")), .symbol(Symbol(char: "・")), .symbol(Symbol(char: "…")), .symbol(Symbol(char: "—")), .backspace],
      [.keyboardType(.alphabetic(.lowercased)), .keyboardType(.englishNumeric), .space, primaryAction],
    ]
  }

  private var layout: KeyboardLayout {
    let items = actionRows.enumerated().map { row -> KeyboardLayoutItemRow in
      row.element.enumerated().map { action -> KeyboardLayoutItem in
        KeyboardLayoutItem(
          action: action.element,
          size: KeyboardLayoutItemSize(width: .available, height: layoutConfig.rowHeight),
          insets: UIEdgeInsets(top: 3, left: 3, bottom: 3, right: 3),
          swipes: []
        )
      }
    }
    return KeyboardLayout(itemRows: items)
  }

  // MARK: - Initialization

  init(
    actionHandler: KeyboardActionHandler,
    appearance: KeyboardAppearance,
    keyboardContext: KeyboardContext,
    calloutContext: KeyboardCalloutContext,
    rimeContext: RimeContext
  ) {
    self.actionHandler = actionHandler
    self.appearance = appearance
    self.keyboardContext = keyboardContext
    self.rimeContext = rimeContext
    self.interfaceOrientation = keyboardContext.interfaceOrientation
    self.isKeyboardFloating = keyboardContext.isKeyboardFloating
    self.userInterfaceStyle = keyboardContext.colorScheme

    super.init(frame: .zero)

    setupKeyboardView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Layout

  func setupKeyboardView() {
    backgroundColor = ClawIOSNativePalette.colors(for: keyboardContext.colorScheme).keyboardBackground

    constructViewHierarchy()
    activateViewConstraints()
  }

  override public func constructViewHierarchy() {
    for (rowIndex, row) in layout.itemRows.enumerated() {
      var tempRow = [KeyboardButton]()
      for (itemIndex, item) in row.enumerated() {
        let buttonItem = KeyboardButton(
          row: rowIndex,
          column: itemIndex,
          item: item,
          actionHandler: actionHandler,
          keyboardContext: keyboardContext,
          rimeContext: rimeContext,
          calloutContext: .disabled,
          appearance: appearance
        )
        buttonItem.translatesAutoresizingMaskIntoConstraints = false
        addSubview(buttonItem)
        tempRow.append(buttonItem)
      }
      keyboardRows.append(tempRow)
    }
  }

  override public func activateViewConstraints() {
    let rowHeight = layoutConfig.rowHeight

    let engine = ClawNineGridLayoutEngine(
      rowHeight: rowHeight,
      specs: [
        .equal([0: 1, 1: 1, 2: 1, 3: 1, 4: 1, 5: 1, 6: 1, 7: 1, 8: 1, 9: 1]),
        .equal([0: 1, 1: 1, 2: 1, 3: 1, 4: 1, 5: 1, 6: 1, 7: 1, 8: 1, 9: 1]),
        .fixed([7: 0.165], equal: [0: 1, 1: 1, 2: 1, 3: 1, 4: 1, 5: 1, 6: 1]),
        .fixedPt([0: 52, 1: 52, 3: 52], equal: [2: 1]),
      ]
    )
    engine.build(on: self, rows: keyboardRows)

    staticConstraints = engine.staticConstraints
    dynamicConstraints = engine.dynamicHeightConstraints
  }

  override public func layoutSubviews() {
    super.layoutSubviews()

    if userInterfaceStyle != keyboardContext.colorScheme {
      userInterfaceStyle = keyboardContext.colorScheme
      backgroundColor = ClawIOSNativePalette.colors(for: userInterfaceStyle).keyboardBackground
      keyboardRows.forEach { $0.forEach { $0.setNeedsLayout() } }
    }

    guard interfaceOrientation != keyboardContext.interfaceOrientation || isKeyboardFloating != keyboardContext.isKeyboardFloating else { return }
    interfaceOrientation = keyboardContext.interfaceOrientation
    isKeyboardFloating = keyboardContext.isKeyboardFloating

    let rowHeight = layoutConfig.rowHeight
    dynamicConstraints.forEach {
      $0.constant = rowHeight
    }
  }
}
