//
//  LegacyChineseNineGridLayoutProvider.swift
//
//  旧 .chineseNineGrid（Hamster 原版中文九键）布局提供器：de90be2 原版按键排布。
//

import UIKit

/// 中文九宫格布局（Hamster 原版，仅供旧 .chineseNineGrid 使用）
/// 行1：@/. | ABC | DEF | 删除
/// 行2：GHI | JKL | MNO | 重输
/// 行3：PQRS | TUV | WXYZ | 回车（跨行，占第3/4行两行高）
/// 行4：符号 | 数字 | 空格 | 中/英
public class LegacyChineseNineGridLayoutProvider: ChineseNineGridLayoutProvider {
  static let actionRows: KeyboardActionRows = [
    [.chineseNineGrid(Symbol(char: "@/.")), .chineseNineGrid(Symbol(char: "ABC")), .chineseNineGrid(Symbol(char: "DEF")), .backspace],
    [.chineseNineGrid(Symbol(char: "GHI")), .chineseNineGrid(Symbol(char: "JKL")), .chineseNineGrid(Symbol(char: "MNO")), .cleanSpellingArea],
    [.chineseNineGrid(Symbol(char: "PQRS")), .chineseNineGrid(Symbol(char: "TUV")), .chineseNineGrid(Symbol(char: "WXYZ"))],
    [.keyboardType(.classifySymbolic), .keyboardType(.numericNineGrid), .space, .keyboardType(.alphabetic(.lowercased))],
  ]

  public override func actions(context: KeyboardContext) -> KeyboardActionRows {
    let inputActions = Self.actionRows
    var result = KeyboardActionRows()
    result.append(inputActions[0])
    result.append(inputActions[1])
    result.append(inputActions[2] + lowerTrailingActions(for: inputActions, context: context))
    result.append(inputActions[3])
    return result
  }
}
