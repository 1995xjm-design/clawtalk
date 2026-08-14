//
//  ClawNineGridLayoutEngine.swift
//
//  ClawTalk「IOS原生」系列页面共用布局引擎。
//

import UIKit

/// ClawTalk「IOS原生」系列页面共用布局引擎
///
/// 支持：
/// - 每行「固定宽度百分比」列 + 「固定 pt 键帽宽」列 + 「等宽均分」列（可带权重）
/// - 整行内边距（paddingH / paddingV，按文档 8pt）
/// - 键帽间距 = keyInset × 2（文档 gap 6pt）
final class ClawNineGridLayoutEngine {
  /// 每行布局规格
  struct RowSpec {
    /// 固定宽度百分比列：列下标 -> 相对视图宽度百分比
    var fixedColumns: [Int: CGFloat] = [:]

    /// 固定 pt 键帽宽列：列下标 -> 键帽宽度（内部自动加 2×keyInset）
    var fixedPtColumns: [Int: CGFloat] = [:]

    /// 等宽均分列：列下标 -> 权重（默认 1）
    var equalWeights: [Int: CGFloat] = [:]

    static func fixed(_ columns: [Int: CGFloat], equal: [Int: CGFloat] = [:]) -> RowSpec {
      RowSpec(fixedColumns: columns, equalWeights: equal)
    }

    static func fixedPt(_ columns: [Int: CGFloat], equal: [Int: CGFloat] = [:]) -> RowSpec {
      RowSpec(fixedPtColumns: columns, equalWeights: equal)
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
  private let padding: UIEdgeInsets
  private let keyInset: CGFloat

  init(
    rowHeight: CGFloat,
    specs: [RowSpec],
    padding: UIEdgeInsets = UIEdgeInsets(top: ClawIOSNativePalette.paddingV, left: ClawIOSNativePalette.paddingH, bottom: ClawIOSNativePalette.paddingV, right: ClawIOSNativePalette.paddingH),
    keyInset: CGFloat = ClawIOSNativePalette.keyInset
  ) {
    self.rowHeight = rowHeight
    self.specs = specs
    self.padding = padding
    self.keyInset = keyInset
  }

  /// 生成并激活约束
  func build(on view: UIView, rows: [[KeyboardButton]]) {
    for (rowIndex, row) in rows.enumerated() {
      let spec = specs[rowIndex]
      let isLastRow = rowIndex + 1 == rows.count
      let fixedMultiplierTotal = spec.fixedColumns.values.reduce(0, +)
      let fixedPtCellTotal = spec.fixedPtColumns.values.reduce(0, +) + CGFloat(spec.fixedPtColumns.count) * keyInset * 2
      let equalTotal = spec.equalWeights.values.reduce(0, +)

      var equalAnchor: KeyboardButton?
      var equalAnchorWeight: CGFloat = 1

      for (columnIndex, button) in row.enumerated() {
        // 高度
        let heightConstraint = button.heightAnchor.constraint(equalToConstant: rowHeight)
        heightConstraint.priority = .defaultHigh
        heightConstraint.identifier = "claw-\(rowIndex)-\(columnIndex)-button-height"
        dynamicHeightConstraints.append(heightConstraint)

        // top
        if rowIndex == 0 {
          staticConstraints.append(button.topAnchor.constraint(equalTo: view.topAnchor, constant: padding.top))
        } else {
          staticConstraints.append(button.topAnchor.constraint(equalTo: rows[rowIndex - 1][0].bottomAnchor))
        }

        // bottom（最后一行）
        if isLastRow {
          staticConstraints.append(button.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -padding.bottom))
        }

        // 宽度
        if let fixedWidth = spec.fixedColumns[columnIndex] {
          staticConstraints.append(button.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: fixedWidth))
        } else if let fixedPt = spec.fixedPtColumns[columnIndex] {
          staticConstraints.append(button.widthAnchor.constraint(equalToConstant: fixedPt + keyInset * 2))
        } else if let weight = spec.equalWeights[columnIndex] {
          if let anchor = equalAnchor {
            staticConstraints.append(button.widthAnchor.constraint(equalTo: anchor.widthAnchor, multiplier: weight / equalAnchorWeight))
          } else {
            equalAnchor = button
            equalAnchorWeight = weight
            let multiplier = max(0, 1 - fixedMultiplierTotal)
            let constant = -(padding.left + padding.right + fixedPtCellTotal)
            staticConstraints.append(button.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: multiplier, constant: constant))
          }
        }

        // leading
        if columnIndex == 0 {
          staticConstraints.append(button.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: padding.left))
        } else {
          staticConstraints.append(button.leadingAnchor.constraint(equalTo: row[columnIndex - 1].trailingAnchor))
        }

        // trailing（最后一行最后一个按键）
        if columnIndex + 1 == row.count {
          staticConstraints.append(button.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -padding.right))
        }
      }
    }

    NSLayoutConstraint.activate(staticConstraints + dynamicHeightConstraints)
  }
}
