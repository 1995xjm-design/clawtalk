//
//  EnglishT9Keyboard.swift
//
//  ClawTalk「IOS原生」英文 T9 页（点 ABC 进入）。
//

import HamsterKit
import HamsterUIKit
import UIKit

/// 英文 T9 页（ClawTalk IOS原生）
/// 行1：123 | QW | ER | TY | 删除
/// 行2：UI | OP | AS | DF | 分隔
/// 行3：GH | JK | LZ | XC | 确认(右侧纵向通高)
/// 行4：😀表情 | 选拼音 | 选定 | 确认(右侧纵向通高)
public class EnglishT9Keyboard: KeyboardTouchView {
  private let actionHandler: KeyboardActionHandler
  private let appearance: KeyboardAppearance
  private var keyboardContext: KeyboardContext
  private var calloutContext: KeyboardCalloutContext
  private var rimeContext: RimeContext

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

  private var actionRows: KeyboardActionRows {
    [
      [.keyboardType(.numericNineGrid), .englishT9(Symbol(char: "QW")), .englishT9(Symbol(char: "ER")), .englishT9(Symbol(char: "TY")), .backspace],
      [.englishT9(Symbol(char: "UI")), .englishT9(Symbol(char: "OP")), .englishT9(Symbol(char: "AS")), .englishT9(Symbol(char: "DF")), .delimiter],
      [.englishT9(Symbol(char: "GH")), .englishT9(Symbol(char: "JK")), .englishT9(Symbol(char: "LZ")), .englishT9(Symbol(char: "XC")), .primary(.custom(title: "确认"))],
      [.keyboardType(.emojis), .t9SelectPinyin, .t9ConfirmCandidate],
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

  public init(
    actionHandler: KeyboardActionHandler,
    appearance: KeyboardAppearance,
    keyboardContext: KeyboardContext,
    calloutContext: KeyboardCalloutContext,
    rimeContext: RimeContext
  ) {
    self.actionHandler = actionHandler
    self.appearance = appearance
    self.keyboardContext = keyboardContext
    self.calloutContext = calloutContext
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
    backgroundColor = ClawIOSNativePalette.keyboardBackground

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
          calloutContext: calloutContext,
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
        .fixed([4: 0.165], equal: [0: 1, 1: 1, 2: 1, 3: 1]),
        .fixed([4: 0.165], equal: [0: 1, 1: 1, 2: 1, 3: 1]),
        .fixed([4: 0.165], equal: [0: 1, 1: 1, 2: 1, 3: 1]),
        .equal([0: 1, 1: 1, 2: 1]),
      ],
      verticalSpan: (row: 2, column: 4)
    )
    engine.build(on: self, rows: keyboardRows)

    staticConstraints = engine.staticConstraints
    dynamicConstraints = engine.dynamicHeightConstraints
  }

  override public func layoutSubviews() {
    super.layoutSubviews()

    if userInterfaceStyle != keyboardContext.colorScheme {
      userInterfaceStyle = keyboardContext.colorScheme
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