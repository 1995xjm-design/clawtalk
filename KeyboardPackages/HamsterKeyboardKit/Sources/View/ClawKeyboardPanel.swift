//
//  ClawKeyboardPanel.swift
//
//  ClawTalk「IOS原生」面板状态机（按文档 Panel 枚举）。
//

import Foundation

/// ClawTalk「IOS原生」面板枚举（文档 Panel）
enum ClawKeyboardPanel {
  /// 9拼音（中文主页，双层候选栏 + 3 业务按钮所在页）
  case pinyin9
  /// 数字
  case numeric
  /// 数字-更多符号子面板
  case numericMore
  /// 中文符号
  case chineseSymbol
  /// 中文拓展符号子面板
  case chineseSymbolMore
  /// 英文大写
  case englishUpper
  /// 英文小写
  case englishLower
  /// 英文数字页
  case englishNumeric
  /// 英文符号更多页
  case englishSymbolsMore
  /// emoji
  case emoji

  /// 面板 -> 键盘类型
  var keyboardType: KeyboardType {
    switch self {
    case .pinyin9: return .chineseNineGridIOS
    case .numeric: return .numericNineGrid
    case .numericMore: return .numericMoreSymbols
    case .chineseSymbol: return .classifySymbolic
    case .chineseSymbolMore: return .classifySymbolicMore
    case .englishUpper: return .alphabetic(.uppercased)
    case .englishLower: return .alphabetic(.lowercased)
    case .englishNumeric: return .englishNumeric
    case .englishSymbolsMore: return .englishSymbolsMore
    case .emoji: return .emojis
    }
  }

  /// 键盘类型 -> 面板
  static func panel(for type: KeyboardType) -> ClawKeyboardPanel? {
    switch type {
    case .chineseNineGrid, .chineseNineGridIOS: return .pinyin9
    case .numericNineGrid: return .numeric
    case .numericMoreSymbols: return .numericMore
    case .classifySymbolic, .classifySymbolicOfLight: return .chineseSymbol
    case .classifySymbolicMore: return .chineseSymbolMore
    case .alphabetic(let casing): return casing.isUppercased ? .englishUpper : .englishLower
    case .englishNumeric: return .englishNumeric
    case .englishSymbolsMore: return .englishSymbolsMore
    case .emojis: return .emoji
    default: return nil
    }
  }

  /// 是否中文主页（9拼音）
  var isPinyin9Home: Bool { self == .pinyin9 }
}

/// 文档状态机切换映射：
/// - 9拼音：123→数字；ABC→英文小写；#@¥→中文符号；😀→emoji；选拼音→选拼音；空格；发送/换行
/// - 数字：更多→数字更多；ABC→英文小写；,/.空格；发送/换行
/// - 数字更多：123→数字（上一级）；ABC→英文小写
/// - 中文符号：#+=→中文符号更多；ABC→英文小写
/// - 中文符号更多：123→中文符号（上一级）；ABC→英文小写
/// - 英文小写：123→英文数字；#+=→英文符号更多；😀→emoji；SHIFT→英文大写
/// - 英文大写：SHIFT→英文小写；123→英文数字；#+=→英文符号更多
/// - 英文数字：ABC→英文小写；#+=→英文符号更多
/// - 英文符号更多：123→英文数字（上一级）；ABC→英文小写
/// - emoji：TAB_BACK/关闭→来源面板（emoji_prev_panel）
