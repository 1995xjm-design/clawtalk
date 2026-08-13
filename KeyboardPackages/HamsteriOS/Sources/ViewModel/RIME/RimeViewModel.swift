//
//  RimeViewModel.swift
//  Hamster
//
//  Created by morse on 2023/6/15.
//

import Combine
import Foundation
import HamsterKeyboardKit
import HamsterKit
import OSLog
import ProgressHUD
import UIKit

public class RimeViewModel {
  public let rimeContext: RimeContext

  private let rimeRestSubject = PassthroughSubject<() -> Void, Never>()
  public var rimeRestPublished: AnyPublisher<() -> Void, Never> {
    rimeRestSubject.eraseToAnyPublisher()
  }

  private let openRimeLoggerViewSubject = PassthroughSubject<Bool, Never>()
  public var openRimeLoggerViewPublished: AnyPublisher<Bool, Never> {
    openRimeLoggerViewSubject.eraseToAnyPublisher()
  }

  private lazy var stdoutHandle = FileHandle.standardOutput
  private lazy var readStderrPipe: Pipe = {
    let pipe = Pipe()
    setvbuf(stderr, nil, _IONBF, 0)
    dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
    return pipe
  }()

  deinit {
    try? stdoutHandle.close()
  }

  // 简繁切换键值
  public var keyValueOfSwitchSimplifiedAndTraditional: String {
    get {
      HamsterConfigurationStore.shared.configuration.rime?.keyValueOfSwitchSimplifiedAndTraditional ?? ""
    }
    set {
      HamsterConfigurationStore.shared.configuration.rime?.keyValueOfSwitchSimplifiedAndTraditional = newValue
      HamsterConfigurationStore.shared.applicationConfiguration.rime?.keyValueOfSwitchSimplifiedAndTraditional = newValue
    }
  }

  /// 简繁切换开关
  /// 基于简繁切换键值是否配置判断：旧文本值非空视为开启，兼容旧存档
  public var isSimplifiedTraditionalEnabled: Bool {
    get { !keyValueOfSwitchSimplifiedAndTraditional.isEmpty }
    set {
      if newValue {
        if keyValueOfSwitchSimplifiedAndTraditional.isEmpty {
          keyValueOfSwitchSimplifiedAndTraditional = "traditionalization"
        }
      } else {
        keyValueOfSwitchSimplifiedAndTraditional = ""
      }
    }
  }

  // 是否覆盖词库文件
  // 非造词用户保持默认值 true
  public var overrideDictFiles: Bool {
    get {
      HamsterConfigurationStore.shared.configuration.rime?.overrideDictFiles ?? true
    }
    set {
      HamsterConfigurationStore.shared.configuration.rime?.overrideDictFiles = newValue
      HamsterConfigurationStore.shared.applicationConfiguration.rime?.overrideDictFiles = newValue
    }
  }

  lazy var settings: [SettingSectionModel] = [
    .init(
      title: "简繁切换",
      footer: "开启后可在键盘上通过简繁切换键在简体与繁体之间快速切换。",
      items: [
        .init(
          text: "启用简繁切换",
          type: .toggle,
          toggleValue: { [unowned self] in isSimplifiedTraditionalEnabled },
          toggleHandled: { [unowned self] in
            isSimplifiedTraditionalEnabled = $0
          }
        ),
      ]
    ),
    .init(
      footer: "如果您未使用自造词功能，请保持保持默认开启状态。",
      items: [
        .init(
          text: "部署时覆盖键盘词库文件",
          type: .toggle,
          toggleValue: { [unowned self] in overrideDictFiles },
          toggleHandled: { [unowned self] in
            overrideDictFiles = $0
          }
        ),
      ]
    ),
    .init(
      items: [
        .init(
          text: "RIME 日志",
          accessoryType: .disclosureIndicator,
          type: .navigation,
          navigationAction: { [unowned self] in
            openRimeLoggerViewSubject.send(true)
          }
        ),
      ]
    ),
    .init(
      items: [
        .init(
          text: "重新部署",
          type: .button,
          buttonAction: { [unowned self] in
            Task {
              await rimeDeploy()
              reloadTableSubject.send(true)
            }
          },
          favoriteButton: .rimeDeploy
        ),
      ]
    ),
    .init(
      footer: """
      注意：
      1. RIME同步自定义参数，需要手工添加至Rime目录下的`installation.yaml`文件中(如果没有，需要则自行创建)；
      2. 同步配置示例：(点击可复制)
      ```
      \(Self.rimeSyncConfigSample)
      ```
      """,
      items: [
        .init(
          text: "RIME同步",
          type: .button,
          buttonAction: { [unowned self] in
            Task {
              await rimeSync()
            }
          },
          favoriteButton: .rimeSync
        ),
      ]
    ),
    .init(items: [
      .init(
        text: "RIME重置",
        textTintColor: .systemRed,
        type: .button,
        buttonAction: { [unowned self] in
          rimeRestSubject.send { [unowned self] in
            Task {
              await rimeRest()
              reloadTableSubject.send(true)
            }
          }
        }
      ),
    ]),
  ]

  private var reloadTableSubject = PassthroughSubject<Bool, Never>()
  public var reloadTablePublished: AnyPublisher<Bool, Never> {
    reloadTableSubject.eraseToAnyPublisher()
  }

  init(rimeContext: RimeContext) {
    self.rimeContext = rimeContext
  }
}

public extension RimeViewModel {
  /// RIME 日志记录
  private func rimeLogger() -> (FileHandle?, URL) {
    let fileName = DateFormatter.tempFileNameStyle.string(from: Date()) + ".log"
    let loggerDirectory = FileManager.sandboxRimeLogDirectory

    try? FileManager.createDirectory(override: false, dst: loggerDirectory)

    // 日志文件最多保存 10 个，排序删除最早的文件
    if let urls = try? FileManager.default.contentsOfDirectory(
      at: loggerDirectory,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ), urls.count >= 10, let url = urls.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).last {
      try? FileManager.default.removeItem(at: url)
    }

    // 创建日志文件
    let filePath = loggerDirectory.appendingPathComponent(fileName)
    FileManager.default.createFile(atPath: filePath.path, contents: nil)
    let fileHandle = try? FileHandle(forWritingTo: filePath)

    // listening on the readabilityHandler
    readStderrPipe.fileHandleForReading.readabilityHandler = { [unowned self] handle in
      let data = handle.availableData
      try? fileHandle?.write(contentsOf: data)
      try? stdoutHandle.write(contentsOf: data)
    }

    return (fileHandle, filePath)
  }

  /// 关闭 RIME Logger 日志
  private func closeRimeLogger(_ fileHandle: FileHandle?) {
    readStderrPipe.fileHandleForReading.readabilityHandler = { [unowned self] handle in
      let data = handle.availableData
      try? stdoutHandle.write(contentsOf: data)
    }
    try? fileHandle?.close()
  }

  /// 检测 RIME Logger 日志是否存在异常
  func checkRimeLogger(_ fileURL: URL) async {
    var errorLines = [String]()
    guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else { return }
    guard let data = try? fileHandle.readToEnd() else { return }
    guard let str = String(data: data, encoding: .utf8) else { return }
    let lines = str.split(separator: "\n").map { String($0) }
    for (index, line) in lines.enumerated() {
      if line.isMatch(regex: ".*[1-9] failure.*") {
        errorLines.append("\(index + 1)")
      }
    }
    try? fileHandle.close()

    if !errorLines.isEmpty {
      await ProgressHUD.banner("RIME日志存在异常", "请检查 \(fileURL.lastPathComponent)，第 \(errorLines.joined(separator: ",")) 行。", delay: 5)
    }
  }

  /// RIME 部署
  /// 手动部署兜底：沙盒 Rime 关键文件缺失时先解压内置方案（带进度），再编译；
  /// 成功后写部署标记并发通知（设置页据此清除「数据未就绪」状态）。
  func rimeDeploy() async {
    let (fileHandle, filePath) = rimeLogger()
    await ProgressHUD.animate("RIME部署中, 请稍候……", AnimationType.circleRotateChase, interaction: false)
    var hamsterConfiguration = HamsterConfigurationStore.shared.configuration
    do {
      if !FileManager.isSandboxRimeUserDataReady {
        // 资源定位双保险：SharedSupport/ 目录优先，回退 Bundle 根目录
        if let zip = FileManager.bundledRimeResource(named: HamsterConstants.userDataZipFile) {
          DispatchQueue.main.async { ProgressHUD.progress("正在解压输入方案 0%", 0, interaction: false) }
          try FileManager.default.unzipSync(zip, dst: FileManager.sandboxUserDataDirectory) { p in
            DispatchQueue.main.async {
              ProgressHUD.progress("正在解压输入方案 \(Int(p * 100))%", CGFloat(p), interaction: false)
            }
          }
        } else {
          try FileManager.initSandboxUserDataDirectory(override: true, unzip: true)
        }
        try FileManager.initSandboxBackupDirectory(override: true)
        DispatchQueue.main.async { ProgressHUD.animate("正在编译输入方案……", interaction: false) }
      }
      try rimeContext.deployment(configuration: &hamsterConfiguration)
      await checkRimeLogger(filePath)
      HamsterConfigurationStore.shared.configuration = hamsterConfiguration
      UserDefaults.hamster.set(true, forKey: "clawTalk_rime_deployed")
      UserDefaults.hamster.set(false, forKey: "clawTalk_rime_deploy_in_progress")
      NotificationCenter.default.post(name: NSNotification.Name("rimeDeployDidSucceed"), object: nil)
      await ProgressHUD.success("部署成功", interaction: false, delay: 1.5)
    } catch {
      UserDefaults.hamster.set(false, forKey: "clawTalk_rime_deploy_in_progress")
      Logger.statistics.error("rime deploy error: \(error)")
      await ProgressHUD.failed(error, interaction: false, delay: 5)
    }
    closeRimeLogger(fileHandle)
  }

  /// RIME 同步
  func rimeSync() async {
    let (fileHandle, filePath) = rimeLogger()
    do {
      await ProgressHUD.animate("RIME同步中, 请稍候……", interaction: false)

      let hamsterConfiguration = HamsterConfigurationStore.shared.configuration

      // 先打开iCloud地址，防止Crash
      _ = URL.iCloudDocumentURL

      // 增加同步路径检测（sync_dir），检测是否有权限写入。
      if let syncDir = FileManager.sandboxInstallationYaml.getSyncPath() {
        if !FileManager.default.fileExists(atPath: syncDir) {
          do {
            try FileManager.default.createDirectory(atPath: syncDir, withIntermediateDirectories: true)
          } catch {
            throw "同步地址无写入权限：\(syncDir)"
          }
        } else {
          if !FileManager.default.isWritableFile(atPath: syncDir) {
            throw "同步地址无写入权限：\(syncDir)"
          }
        }
      }

      try rimeContext.syncRime(configuration: hamsterConfiguration)
      await checkRimeLogger(filePath)
      await ProgressHUD.success("同步成功", interaction: false, delay: 1.5)
    } catch {
      Logger.statistics.error("rime sync error: \(error)")
      await ProgressHUD.failed("同步失败:\(error.localizedDescription)", interaction: false, delay: 3)
    }
    closeRimeLogger(fileHandle)
  }

  /// Rime重置
  func rimeRest() async {
    await ProgressHUD.animate("RIME重置中, 请稍候……", interaction: false)
    do {
      try rimeContext.restRime()

      // 重置应用配置
      HamsterConfigurationRepositories.shared.resetConfiguration()

      // 重新读取 Hamster.yaml 生成 configuration
      let hamsterConfiguration = try HamsterConfigurationRepositories.shared.loadFromYAML(FileManager.hamsterConfigFileOnSandboxSharedSupport)

      // 保存配置至 build/hamster.yaml
      // try? HamsterConfigurationRepositories.shared.saveToYAML(config: configuration, path: FileManager.hamsterConfigFileOnBuild)
  //    try? HamsterConfigurationRepositories.shared.saveToJSON(
  //      config: configuration,
  //      path: FileManager.sandboxUserDataDirectory.appendingPathComponent("/build/hamster.json")
  //    )
      try? HamsterConfigurationRepositories.shared.saveToPropertyList(
        config: hamsterConfiguration,
        path: FileManager.sandboxUserDataDirectory.appendingPathComponent("/build/hamster.plist")
      )

      HamsterConfigurationStore.shared.configuration = hamsterConfiguration

      HamsterConfigurationStore.shared.applicationConfiguration = HamsterConfiguration(
        general: GeneralConfiguration(),
        toolbar: KeyboardToolbarConfiguration(),
        keyboard: KeyboardConfiguration(),
        rime: RimeConfiguration(),
        swipe: KeyboardSwipeConfiguration(),
        keyboards: nil
      )

      // ClawTalk极简九宫格：默认使用 t9（中文九键）方案
      let rimeSchema = RimeSchema(schemaId: "t9", schemaName: "中文九键")
      rimeContext.selectSchemas = [rimeSchema]
      rimeContext.currentSchema = rimeSchema

      /// 在另存一份用于应用配置还原
      try HamsterConfigurationRepositories.shared.saveToUserDefaultsOnDefault(hamsterConfiguration)

      await ProgressHUD.success("重置成功", interaction: false, delay: 1.5)
    } catch {
      Logger.statistics.error("rimeRest() error: \(error)")
      await ProgressHUD.failed("重置失败", interaction: false, delay: 3)
    }
  }
}

public extension RimeViewModel {
  static let rimeSyncConfigSample = """
  # id可以自定义，但不能其他终端定义的ID重复
  installation_id: "hamster"
  # 仓的iOS中iCloud前缀路径固定为：/private/var/mobile/Library/Mobile Documents/iCloud~dev~fuxiao~app~hamsterapp/Documents
  # iOS中的路径与MacOS及Windows的iCloud路径是不同的
  sync_dir: "/private/var/mobile/Library/Mobile Documents/iCloud~dev~fuxiao~app~hamsterapp/Documents/sync"
  """
}
