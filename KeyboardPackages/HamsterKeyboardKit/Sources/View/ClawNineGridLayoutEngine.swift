//
//  ClawNineGridLayoutEngine.swift
//
//  ClawTalk「IOS原生」九宫格系列页面共用布局引擎。
//

import UIKit

/// ClawTalk「IOS原生」九宫格系列页面共用布局引擎
///
/// 支持：
/// - 每行「固定宽度」列 + 「等宽均分」列（可带权重）
/// - 末尾两行右侧「纵向通高」按键（如确认竖块，禁止拆成多个小按钮）
/// - 行高随 `KeyboardLayoutConfiguration.rowHeight` 动态调整
final class ClawNineGridLayoutEngine {
  /// 每行布局规格
  struct RowSpec {
    /// 固定宽度列：列下标 -> 相对视图宽度百分比
    var fixedColumns: [Int: CGFloat] = [:]

    /// 等宽均分列：列下标 -> 权重（默认 1，空格等可设 2 拉宽）
    var equalWeights: [Int: CGFloat] = [:]

    static func fixed(_ columns: [Int: CGFloat], equal: [Int: CGFloat] = [:]) -> RowSpec {
      RowSpec(fixedColumns: columns, equalWeights: equal)
    }

    static func equal(_ columns: [Int: CGFloat]) -> RowSpec {
      RowSpec(fixedColumns: [:], equalWeights: columns)
    }
  }

  /// 静态约束
  private(set) var staticConstraints: [NSLayoutConstraint] = []

  /// 行高动态约束（随布局变化更新）
  private(set) var dynamicHeightConstraints: [NSLayoutConstraint] = []

  private let rowHeight: CGFloat
  private let specs: [RowSpec]
  private let verticalSpan: (row: Int, column: Int)?

  init(rowHeight: CGFloat, specs: [RowSpec], verticalSpan: (row: Int, column: Int)? = nil) {
    self.rowHeight = rowHeight
    self.specs = specs
    self.verticalSpan = verticalSpan
  }

  /// 生成并激活约束
  func build(on view: UIView, rows: [[KeyboardButton]]) {
    for (rowIndex, row) in rows.enumerated() {
      let spec = specs[rowIndex]
      let isLastRow = rowIndex + 1 == rows.count
      let fixedTotal = spec.fixedColumns.values.reduce(0, +)
      let equalTotal = spec.equalWeights.values.reduce(0, +)
      let equalUnit = equalTotal > 0 ? max(0, (1 - fixedTotal) / equalTotal) : 0

      var equalAnchor: KeyboardButton?
      var equalAnchorWeight: CGFloat = 1

      for (columnIndex, button) in row.enumerated() {
        let isSpanButton = isVerticalSpan(row: rowIndex, column: columnIndex)

        // 高度（通高按键不设行高，由 top/bottom 决定）
        if !isSpanButton {
          let heightConstraint = button.heightAnchor.constraint(equalToConstant: rowHeight)
          heightConstraint.priority = .defaultHigh
          heightConstraint.identifier = "claw-\(rowIndex)-\(columnIndex)-button-height"
          dynamicHeightConstraints.append(heightConstraint)
        }

        // top
        if rowIndex == 0 {
          staticConstraints.append(button.topAnchor.constraint(equalTo: view.topAnchor))
        } else {
          staticConstraints.append(button.topAnchor.constraint(equalTo: rows[rowIndex - 1][0].bottomAnchor))
        }

        // bottom
        if isSpanButton {
          staticConstraints.append(button.bottomAnchor.constraint(equalTo: view.bottomAnchor))
        } else if isLastRow {
          staticConstraints.append(button.bottomAnchor.constraint(equalTo: view.bottomAnchor))
        }

        // 宽度
        if let fixedWidth = spec.fixedColumns[columnIndex] {
          staticConstraints.append(button.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: fixedWidth))
        } else if let weight = spec.equalWeights[columnIndex] {
          if let anchor = equalAnchor {
            staticConstraints.append(button.widthAnchor.constraint(equalTo: anchor.widthAnchor, multiplier: weight / equalAnchorWeight))
          } else {
            equalAnchor = button
            equalAnchorWeight = weight
            staticConstraints.append(button.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: equalUnit * weight))
          }
        }

        // leading
        if columnIndex == 0 {
          staticConstraints.append(button.leadingAnchor.constraint(equalTo: view.leadingAnchor))
        } else {
          staticConstraints.append(button.leadingAnchor.constraint(equalTo: row[columnIndex - 1].trailingAnchor))
        }

        // trailing（最后一行最后一个按键让位给纵向通高按键）
        if columnIndex + 1 == row.count {
          if isLastRow, let span = verticalSpan {
            let spanButton = rows[span.row][span.column]
            staticConstraints.append(button.trailingAnchor.constraint(equalTo: spanButton.leadingAnchor))
          } else {
            staticConstraints.append(button.trailingAnchor.constraint(equalTo: view.trailingAnchor))
          }
        }
      }
    }

    NSLayoutConstraint.activate(staticConstraints + dynamicHeightConstraints)
  }

  private func isVerticalSpan(row: Int, column: Int) -> Bool {
    guard let span = verticalSpan else { return false }
    return span.row == row && span.column == column
  }
}
