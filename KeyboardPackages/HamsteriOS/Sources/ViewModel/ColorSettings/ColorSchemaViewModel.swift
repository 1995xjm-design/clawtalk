//
//  ColorSchemaViewModel.swift
//
//
//  Created by morse on 14/7/2023.
//

import Combine
import HamsterKeyboardKit
import UIKit

/// 键盘配色 ViewModel：8 选 1（系统默认 / 红 / 白 / 黑 / 黑金 / 海盐蓝 / 森林绿 / 樱花粉）
class KeyboardColorViewModel {
  public var enableColorSchema: Bool {
    get {
      HamsterConfigurationStore.shared.configuration.keyboard?.enableColorSchema ?? false
    }
    set {
      HamsterConfigurationStore.shared.configuration.keyboard?.enableColorSchema = newValue
      HamsterConfigurationStore.shared.applicationConfiguration.keyboard?.enableColorSchema = newValue
    }
  }

  public var useColorSchemaForLight: String {
    get {
      HamsterConfigurationStore.shared.configuration.keyboard?.useColorSchemaForLight ?? ""
    }
    set {
      HamsterConfigurationStore.shared.configuration.keyboard?.useColorSchemaForLight = newValue
      HamsterConfigurationStore.shared.applicationConfiguration.keyboard?.useColorSchemaForLight = newValue
    }
  }

  public var useColorSchemaForDark: String {
    get {
      HamsterConfigurationStore.shared.configuration.keyboard?.useColorSchemaForDark ?? ""
    }
    set {
      HamsterConfigurationStore.shared.configuration.keyboard?.useColorSchemaForDark = newValue
      HamsterConfigurationStore.shared.applicationConfiguration.keyboard?.useColorSchemaForDark = newValue
    }
  }

  /// 设置页可选项：0=系统默认，1...7 = ClawTalk 7 套主题（顺序固定）
  static let themeOptions: [ClawTalkTheme] = ClawTalkTheme.allCases

  /// 当前选项：0=系统默认（苹果原生），1-7 = 对应主题
  public var selectedIndex: Int {
    get {
      guard enableColorSchema else { return 0 }
      let light = useColorSchemaForLight
      let dark = useColorSchemaForDark
      let name = light.isEmpty ? dark : light
      if let theme = ClawTalkThemePresets.theme(forSchemaName: name),
         let index = Self.themeOptions.firstIndex(of: theme) {
        return index + 1
      }
      return 0
    }
    set {
      switch newValue {
      case 0:
        // 系统默认：关闭配色，键盘回落苹果原生外观
        enableColorSchema = false
      default:
        guard Self.themeOptions.indices.contains(newValue - 1) else { return }
        applyTheme(Self.themeOptions[newValue - 1])
      }
    }
  }

  /// 应用主题：写入浅/深 schema 名 + 注入内置预设到 colorSchemas
  private func applyTheme(_ theme: ClawTalkTheme) {
    let preset = ClawTalkThemePresets.preset(for: theme)

    var config = HamsterConfigurationStore.shared.configuration
    var keyboard = config.keyboard ?? KeyboardConfiguration()

    // 注入该主题浅/深两套预设，保证键盘扩展能解析
    var schemas = keyboard.colorSchemas ?? []
    schemas.removeAll { $0.schemaName == preset.lightSchemaName || $0.schemaName == preset.darkSchemaName }
    schemas.append(preset.lightSchema)
    schemas.append(preset.darkSchema)

    keyboard.colorSchemas = schemas
    keyboard.enableColorSchema = true
    keyboard.useColorSchemaForLight = preset.lightSchemaName
    keyboard.useColorSchemaForDark = preset.darkSchemaName
    config.keyboard = keyboard
    HamsterConfigurationStore.shared.configuration = config

    // 同步应用级配置（App 设置页最高优先级）
    var appConfig = HamsterConfigurationStore.shared.applicationConfiguration
    var appKeyboard = appConfig.keyboard ?? KeyboardConfiguration()
    appKeyboard.enableColorSchema = true
    appKeyboard.useColorSchemaForLight = preset.lightSchemaName
    appKeyboard.useColorSchemaForDark = preset.darkSchemaName
    appKeyboard.colorSchemas = keyboard.colorSchemas
    appConfig.keyboard = appKeyboard
    HamsterConfigurationStore.shared.applicationConfiguration = appConfig
  }
}
