//
//  BackupViewModel.swift
//  Hamster
//
//  Created by morse on 2023/6/14.
//

import Foundation
import HamsterKeyboardKit
import OSLog
import ProgressHUD
import ZIPFoundation

public class BackupViewModel {
  // MARK: - properties

  lazy var settingItem = SettingItemModel(
    text: "软件备份",
    buttonAction: { [unowned self] in
      await backup()
    },
    favoriteButton: .appBackup
  )

  lazy var importSettingItem = SettingItemModel(
    text: "从文件导入备份",
    buttonAction: { [unowned self] in
      backupSwipeAction = .importBackup
    }
  )

  /// 备份文件列表
  @Published
  var backupFiles: [FileInfo] = []

  @Published
  var backupSwipeAction: BackupSwipeAction?

  /// 选择文件
  var selectFile: FileInfo?

  private let fileBrowserViewModel: FileBrowserViewModel

  // MARK: methods

  init(fileBrowserViewModel: FileBrowserViewModel) {
    self.fileBrowserViewModel = fileBrowserViewModel
  }

  func loadBackupFiles() {
    backupFiles = fileBrowserViewModel.currentPathFiles().filter { $0.url.pathExtension.lowercased() == "zip" }
  }

  /// 备份应用
  func backup() async {
    await ProgressHUD.animate("软件备份中，请等待……", interaction: false)
    do {
      try makeBackup()
      loadBackupFiles()
      await ProgressHUD.success("备份成功", interaction: false, delay: 1.5)
    } catch {
      Logger.statistics.error("App backup error: \(error.localizedDescription)")
      await ProgressHUD.failed("备份失败")
    }
  }

  /// Restore application from backup
  func restore(fileInfo: FileInfo) async {
    await restore(from: fileInfo.url)
  }

  /// 应用恢复（指定备份文件 URL）
  func restore(from selectRestoreFileURL: URL) async {
    await ProgressHUD.animate("恢复中，请等待……", interaction: false)
    do {
      // 解压zip
      if FileManager.default.fileExists(atPath: FileManager.tempBackupDirectory.path) {
        try FileManager.default.removeItem(at: FileManager.tempBackupDirectory)
      }

      try FileManager.default.unzipItem(at: selectRestoreFileURL, to: FileManager.default.temporaryDirectory)

      // 检测 UI 配置文件是否存在，存在则恢复
      let appConfiguration = FileManager.tempUserDataDirectory.appendingPathComponent("hamster.app.yaml")
      if FileManager.default.fileExists(atPath: appConfiguration.path) {
        let appConfig = try HamsterConfigurationRepositories.shared.loadFromYAML(appConfiguration)
        HamsterConfigurationStore.shared.applicationConfiguration = appConfig
        try FileManager.default.removeItem(at: appConfiguration)
      }

      // 恢复输入方案
      try FileManager.copyDirectory(override: true, src: FileManager.tempSharedSupportDirectory, dst: FileManager.sandboxSharedSupportDirectory)
      try FileManager.copyDirectory(override: true, src: FileManager.tempUserDataDirectory, dst: FileManager.sandboxUserDataDirectory)

      await ProgressHUD.success("恢复成功, 请重新部署。", delay: 1.5)
    } catch {
      Logger.statistics.error("App restore error: \(error.localizedDescription)")
      await ProgressHUD.failed("恢复失败")
    }
  }

  /// 从外部文件导入备份（文档选择器选中后调用）
  func importBackup(from externalURL: URL) async {
    let didStartAccessing = externalURL.startAccessingSecurityScopedResource()
    defer {
      if didStartAccessing {
        externalURL.stopAccessingSecurityScopedResource()
      }
    }
    do {
      let backupURL = FileManager.sandboxBackupDirectory
      if !FileManager.default.fileExists(atPath: backupURL.path) {
        try FileManager.createDirectory(dst: backupURL)
      }
      let fileName = externalURL.lastPathComponent.isEmpty
        ? "import-\(DateFormatter.tempFileNameStyle.string(from: Date())).zip"
        : externalURL.lastPathComponent
      let localURL = backupURL.appendingPathComponent(fileName)
      try? FileManager.default.removeItem(at: localURL)
      try FileManager.default.copyItem(at: externalURL, to: localURL)
      await restore(from: localURL)
      loadBackupFiles()
    } catch {
      Logger.statistics.error("App import backup error: \(error.localizedDescription)")
      await ProgressHUD.failed("导入备份失败")
    }
  }

  /// 修改备份文件名称
  func renameBackupFile(at fileURL: URL, newFileName: String) async throws {
    guard !newFileName.isEmpty else { return }

    let newFileURL = fileURL.deletingLastPathComponent()
      .appendingPathComponent(newFileName.hasSuffix(".zip") ? newFileName : newFileName + ".zip", isDirectory: false)

    try? FileManager.default.moveItem(at: fileURL, to: newFileURL)
  }

  /// 创建备份文件
  private func makeBackup() throws {
    // 创建备份临时文件夹
    try FileManager.createDirectory(override: true, dst: FileManager.tempBackupDirectory)

    // copy 当前输入方案
    try FileManager.copyDirectory(override: true, src: FileManager.sandboxSharedSupportDirectory, dst: FileManager.tempSharedSupportDirectory)
    try FileManager.copyDirectory(override: true, src: FileManager.sandboxUserDataDirectory, dst: FileManager.tempUserDataDirectory)

    // 读取 UI 操作产生的配置，并保存至备份文件夹
    if let appConfig = try? HamsterConfigurationRepositories.shared.loadAppConfigurationFromUserDefaults() {
      try HamsterConfigurationRepositories.shared.saveToYAML(config: appConfig, path: FileManager.tempUserDataDirectory.appendingPathComponent("hamster.app.yaml"))
    }

    // 检测备份文件夹是否存在
    let backupURL = FileManager.sandboxBackupDirectory
    if !FileManager.default.fileExists(atPath: backupURL.path) {
      try FileManager.createDirectory(dst: backupURL)
    }

    let fileName = DateFormatter.tempFileNameStyle.string(from: Date())

    // 生成zip包
    try FileManager.default.zipItem(at: FileManager.tempBackupDirectory, to: backupURL.appendingPathComponent("\(fileName).zip"))
  }

  /// 删除备份文件
  func deleteBackupFile(_ backupURL: URL) throws {
    try FileManager.default.removeItem(at: backupURL)
  }
}
