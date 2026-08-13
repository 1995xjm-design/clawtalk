//
//  File.swift
//
//
//  Created by morse on 2023/7/7.
//

import Combine
import HamsterKeyboardKit
import HamsterKit
import ProgressHUD
import UIKit

public class AboutViewModel: ObservableObject {
  init() {}

  @Published
  public var displayOpenSourceView = false

  private let restUISettingsSubject = PassthroughSubject<() -> Void, Never>()
  public var restUISettingsPublished: AnyPublisher<() -> Void, Never> {
    restUISettingsSubject.eraseToAnyPublisher()
  }

  private let exportConfigurationSubject = PassthroughSubject<URL, Never>()
  public var exportConfigurationPublished: AnyPublisher<URL, Never> {
    exportConfigurationSubject.eraseToAnyPublisher()
  }

    lazy var settingItems: [SettingSectionModel] = [
    .init(items: [
      .init(text: "RIME版本", secondaryText: AppInfo.rimeVersion, type: .settings, buttonAction: {
        UIPasteboard.general.string = AppInfo.rimeVersion
        await ProgressHUD.success("复制成功", interaction: false, delay: 1.5)
      })
    ])
  ]
}
