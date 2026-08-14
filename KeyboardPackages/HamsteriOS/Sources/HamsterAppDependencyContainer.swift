//
//  HamsterAppDependencyContainer.swift
//
//
//  Created by morse on 2023/7/5.
//

import Combine
import Foundation
import HamsterKeyboardKit
import HamsterKit
import OSLog
import UIKit

/// Hamster 应用依赖注入容器
/// 通过此容器，为对象注入依赖
open class HamsterAppDependencyContainer {
  /// 单例
  public static let shared = HamsterAppDependencyContainer()

  /// v049 修复：主 App 嵌入键盘设置页时无 MainViewController 订阅子页跳转，
  /// 由 makeSettingsViewController 内部订阅并 push（详见该方法的 onSubViewRequested）。
  private var subViewSubscriptions = Set<AnyCancellable>()

  // MARK: Long-lived 依赖属性

  public let rimeContext: RimeContext
  public let mainViewModel: MainViewModel

  public lazy var settingsViewModel: SettingsViewModel = {
    let vm = SettingsViewModel(
      navigate: { [weak self] subView in self?.mainViewModel.subViewSubject.send(subView) },
      rimeViewModel: rimeViewModel,
      backupViewModel: backupViewModel
    )
    return vm
  }()

  public lazy var rimeViewModel: RimeViewModel = {
    let vm = RimeViewModel(rimeContext: rimeContext)
    return vm
  }()

  public lazy var backupViewModel: BackupViewModel = {
    let vm = BackupViewModel(fileBrowserViewModel: makeFileBrowserViewModel(rootURL: FileManager.sandboxBackupDirectory))
    return vm
  }()

  public lazy var inputSchemaViewModel: InputSchemaViewModel = {
    let vm = InputSchemaViewModel(rimeContext: rimeContext)
    return vm
  }()

  public lazy var keyboardSettingsViewModel: KeyboardSettingsViewModel = {
    let vm = KeyboardSettingsViewModel()
    return vm
  }()

  /// 应用配置
  public var configuration: HamsterConfiguration {
    didSet {
      Task {
        do {
          Logger.statistics.debug("hamster configuration didSet")
          try HamsterConfigurationRepositories.shared.saveToUserDefaults(configuration)
          // try HamsterConfigurationRepositories.shared.saveToYAML(config: configuration, path: FileManager.hamsterConfigFileOnBuild)
//          try HamsterConfigurationRepositories.shared.saveToJSON(
//            config: configuration,
//            path: FileManager.appGroupUserDataDirectoryURL.appendingPathComponent("/build/hamster.json")
//          )
          try HamsterConfigurationRepositories.shared.saveToPropertyList(
            config: configuration,
            path: FileManager.appGroupUserDataDirectoryURL.appendingPathComponent("/build/hamster.plist")
          )
        } catch {
          Logger.statistics.error("hamster configuration didSet error: \(error.localizedDescription)")
        }
      }
    }
  }

  /// 在 app 内设置的的配置项
  /// 用于在重新部署时，覆盖 hamster.custom.yaml 配置
  /// 配置优先级：应用UI操作配置（存储在 UserDefaults 中） > Rime/hamster.custom.yaml > Rime/hamster.yaml > 默认配置(SharedSupport/hamster.yaml)
  public var applicationConfiguration: HamsterConfiguration = {
    if let config = try? HamsterConfigurationRepositories.shared.loadAppConfigurationFromUserDefaults() {
      return config
    }
    return HamsterConfiguration(
      general: GeneralConfiguration(),
      toolbar: KeyboardToolbarConfiguration(),
      keyboard: KeyboardConfiguration(),
      rime: RimeConfiguration(),
      swipe: KeyboardSwipeConfiguration(),
      keyboards: nil
    )
  }() {
    didSet {
      do {
        try HamsterConfigurationRepositories.shared.saveAppConfigurationToUserDefaults(applicationConfiguration)
      } catch {
        Logger.statistics.error("hamster app configuration set error: \(error.localizedDescription)")
      }
    }
  }

  // 应用默认配置（计算属性）
  // 注意：此配置用于还原系统默认配置
  public var defaultConfiguration: HamsterConfiguration? {
    do {
      return try HamsterConfigurationRepositories.shared.loadFromUserDefaultsOnDefault()
    } catch {
      Logger.statistics.error("loadFromUserDefaultsOnDefault() error: \(error)")
      return nil
    }
  }

  private init() {
    // 创建 long-lived 属性
    self.rimeContext = RimeContext()
    self.mainViewModel = MainViewModel()

    // 判断应用是否首次运行
    // 注意: 首次运行标志（UserDefaults.standard.isFirstRunning）在 SettingsViewModel 的 loadAppData() 方法内重置
    if UserDefaults.standard.isFirstRunning {
      do {
        // 首次运行解压 zip 文件（包含应用内置输入方案及配置文件）
        // 若上次已解压过（部署重试情况）则不再删除重解压，避免每次启动卡黑屏
        let sharedSupportYaml = FileManager.sandboxSharedSupportDirectory.appendingPathComponent("hamster.yaml")
        let alreadyExtracted = FileManager.default.fileExists(atPath: sharedSupportYaml.path)
        try FileManager.initSandboxSharedSupportDirectory(override: !alreadyExtracted)

        // 读取 SharedSupport/hamster.yaml, 生成默认应用配置
        let hamsterConfiguration = try HamsterConfigurationRepositories.shared.loadFromYAML(FileManager.hamsterConfigFileOnSandboxSharedSupport)

        // 作为应用的默认配置，可从默认值中恢复
        try HamsterConfigurationRepositories.shared.saveToUserDefaultsOnDefault(hamsterConfiguration)

        self.configuration = hamsterConfiguration

      } catch {
        self.configuration = HamsterConfiguration()
        Logger.statistics.error("init SharedSupport error: \(error.localizedDescription)")
        ClawLog.record(module: "键盘RIME", "首次启动 SharedSupport 初始化失败: \(error.localizedDescription)")
      }
      return
    }

    // 修复：非首次运行但沙盒缺 SharedSupport/hamster.yaml 时补解压，不依赖首次运行标志
    // 场景：主 App 沙盒被系统清理/升级丢失 SharedSupport，但首次运行标志已非 true
    let sharedSupportYaml = FileManager.sandboxSharedSupportDirectory.appendingPathComponent("hamster.yaml")
    if !FileManager.default.fileExists(atPath: sharedSupportYaml.path) {
      do {
        try FileManager.initSandboxSharedSupportDirectory(override: true)
        Logger.statistics.info("init SharedSupport (missing hamster.yaml) extracted")
      } catch {
        Logger.statistics.error("init SharedSupport (missing hamster.yaml) error: \(error.localizedDescription)")
        ClawLog.record(module: "键盘RIME", "SharedSupport 缺失补解压失败: \(error.localizedDescription)")
      }
    }

    // 非首次启动从 UserDefault 文件中加载
    do {
      self.configuration = try HamsterConfigurationRepositories.shared.loadFromUserDefaults()

      // PATCH
      if !FileManager.default.fileExists(atPath: FileManager.appGroupUserDataDirectoryURL.appendingPathComponent("/build/hamster.plist").path) {
        try HamsterConfigurationRepositories.shared.saveToPropertyList(
          config: configuration,
          path: FileManager.appGroupUserDataDirectoryURL.appendingPathComponent("/build/hamster.plist")
        )
      }
    } catch {
      Logger.statistics.error("load configuration from UserDefault error: \(error.localizedDescription)")
      // 如果从 UserDefaults 加载失败，则尝试从配置文件中加载一次
      if let hamsterConfiguration = try? HamsterConfigurationRepositories.shared.loadFromYAML(FileManager.hamsterConfigFileOnSandboxSharedSupport) {
        self.configuration = hamsterConfiguration
      } else {
        self.configuration = HamsterConfiguration()
      }
    }
  }

  /// 重置应用配置
  public func resetAppConfiguration() {
    HamsterConfigurationRepositories.shared.resetAppConfiguration()
    HamsterAppDependencyContainer.shared.applicationConfiguration = HamsterConfiguration(
      general: GeneralConfiguration(),
      toolbar: KeyboardToolbarConfiguration(),
      keyboard: KeyboardConfiguration(),
      rime: RimeConfiguration(),
      swipe: KeyboardSwipeConfiguration(),
      keyboards: nil
    )

    // 删除 UserDefaults 中的 UI 操作配置
    if let configuration = try? HamsterConfigurationRepositories.shared.loadConfiguration() {
      HamsterAppDependencyContainer.shared.configuration = configuration
    }
  }

  /// 重置应用配置
  public func resetHamsterConfiguration() {
    HamsterConfigurationRepositories.shared.resetConfiguration()
  }
}

extension HamsterAppDependencyContainer {
  func makeZipDocumentPickerViewController() -> UIDocumentPickerViewController {
    let vc = UIDocumentPickerViewController(forOpeningContentTypes: [.zip])
    if let iCloudURL = FileManager.default.url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("Documents") {
      vc.directoryURL = iCloudURL
    } else {
      vc.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    return vc
  }
}

extension HamsterAppDependencyContainer: UploadInputSchemaViewModelFactory {
  func makeUploadInputSchemaViewModel() -> UploadInputSchemaViewModel {
    return UploadInputSchemaViewModel()
  }
}

extension HamsterAppDependencyContainer: FinderViewModelFactory {
  func makeFinderViewModel() -> FinderViewModel {
    return FinderViewModel()
  }
}

extension HamsterAppDependencyContainer: KeyboardSettingsSubViewControllerFactory {
  func makeNumberNineGridSettingsViewController() -> NumberNineGridSettingsViewController {
    NumberNineGridSettingsViewController(keyboardSettingsViewModel: keyboardSettingsViewModel)
  }

  func makeSymbolSettingsViewController() -> SymbolSettingsViewController {
    SymbolSettingsViewController(keyboardSettingsViewModel: keyboardSettingsViewModel)
  }

  func makeSymbolKeyboardSettingsViewController() -> SymbolKeyboardSettingsViewController {
    SymbolKeyboardSettingsViewController(keyboardSettingsViewModel: keyboardSettingsViewModel)
  }

  func makeToolbarSettingsViewController() -> ToolbarSettingsViewController {
    ToolbarSettingsViewController(keyboardSettingsViewModel: keyboardSettingsViewModel)
  }

  func makeKeyboardLayoutViewController() -> KeyboardLayoutViewController {
    KeyboardLayoutViewController(keyboardSettingsViewModel: keyboardSettingsViewModel)
  }

  func makeSpaceSettingsViewController() -> SpaceSettingsViewController {
    SpaceSettingsViewController(keyboardSettingsViewModel: keyboardSettingsViewModel)
  }
}

extension HamsterAppDependencyContainer: KeyboardColorViewModelFactory {
  func makeKeyboardColorViewModel() -> KeyboardColorViewModel {
    KeyboardColorViewModel()
  }
}

extension HamsterAppDependencyContainer: KeyboardFeedbackViewModelFactory {
  func makeKeyboardFeedbackViewModel() -> KeyboardFeedbackViewModel {
    KeyboardFeedbackViewModel()
  }
}

extension HamsterAppDependencyContainer: FileBrowserViewModelFactory {
  func makeFileBrowserViewModel(rootURL: URL) -> FileBrowserViewModel {
    let fileBrowserViewModel = FileBrowserViewModel(rootURL: rootURL)
    return fileBrowserViewModel
  }
}

extension HamsterAppDependencyContainer: AppleCloudViewModelFactory {
  func makeAppleCloudViewModel() -> AppleCloudViewModel {
    return AppleCloudViewModel(settingsViewModel: settingsViewModel)
  }
}


extension HamsterAppDependencyContainer: OpenSourceViewControllerFactory {
  func makeOpenSourceViewController() -> OpenSourceViewController {
    return OpenSourceViewController(openSourceViewModelFactory: self)
  }
}

extension HamsterAppDependencyContainer: OpenSourceViewModelFactory {
  func makeOpenSourceViewModel() -> OpenSourceViewModel {
    return OpenSourceViewModel()
  }
}

extension HamsterAppDependencyContainer: SubViewControllerFactory {
  public func makeRootController() -> MainViewController {
    let navigationController = MainViewController(mainViewModel: mainViewModel, subViewControllerFactory: self)
    return navigationController
  }

  public func makeSettingsViewController() -> SettingsViewController {
    let settingViewController = SettingsViewController(settingsViewModel: settingsViewModel, rimeViewModel: rimeViewModel, backupViewModel: backupViewModel)
    // v049 修复：原版由 MainViewController 订阅 mainViewModel.subViewPublished 完成子页跳转；
    // 主 App 嵌入键盘设置页时没有 MainViewController，这里内部订阅并 push 到所在导航栈。
    mainViewModel.subViewPublished
      .receive(on: DispatchQueue.main)
      .sink { [weak self, weak settingViewController] subView in
        guard let self, let settingViewController, let nav = settingViewController.navigationController else { return }
        if subView == .main {
          nav.popToRootViewController(animated: true)
          return
        }
        if let vc = self.makeSubViewController(for: subView) {
          nav.pushViewController(vc, animated: true)
        }
      }
      .store(in: &subViewSubscriptions)
    return settingViewController
  }

  /// 子页控制器映射（与 MainViewController.navigationResponse 一致）。
  private func makeSubViewController(for subView: SettingsSubView) -> UIViewController? {
    switch subView {
    case .inputSchema: return makeInputSchemaViewController()
    case .finder: return makeFinderViewController()
    case .uploadInputSchema: return makeUploadInputSchemaViewController()
    case .keyboardSettings: return makeKeyboardSettingsViewController()
    case .colorSchema: return makeKeyboardColorViewController()
    case .feedback: return makeKeyboardFeedbackViewController()
    case .rime: return makeRimeViewController()
    case .backup: return makeBackupViewController()
    case .iCloud: return makeAppleCloudViewController()
    case .clawTalk: return makeClawTalkViewController()
    case .autoInsight: return makeAutoInsightViewController()
    case .smartFreq: return makeSmartFreqViewController()
    case .googleDrive: return makeGoogleDriveViewController()
    case .debugLog: return makeLogViewController()
    case .inputMethodSettings: return makeInputMethodSettingsViewController()
    case .heartTargets: return makeHeartTargetSettingsViewController()
    case .main, .about, .none: return nil
    }
  }

  func makeInputSchemaViewController() -> InputSchemaViewController {
    let inputSchemaViewController = InputSchemaViewController(
      inputSchemaViewModel: inputSchemaViewModel,
      documentPickerViewController: makeZipDocumentPickerViewController()
    )
    return inputSchemaViewController
  }

  func makeUploadInputSchemaViewController() -> UploadInputSchemaViewController {
    let uploadInputSchemaViewController = UploadInputSchemaViewController(
      uploadInputSchemaViewModelFactory: self
    )
    return uploadInputSchemaViewController
  }

  func makeFinderViewController() -> FinderViewController {
    let finderViewController = FinderViewController(finderViewModelFactory: self, fileBrowserViewModelFactory: self)
    return finderViewController
  }

  func makeKeyboardSettingsViewController() -> KeyboardSettingsViewController {
    let keyboardSettingsViewController = KeyboardSettingsViewController(
      keyboardSettingsViewModel: keyboardSettingsViewModel,
      keyboardSettingsSubViewControllerFactory: self
    )
    return keyboardSettingsViewController
  }

  func makeKeyboardColorViewController() -> KeyboardColorViewController {
    KeyboardColorViewController(keyboardColorViewModelFactory: self)
  }

  func makeKeyboardFeedbackViewController() -> KeyboardFeedbackViewController {
    KeyboardFeedbackViewController(keyboardFeedbackViewModelFactory: self)
  }

  func makeAppleCloudViewController() -> AppleCloudViewController {
    let iCloudViewController = AppleCloudViewController(appleCloudViewModelFactory: self)
    return iCloudViewController
  }

  func makeRimeViewController() -> RimeViewController {
    let rimeViewController = RimeViewController(rimeViewModel: rimeViewModel)
    return rimeViewController
  }

  func makeBackupViewController() -> BackupViewController {
    let backupViewController = BackupViewController(backupViewModel: backupViewModel)
    return backupViewController
  }


  func makeClawTalkViewController() -> ClawTalkViewController {
    return ClawTalkViewController()
  }

  func makeAutoInsightViewController() -> AutoInsightViewController {
    return AutoInsightViewController()
  }

  func makeSmartFreqViewController() -> SmartFreqViewController {
    return SmartFreqViewController()
  }

  func makeGoogleDriveViewController() -> GoogleDriveViewController {
    return GoogleDriveViewController()
  }

  func makeLogViewController() -> LogViewController {
    return LogViewController()
  }

  func makeInputMethodSettingsViewController() -> InputMethodSettingsViewController {
    return InputMethodSettingsViewController(
      onNavigate: { [weak self] subView in self?.mainViewModel.subViewSubject.send(subView) },
      enableColorSchema: { [weak self] in
        self?.settingsViewModel.enableColorSchema ?? false
      }
    )
  }


  func makeHeartTargetSettingsViewController() -> HeartTargetSettingsViewController {
    HeartTargetSettingsViewController()
  }
}
