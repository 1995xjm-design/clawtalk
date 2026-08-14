//
//  ClawBottomSystemBarView.swift
//
//  ClawTalk「IOS原生」底部系统栏：🌐 地球（切换输入法）+ 🎤 麦克风（按住语音输入）。
//

import UIKit

/// 底部系统栏：高 50pt，图标 #636366
final class ClawBottomSystemBarView: UIView {
  private let keyboardContext: KeyboardContext

  /// 🌐 地球：切换输入法（点击弹出系统输入法列表）
  private lazy var globeButton: UIButton = {
    let button = UIButton(type: .system)
    button.setImage(UIImage(systemName: "globe"), for: .normal)
    button.setPreferredSymbolConfiguration(.init(font: .systemFont(ofSize: 20), scale: .default), forImageIn: .normal)
    button.tintColor = ClawIOSNativePalette.bottomBarIcon
    button.translatesAutoresizingMaskIntoConstraints = false
    button.addTarget(self, action: #selector(handleInputModeListFromView(from:with:)), for: .allEvents)
    return button
  }()

  /// 🎤 麦克风：按住说话，松开上屏
  private lazy var micButton: UIButton = {
    let button = UIButton(type: .system)
    button.setImage(UIImage(systemName: "mic"), for: .normal)
    button.setPreferredSymbolConfiguration(.init(font: .systemFont(ofSize: 20), scale: .default), forImageIn: .normal)
    button.tintColor = ClawIOSNativePalette.bottomBarIcon
    button.translatesAutoresizingMaskIntoConstraints = false
    button.addTarget(self, action: #selector(micTouchDown(_:)), for: .touchDown)
    button.addTarget(self, action: #selector(micTouchUp(_:)), for: .touchUpInside)
    button.addTarget(self, action: #selector(micTouchUp(_:)), for: .touchUpOutside)
    button.addTarget(self, action: #selector(micTouchUp(_:)), for: .touchCancel)
    return button
  }()

  init(keyboardContext: KeyboardContext) {
    self.keyboardContext = keyboardContext
    super.init(frame: .zero)

    backgroundColor = ClawIOSNativePalette.keyboardBackground
    setupViews()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupViews() {
    addSubview(globeButton)
    addSubview(micButton)

    NSLayoutConstraint.activate([
      globeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      globeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      globeButton.widthAnchor.constraint(equalToConstant: 40),
      globeButton.heightAnchor.constraint(equalToConstant: 40),

      micButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      micButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      micButton.widthAnchor.constraint(equalToConstant: 40),
      micButton.heightAnchor.constraint(equalToConstant: 40),
    ])
  }

  @objc func handleInputModeListFromView(from: UIView, with: UIEvent) {
    keyboardContext.handleInputModeListFromView(from: from, with: with)
  }

  @objc private func micTouchDown(_ sender: UIButton) {
    ClawVoiceInputService.shared.requestAuthorization { [weak self] granted in
      DispatchQueue.main.async {
        guard granted, let self = self else { return }
        self.startRecording()
      }
    }
  }

  private func startRecording() {
    micButton.setImage(UIImage(systemName: "mic.fill"), for: .normal)
    micButton.tintColor = .systemRed

    ClawVoiceInputService.shared.start { [weak self] result in
      DispatchQueue.main.async {
        self?.resetMicState()
        if case .success(let text) = result, !text.isEmpty {
          ClawPanelInputBridge.shared.send(text)
        }
      }
    }
  }

  @objc private func micTouchUp(_ sender: UIButton) {
    ClawVoiceInputService.shared.stop()
    resetMicState()
  }

  private func resetMicState() {
    micButton.setImage(UIImage(systemName: "mic"), for: .normal)
    micButton.tintColor = ClawIOSNativePalette.bottomBarIcon
  }
}