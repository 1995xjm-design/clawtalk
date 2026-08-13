//
//  HamsterConfigurationStore.swift
//  ClawTalk keyboard app - shared configuration access layer
//
//  Unified read/write entry for keyboard configuration shared via App Group.
//  Independent from the main app environment (MainViewModel / RimeContext /
//  first-run deployment), so ClawTalk can reuse this file + keyboard packages
//  as-is: settings pages and the keyboard extension both read/write the same
//  App Group UserDefaults and shared files.
//

import Foundation
import HamsterKit
import OSLog

/// Shared configuration store for the ClawTalk input method.
/// Mirrors the semantics of HamsterAppDependencyContainer.configuration and
/// .applicationConfiguration, but without any dependency on the main app.
public final class HamsterConfigurationStore {
  public static let shared = HamsterConfigurationStore()

  /// Keyboard runtime configuration.
  /// Persisted to App Group UserDefaults (hamsterConfig key) and
  /// AppGroup/userData/build/hamster.plist.
  public var configuration: HamsterConfiguration {
    get {
      if let cached = cachedConfiguration { return cached }
      let value =
        (try? HamsterConfigurationRepositories.shared.loadFromUserDefaults())
        ?? (try? HamsterConfigurationRepositories.shared.loadConfiguration())
        ?? HamsterConfiguration()
      cachedConfiguration = value
      return value
    }
    set {
      cachedConfiguration = newValue
      persistConfiguration(newValue)
    }
  }

  /// App-level UI settings (highest priority, overrides RIME yaml).
  /// Persisted to App Group UserDefaults (hamsterAppConfig key).
  public var applicationConfiguration: HamsterConfiguration {
    get {
      if let cached = cachedApplicationConfiguration { return cached }
      let value =
        (try? HamsterConfigurationRepositories.shared.loadAppConfigurationFromUserDefaults())
        ?? Self.defaultEmptyConfiguration()
      cachedApplicationConfiguration = value
      return value
    }
    set {
      cachedApplicationConfiguration = newValue
      persistApplicationConfiguration(newValue)
    }
  }

  /// App default configuration (for restoring defaults).
  public var defaultConfiguration: HamsterConfiguration? {
    try? HamsterConfigurationRepositories.shared.loadFromUserDefaultsOnDefault()
  }

  /// Reset app configuration (UI settings + keyboard config).
  public func reset() {
    HamsterConfigurationRepositories.shared.resetAppConfiguration()
    applicationConfiguration = Self.defaultEmptyConfiguration()
    if let loaded = try? HamsterConfigurationRepositories.shared.loadConfiguration() {
      configuration = loaded
    }
  }

  private var cachedConfiguration: HamsterConfiguration?
  private var cachedApplicationConfiguration: HamsterConfiguration?

  private init() {}

  private func persistConfiguration(_ config: HamsterConfiguration) {
    let repositories = HamsterConfigurationRepositories.shared
    let plistURL = FileManager.appGroupUserDataDirectoryURL.appendingPathComponent("/build/hamster.plist")
    Task {
      do {
        try repositories.saveToUserDefaults(config)
        try repositories.saveToPropertyList(config: config, path: plistURL)
      } catch {
        Logger.statistics.error("hamster configuration save error: \(error.localizedDescription)")
      }
    }
  }

  private func persistApplicationConfiguration(_ config: HamsterConfiguration) {
    do {
      try HamsterConfigurationRepositories.shared.saveAppConfigurationToUserDefaults(config)
    } catch {
      Logger.statistics.error("hamster app configuration save error: \(error.localizedDescription)")
    }
  }

  private static func defaultEmptyConfiguration() -> HamsterConfiguration {
    HamsterConfiguration(
      general: GeneralConfiguration(),
      toolbar: KeyboardToolbarConfiguration(),
      keyboard: KeyboardConfiguration(),
      rime: RimeConfiguration(),
      swipe: KeyboardSwipeConfiguration(),
      keyboards: nil
    )
  }
}
