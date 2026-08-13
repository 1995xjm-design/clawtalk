import Combine
import HamsterKit
import PhotosUI
import UIKit

// MARK: - UIView 辅助：沿 responder 链找所属视图控制器

extension UIView {
  var clawParentViewController: UIViewController? {
    var responder: UIResponder? = self
    while let r = responder {
      if let vc = r as? UIViewController { return vc }
      responder = r.next
    }
    return nil
  }
}

// MARK: - 业务面板覆盖层（AI语音助手 / 帮你回 / 超会说）

public final class ClawPanelOverlayView: UIView {
  /// 面板展开高度（标题 + 多行输入 + 结果区 + 建议条 + 聊天对象）
  public static let panelHeight: CGFloat = 220

  enum PanelTab: Int {
    case ai = 0
    case helpReply = 1
    case superTalk = 2
  }

  private let keyboardContext: KeyboardContext
  private let actionHandler: KeyboardActionHandler
  private var subscriptions = Set<AnyCancellable>()

  // 标题
  private let titleLabel = UILabel()
  private let closeButton = UIButton(type: .system)

  // 内容区（按 tab 切换）
  private let aiWaveContainer = UIView()
  private var barStack: [UIView] = []

  // 输入区：多行可滚动输入框 + 语音按钮 + 动作按钮
  private let inputRow = UIView()
  private let inputTextView = UITextView()
  private let micButton = UIButton(type: .system)
  private let actionButton = UIButton(type: .system)

  // 结果展示：可滚动/可选中复制 + 复制按钮
  private let resultTextView = UITextView()
  private let copyButton = UIButton(type: .system)

  // 实时建议条（右侧空余区域）
  private let suggestionStrip = ClawSuggestionStripView()
  private var suggestionStripWidthConstraint: NSLayoutConstraint!

  // 聊天对象
  private let heartTargetButton = UIButton(type: .system)

  // AI 分析状态
  private var isLoading = false
  // 语音状态
  private var isMicHeld = false
  private var isListening = false

  public init(
    appearance: KeyboardAppearance,
    actionHandler: KeyboardActionHandler,
    keyboardContext: KeyboardContext
  ) {
    self.actionHandler = actionHandler
    self.keyboardContext = keyboardContext
    super.init(frame: .zero)

    setupViews()
    setupConstraints()
    bind()

    keyboardContext.$clawPanelTab
      .receive(on: DispatchQueue.main)
      .sink { [weak self] tab in
        if tab < 0 {
          self?.inputTextView.resignFirstResponder()
          ClawVoiceInputService.shared.stop()
        }
        self?.refresh(for: tab)
      }
      .store(in: &subscriptions)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - 视图构建

  private func setupViews() {
    backgroundColor = .clear

    // 主题卡片
    layer.cornerRadius = 20
    layer.masksToBounds = true
    backgroundColor = ClawPanelPalette.keyWhite

    titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
    titleLabel.textColor = ClawPanelPalette.titleBlue
    titleLabel.text = "AI语音助手"

    closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
    closeButton.tintColor = ClawPanelPalette.titleBlue
    closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

    // AI 波形占位（蓝色动态竖条，后续接真实音频）
    for _ in 0..<9 {
      let bar = UIView()
      bar.backgroundColor = ClawPanelPalette.brandBlue
      bar.layer.cornerRadius = 2.5
      bar.autoresizingMask = [.flexibleTopMargin, .flexibleBottomMargin]
      aiWaveContainer.addSubview(bar)
      barStack.append(bar)
    }

    // 多行可滚动输入框：键盘按键直输（inputView 置空禁系统键盘，保留长按粘贴菜单）
    inputTextView.font = .systemFont(ofSize: 15)
    inputTextView.textColor = ClawPanelPalette.candidateText
    inputTextView.backgroundColor = ClawPanelPalette.inputBackground
    inputTextView.layer.cornerRadius = 10
    inputTextView.layer.masksToBounds = true
    inputTextView.textContainerInset = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
    inputTextView.isScrollEnabled = true
    inputTextView.alwaysBounceVertical = false
    inputTextView.inputView = UIView()
    inputTextView.delegate = self

    micButton.setImage(UIImage(systemName: "mic.fill"), for: .normal)
    micButton.setPreferredSymbolConfiguration(.init(font: .systemFont(ofSize: 16), scale: .default), forImageIn: .normal)
    micButton.tintColor = ClawPanelPalette.brandBlue
    micButton.backgroundColor = ClawPanelPalette.inputBackground
    micButton.layer.cornerRadius = 18
    let micLongPress = UILongPressGestureRecognizer(target: self, action: #selector(micLongPressed(_:)))
    micLongPress.minimumPressDuration = 0.3
    micButton.addGestureRecognizer(micLongPress)

    actionButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
    actionButton.setTitleColor(.white, for: .normal)
    actionButton.backgroundColor = ClawPanelPalette.brandBlue
    actionButton.layer.cornerRadius = 10
    actionButton.addTarget(self, action: #selector(actionButtonTapped), for: .touchUpInside)
    let longPress = UILongPressGestureRecognizer(target: self, action: #selector(actionButtonLongPressed(_:)))
    longPress.minimumPressDuration = 0.5
    actionButton.addGestureRecognizer(longPress)

    // 结果区：可滚动、可选中复制
    resultTextView.font = .systemFont(ofSize: 13)
    resultTextView.textColor = ClawPanelPalette.candidateText
    resultTextView.backgroundColor = .clear
    resultTextView.isEditable = false
    resultTextView.isSelectable = true
    resultTextView.isScrollEnabled = true
    resultTextView.textContainerInset = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 44)
    resultTextView.isHidden = true

    copyButton.setTitle("复制", for: .normal)
    copyButton.setTitleColor(ClawPanelPalette.brandBlue, for: .normal)
    copyButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
    copyButton.backgroundColor = ClawPanelPalette.capsuleNormal
    copyButton.layer.cornerRadius = 10
    copyButton.layer.masksToBounds = true
    copyButton.isHidden = true
    copyButton.addTarget(self, action: #selector(copyResultTapped), for: .touchUpInside)

    suggestionStrip.onSend = { text in
      ClawPanelInputBridge.shared.send(text)
    }
    suggestionStrip.onCopy = { text in
      UIPasteboard.general.string = text
      UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    suggestionStrip.isHidden = true

    heartTargetButton.setTitleColor(ClawPanelPalette.deepBlue, for: .normal)
    heartTargetButton.titleLabel?.font = .systemFont(ofSize: 13)
    heartTargetButton.showsMenuAsPrimaryAction = true
    refreshHeartTargetMenu()
  }

  private func setupConstraints() {
    [titleLabel, closeButton, aiWaveContainer, inputRow, resultTextView, copyButton, suggestionStrip, heartTargetButton].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      addSubview($0)
    }
    [inputTextView, micButton, actionButton].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      inputRow.addSubview($0)
    }

    suggestionStripWidthConstraint = suggestionStrip.widthAnchor.constraint(equalToConstant: 0)

    NSLayoutConstraint.activate([
      titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
      closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      closeButton.widthAnchor.constraint(equalToConstant: 26),
      closeButton.heightAnchor.constraint(equalToConstant: 26),

      aiWaveContainer.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
      aiWaveContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      aiWaveContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      aiWaveContainer.heightAnchor.constraint(equalToConstant: 56),

      inputRow.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
      inputRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      inputRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      inputRow.heightAnchor.constraint(equalToConstant: 72),

      inputTextView.topAnchor.constraint(equalTo: inputRow.topAnchor),
      inputTextView.bottomAnchor.constraint(equalTo: inputRow.bottomAnchor),
      inputTextView.leadingAnchor.constraint(equalTo: inputRow.leadingAnchor),

      micButton.leadingAnchor.constraint(equalTo: inputTextView.trailingAnchor, constant: 6),
      micButton.centerYAnchor.constraint(equalTo: inputRow.centerYAnchor),
      micButton.widthAnchor.constraint(equalToConstant: 36),
      micButton.heightAnchor.constraint(equalToConstant: 36),

      actionButton.leadingAnchor.constraint(equalTo: micButton.trailingAnchor, constant: 6),
      actionButton.trailingAnchor.constraint(equalTo: inputRow.trailingAnchor),
      actionButton.centerYAnchor.constraint(equalTo: inputRow.centerYAnchor),
      actionButton.widthAnchor.constraint(equalToConstant: 84),
      actionButton.heightAnchor.constraint(equalToConstant: 40),

      resultTextView.topAnchor.constraint(equalTo: inputRow.bottomAnchor, constant: 8),
      resultTextView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      resultTextView.trailingAnchor.constraint(equalTo: suggestionStrip.leadingAnchor, constant: -8),
      resultTextView.bottomAnchor.constraint(equalTo: heartTargetButton.topAnchor, constant: -8),
      resultTextView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),

      copyButton.topAnchor.constraint(equalTo: resultTextView.topAnchor, constant: 2),
      copyButton.trailingAnchor.constraint(equalTo: resultTextView.trailingAnchor, constant: -4),
      copyButton.widthAnchor.constraint(equalToConstant: 48),
      copyButton.heightAnchor.constraint(equalToConstant: 24),

      suggestionStrip.topAnchor.constraint(equalTo: inputRow.bottomAnchor, constant: 8),
      suggestionStrip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      suggestionStrip.bottomAnchor.constraint(equalTo: heartTargetButton.topAnchor, constant: -8),
      suggestionStripWidthConstraint,

      heartTargetButton.topAnchor.constraint(greaterThanOrEqualTo: resultTextView.bottomAnchor, constant: 8),
      heartTargetButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      heartTargetButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
      heartTargetButton.heightAnchor.constraint(equalToConstant: 22),
    ])
  }

  private func bind() {
    // 聊天对象档案变化时刷新选择菜单
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(heartProfilesDidChange),
      name: .heartTargetProfilesDidChange,
      object: nil
    )

    // 实时建议条跟随建议引擎
    ClawSuggestionEngine.shared.$suggestions
      .receive(on: DispatchQueue.main)
      .sink { [weak self] suggestions in
        guard let self else { return }
        self.suggestionStrip.update(suggestions: suggestions)
        let showStrip = !suggestions.isEmpty && self.keyboardContext.clawPanelTab != PanelTab.ai.rawValue
        self.suggestionStrip.isHidden = !showStrip
        self.suggestionStripWidthConstraint.constant = showStrip ? 140 : 0
        self.layoutIfNeeded()
      }
      .store(in: &subscriptions)
  }

  @objc private func heartProfilesDidChange() {
    DispatchQueue.main.async { [weak self] in
      self?.refreshHeartTargetMenu()
    }
  }

  // MARK: - Tab 刷新

  func refresh(for tab: Int) {
    // 面板配色跟随当前键盘主题
    ClawPanelPalette.sync(with: keyboardContext)
    guard let panelTab = PanelTab(rawValue: tab) else { return }
    let isHelp = panelTab == .helpReply
    let isSuper = panelTab == .superTalk
    aiWaveContainer.isHidden = panelTab != .ai
    inputRow.isHidden = !isHelp && !isSuper
    actionButton.setTitle(isHelp ? "读懂TA" : "优化", for: .normal)
    titleLabel.text = panelTab == .ai ? "AI语音助手" : (isHelp ? "帮你回" : "超会说")
    inputTextView.text = ""
    resultTextView.text = ""
    resultTextView.isHidden = true
    copyButton.isHidden = true
    isListening = false
    isMicHeld = false
    micButton.tintColor = ClawPanelPalette.brandBlue
    if panelTab == .ai {
      startWaveAnimation()
    } else {
      stopWaveAnimation()
    }
  }

  // MARK: - 波形动画（占位）

  private func startWaveAnimation() {
    guard barStack.count == 9 else { return }
    let midY = aiWaveContainer.bounds.midY
    for (index, bar) in barStack.enumerated() {
      let base: CGFloat = 14 + CGFloat((index % 3) * 8)
      bar.frame = CGRect(x: CGFloat(index) * 22, y: midY - base / 2, width: 5, height: base)
      let anim = CABasicAnimation(keyPath: "bounds.size.height")
      anim.fromValue = base
      anim.toValue = base + 22 + CGFloat(index % 4) * 6
      anim.duration = 0.5 + Double(index) * 0.09
      anim.autoreverses = true
      anim.repeatCount = .infinity
      bar.layer.add(anim, forKey: "wave")
    }
  }

  private func stopWaveAnimation() {
    barStack.forEach { $0.layer.removeAnimation(forKey: "wave") }
  }

  // MARK: - 输入框（键盘按键直输）

  /// 键盘按键/候选上屏注入面板输入框
  private func appendTextToInput(_ text: String) {
    let current = inputTextView.text ?? ""
    let selectedRange = inputTextView.selectedRange
    var newText = current
    if selectedRange.location != NSNotFound, selectedRange.length > 0 {
      let ns = newText as NSString
      newText = ns.replacingCharacters(in: selectedRange, with: text)
    } else {
      let ns = newText as NSString
      let location = min(selectedRange.location, ns.length)
      newText = ns.replacingCharacters(in: NSRange(location: location, length: 0), with: text)
    }
    inputTextView.text = newText
    let cursor = (newText as NSString).length
    inputTextView.selectedRange = NSRange(location: cursor, length: 0)
    scrollInputToBottom()
    ClawSuggestionEngine.shared.feed(newText)
  }

  /// 键盘退格 → 面板输入框
  private func deleteLastCharFromInput() {
    let current = inputTextView.text ?? ""
    let ns = current as NSString
    let selectedRange = inputTextView.selectedRange
    var newText: String
    if selectedRange.location != NSNotFound, selectedRange.length > 0 {
      newText = ns.replacingCharacters(in: selectedRange, with: "")
    } else {
      let location = min(selectedRange.location, ns.length)
      guard location > 0 else { return }
      newText = ns.replacingCharacters(in: NSRange(location: location - 1, length: 1), with: "")
    }
    inputTextView.text = newText
    inputTextView.selectedRange = NSRange(location: (newText as NSString).length, length: 0)
    scrollInputToBottom()
    ClawSuggestionEngine.shared.feed(newText)
  }

  private func scrollInputToBottom() {
    let range = NSRange(location: (inputTextView.text as NSString).length, length: 0)
    inputTextView.scrollRangeToVisible(range)
  }

  // MARK: - 交互

  @objc private func closeTapped() {
    keyboardContext.clawPanelTab = -1
  }

  @objc private func actionButtonTapped() {
    guard !isLoading else { return }
    let text = inputTextView.text ?? ""
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      showResultMessage("请先输入或粘贴内容")
      return
    }
    runAnalysis(text: trimmed)
  }

  @objc private func actionButtonLongPressed(_ sender: UILongPressGestureRecognizer) {
    guard sender.state == .began, !isLoading else { return }
    presentPhotoPicker()
  }

  @objc private func micLongPressed(_ sender: UILongPressGestureRecognizer) {
    switch sender.state {
    case .began:
      guard !isListening else { return }
      isMicHeld = true
      startVoiceInput()
    case .ended, .cancelled, .failed:
      isMicHeld = false
      ClawVoiceInputService.shared.stop()
      if isListening {
        isListening = false
        updateMicUI(recording: false)
      }
    default:
      break
    }
  }

  /// 语音输入：按住说话 → STT（zh-Hans）转文字填入输入框
  private func startVoiceInput() {
    ClawVoiceInputService.shared.requestAuthorization { [weak self] granted in
      DispatchQueue.main.async {
        guard let self, self.isMicHeld else { return }
        guard granted else {
          ClawLog.record(module: "键盘面板", "语音权限未授权，无法使用语音输入")
          self.showResultMessage("需要麦克风和语音识别权限，请在系统设置中开启")
          return
        }
        self.isListening = true
        self.updateMicUI(recording: true)
        ClawVoiceInputService.shared.start { [weak self] result in
          DispatchQueue.main.async {
            guard let self else { return }
            self.isListening = false
            self.updateMicUI(recording: false)
            switch result {
            case .success(let text):
              let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
              if !trimmed.isEmpty {
                self.appendTextToInput(trimmed)
              }
            case .failure(let error):
              ClawLog.record(module: "键盘面板", "语音识别失败：\(error.localizedDescription)")
              self.showResultMessage("语音识别失败：\(error.localizedDescription)")
            }
          }
        }
      }
    }
  }

  private func updateMicUI(recording: Bool) {
    micButton.tintColor = recording ? .systemRed : ClawPanelPalette.brandBlue
    let tab = keyboardContext.clawPanelTab
    actionButton.setTitle(recording ? "松开发送…" : (tab == PanelTab.helpReply.rawValue ? "读懂TA" : "优化"), for: .normal)
  }

  /// 读懂TA 长按：上传聊天截图 → 本地 OCR → 文本填入输入框
  private func presentPhotoPicker() {
    var config = PHPickerConfiguration()
    config.filter = .images
    config.selectionLimit = 1
    let picker = PHPickerViewController(configuration: config)
    picker.delegate = self
    guard let vc = clawParentViewController else { return }
    vc.present(picker, animated: true)
  }

  /// AI 分析（读懂TA / 优化），prompt 注入聊天对象档案
  private func runAnalysis(text: String) {
    isLoading = true
    resultTextView.isHidden = false
    resultTextView.text = "分析中…"
    copyButton.isHidden = true
    actionButton.isEnabled = false

    let panelTab = keyboardContext.clawPanelTab
    let profile = HeartTargetService.shared.selectedProfile
    var systemPrompt: String
    if panelTab == 1 {
      systemPrompt = "你是情感沟通助手。请读懂对方的话，帮用户理解对方意图和情绪，并给出针对性的回复建议。保持简洁、有温度。"
    } else {
      systemPrompt = "你是表达优化助手。请帮用户把想说的话优化得更得体、更有说服力，保留原意。"
    }
    if let profile, !profile.bio.isEmpty {
      systemPrompt += "\n聊天对象背景：\(profile.bio)"
    }

    AIService.shared.chat(
      messages: [
        AIMessage(role: "system", content: systemPrompt),
        AIMessage(role: "user", content: text),
      ]
    ) { [weak self] result in
      guard let self else { return }
      self.isLoading = false
      self.actionButton.isEnabled = true
      switch result {
      case .success(let reply):
        self.resultTextView.text = reply
        self.copyButton.isHidden = false
      case .failure(let error):
        ClawLog.record(module: "键盘面板", "AI 分析失败：\(error.localizedDescription)")
        self.resultTextView.text = "分析失败：\(error.localizedDescription)"
      }
    }
  }

  /// 结果区提示消息
  private func showResultMessage(_ message: String) {
    resultTextView.isHidden = false
    resultTextView.text = message
    copyButton.isHidden = true
  }

  @objc private func copyResultTapped() {
    guard let text = resultTextView.text, !text.isEmpty else { return }
    UIPasteboard.general.string = text
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    copyButton.setTitle("已复制", for: .normal)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
      self?.copyButton.setTitle("复制", for: .normal)
    }
  }

  // MARK: - 聊天对象

  private func refreshHeartTargetMenu() {
    let profiles = HeartTargetService.shared.profiles
    let selected = HeartTargetService.shared.selectedProfile?.displayName ?? "未选择"
    heartTargetButton.setTitle("聊天对象：\(selected) ⇄", for: .normal)

    if profiles.isEmpty {
      heartTargetButton.menu = UIMenu(children: [
        UIAction(title: "暂无档案，请到设置添加", attributes: .disabled) { _ in },
      ])
      return
    }
    let actions = profiles.enumerated().map { index, profile in
      UIAction(title: profile.displayName, state: index == HeartTargetService.shared.selectedIndex ? .on : .off) { _ in
        HeartTargetService.shared.select(at: index)
        self.refreshHeartTargetMenu()
      }
    }
    heartTargetButton.menu = UIMenu(children: actions)
  }
}

// MARK: - UITextViewDelegate（键盘按键直输 + 建议触发）

extension ClawPanelOverlayView: UITextViewDelegate {
  public func textViewDidBeginEditing(_ textView: UITextView) {
    keyboardContext.clawPanelInputActive = true
    ClawPanelInputBridge.shared.panelInsert = { [weak self] text in
      self?.appendTextToInput(text)
    }
    ClawPanelInputBridge.shared.panelDelete = { [weak self] in
      self?.deleteLastCharFromInput()
    }
  }

  public func textViewDidEndEditing(_ textView: UITextView) {
    keyboardContext.clawPanelInputActive = false
    ClawPanelInputBridge.shared.panelInsert = nil
    ClawPanelInputBridge.shared.panelDelete = nil
  }

  public func textViewDidChange(_ textView: UITextView) {
    ClawSuggestionEngine.shared.feed(textView.text)
  }
}

// MARK: - PHPickerViewControllerDelegate（上传聊天截图）

extension ClawPanelOverlayView: PHPickerViewControllerDelegate {
  public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let itemProvider = results.first?.itemProvider,
          itemProvider.canLoadObject(ofClass: UIImage.self) else { return }
    itemProvider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
      guard let image = object as? UIImage else { return }
      VisionOCRService.shared.recognizeText(in: image) { result in
        guard let self else { return }
        switch result {
        case .success(let text):
          let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
          if trimmed.isEmpty {
            self.showResultMessage("未识别到文字")
          } else {
            self.appendTextToInput(trimmed)
          }
        case .failure(let error):
          ClawLog.record(module: "键盘面板", "OCR 识别失败：\(error.localizedDescription)")
          self.showResultMessage("识别失败：\(error.localizedDescription)")
        }
      }
    }
  }
}
