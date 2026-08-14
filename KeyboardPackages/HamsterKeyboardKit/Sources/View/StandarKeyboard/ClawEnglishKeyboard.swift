//
//  ClawEnglishKeyboard.swift
//
//  ClawTalk「IOS原生」英文 QWERTY 全键盘（大写/小写两页，按文档）。
//

import HamsterKit
import HamsterUIKit
import UIKit

/// 英文 QWERTY 全键盘（ClawTalk IOS原生，按文档）
/// 行1：10 键 30.5×46（QWERTYUIOP）
/// 行2：9 键 34.5×46 水平居中（ASDFGHJKL）
/// 行3：SHIFT 52×46 | ZXCVBNM 等分 | 删除 52×46
/// 行4：123 52×46 | 😀 52×46 | 空格弹性 | send 52×46
/// SHIFT 切换大小写
public class ClawEnglishKeyboard: KeyboardTouchView {
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

  /// 当前是否大写页
  private var isUppercased: Bool {
    if case .alphabetic(let casing) = keyboardContext.keyboardType {
      return casing.isUppercased
    }
    return false
  }

  /// 字母序列（按当前大小写）
  private var letters: [String] {
    Array("qwertyuiopasdfghjklzxcvbnm").map { isUppercased ? String($0).uppercased() : String($0) }
  }

  /// 发送/换行键（跟随外部输入框 returnKeyType，键盘不自行判断）
  private var primaryAction: KeyboardAction {
    let proxy = keyboardContext.textDocumentProxy
    let returnType = proxy.returnKeyType?.keyboardReturnKeyType
    if let returnType { return .primary(returnType) }
    return .primary(.return)
  }

  private var actionRows: KeyboardActionRows {
    let l = letters
    let shiftCasing: KeyboardCase = isUppercased ? .uppercased : .lowercased
    return [
      (0..<10).map { .character(l[$0]) },
      (10..<19).map { .character(l[$0]) },
      [.shift(currentCasing: shiftCasing)]
        + (19..<26).map { .character(l[$0]) }
        + [.backspace],
      [.keyboardType(.englishNumeric), .keyboardType(.emojis), .space, primaryAction],
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
        .equal([0: 1, 1: 1, 2: 1, 3: 1, 4: 1, 5: 1, 6: 1, 7: 1, 8: 1, 9: 1]),
        .equal([0: 1, 1: 1, 2: 1, 3: 1, 4: 1, 5: 1, 6: 1, 7: 1, 8: 1]),
        .fixedPt([0: 52, 8: 52], equal: [1: 1, 2: 1, 3: 1, 4: 1, 5: 1, 6: 1, 7: 1]),
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
