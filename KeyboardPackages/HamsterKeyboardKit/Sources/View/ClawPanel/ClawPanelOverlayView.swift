import AVFoundation
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

  // AI 结果「发送」/ 实时通话「结束」/ 波形提示
  private let sendButton = UIButton(type: .system)
  private let endCallButton = UIButton(type: .system)
  private let waveHintLabel = UILabel()

  // 聊天对象
  private let heartTargetButton = UIButton(type: .system)

  // AI 分析状态
  private var isLoading = false
  // 语音状态
  private var isMicHeld = false
  private var isListening = false
  // AI 波形交互状态（短语音 / 实时通话）
  private var isWaveHeld = false
  private var isCallActive = false
  private var callRoundInFlight = false
  private var waveLongPressGesture: UILongPressGestureRecognizer!
  private var wavePanGesture: UIPanGestureRecognizer!
  private var slideStartX: CGFloat?
  private var lastWaveLayoutHeight: CGFloat = 0
  private let speechSynthesizer = AVSpeechSynthesizer()

  private enum WaveStyle {
    case idle
    case recording
    case call
  }
  private var currentWaveStyle: WaveStyle = .idle
  private var currentWaveBaseColor: UIColor = .clear
  private var hasShownVoiceGuide: Bool {
    get { UserDefaults.standard.bool(forKey: "clawtalk.keyboard.voiceGuideShown") }
    set { UserDefaults.standard.set(newValue, forKey: "clawtalk.keyboard.voiceGuideShown") }
  }

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
          self?.endCallMode()
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

    // AI 波形占位（蓝色动态竖条，短语音/实时通话状态切换颜色与幅度）
    for _ in 0..<9 {
      let bar = UIView()
      bar.backgroundColor = ClawPanelPalette.brandBlue
      bar.layer.cornerRadius = 2.5
      bar.autoresizingMask = [.flexibleTopMargin, .flexibleBottomMargin]
      aiWaveContainer.addSubview(bar)
      barStack.append(bar)
    }

    // 波形操作提示 + 实时通话「结束」按钮（悬浮在波形容器内）
    waveHintLabel.font = .systemFont(ofSize: 11, weight: .medium)
    waveHintLabel.textColor = ClawPanelPalette.keyLabel
    waveHintLabel.textAlignment = .center
    waveHintLabel.text = "按住说话 · 右滑进入通话"
    waveHintLabel.isUserInteractionEnabled = false
    waveHintLabel.translatesAutoresizingMaskIntoConstraints = false
    aiWaveContainer.addSubview(waveHintLabel)

    endCallButton.setTitle("结束", for: .normal)
    endCallButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
    endCallButton.setTitleColor(.white, for: .normal)
    endCallButton.backgroundColor = .systemRed
    endCallButton.layer.cornerRadius = 15
    endCallButton.isHidden = true
    endCallButton.addTarget(self, action: #selector(endCallTapped), for: .touchUpInside)
    endCallButton.translatesAutoresizingMaskIntoConstraints = false
    aiWaveContainer.addSubview(endCallButton)

    // 波形手势：按住 = 短语音；按住后右滑 = 进入实时通话（长按与平移同时识别）
    let waveLongPress = UILongPressGestureRecognizer(target: self, action: #selector(waveLongPressed(_:)))
    waveLongPress.minimumPressDuration = 0.25
    waveLongPress.delegate = self
    aiWaveContainer.addGestureRecognizer(waveLongPress)
    waveLongPressGesture = waveLongPress

    let wavePan = UIPanGestureRecognizer(target: self, action: #selector(wavePanned(_:)))
    wavePan.maximumNumberOfTouches = 1
    wavePan.delegate = self
    aiWaveContainer.addGestureRecognizer(wavePan)
    wavePanGesture = wavePan

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
    actionButton.setTitleColor(ClawPanelPalette.currentColors.accentForeground, for: .normal)
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

    sendButton.setTitle("发送", for: .normal)
    sendButton.setTitleColor(ClawPanelPalette.currentColors.accentForeground, for: .normal)
    sendButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
    sendButton.backgroundColor = ClawPanelPalette.brandBlue
    sendButton.layer.cornerRadius = 10
    sendButton.layer.masksToBounds = true
    sendButton.isHidden = true
    sendButton.addTarget(self, action: #selector(sendButtonTapped), for: .touchUpInside)

    suggestionStrip.onSend = { text in
      ClawPanelInputBridge.shared.send(text)
      ClawSuggestionEngine.shared.consume(text)
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
    [titleLabel, closeButton, aiWaveContainer, inputRow, resultTextView, copyButton, sendButton, suggestionStrip, heartTargetButton].forEach {
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

      sendButton.topAnchor.constraint(equalTo: copyButton.topAnchor),
      sendButton.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -6),
      sendButton.widthAnchor.constraint(equalToConstant: 48),
      sendButton.heightAnchor.constraint(equalToConstant: 24),

      suggestionStrip.topAnchor.constraint(equalTo: inputRow.bottomAnchor, constant: 8),
      suggestionStrip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      suggestionStrip.bottomAnchor.constraint(equalTo: heartTargetButton.topAnchor, constant: -8),
      suggestionStripWidthConstraint,

      heartTargetButton.topAnchor.constraint(greaterThanOrEqualTo: resultTextView.bottomAnchor, constant: 8),
      heartTargetButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      heartTargetButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
      heartTargetButton.heightAnchor.constraint(equalToConstant: 22),

      waveHintLabel.centerXAnchor.constraint(equalTo: aiWaveContainer.centerXAnchor),
      waveHintLabel.centerYAnchor.constraint(equalTo: aiWaveContainer.centerYAnchor),

      endCallButton.trailingAnchor.constraint(equalTo: aiWaveContainer.trailingAnchor, constant: -4),
      endCallButton.centerYAnchor.constraint(equalTo: aiWaveContainer.centerYAnchor),
      endCallButton.widthAnchor.constraint(equalToConstant: 64),
      endCallButton.heightAnchor.constraint(equalToConstant: 30),
    ])
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // 波形容器首次布局后按当前状态重绘（bounds 就绪前动画位置无效）
    if !aiWaveContainer.isHidden, aiWaveContainer.bounds.height != lastWaveLayoutHeight {
      lastWaveLayoutHeight = aiWaveContainer.bounds.height
      applyWaveStyle(currentWaveStyle)
    }
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
    // 离开 AI 页签时结束实时通话与波形动画
    if panelTab != .ai {
      endCallMode()
      stopWaveAnimation()
    }
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
    sendButton.isHidden = true
    isListening = false
    isMicHeld = false
    micButton.tintColor = ClawPanelPalette.brandBlue
    if panelTab == .ai {
      endCallButton.isHidden = true
      waveHintLabel.text = "按住说话 · 右滑进入通话"
      waveHintLabel.textColor = ClawPanelPalette.keyLabel
      startWaveAnimation()
    }
  }

  // MARK: - 波形动画（短语音 / 实时通话状态）

  private func startWaveAnimation() {
    applyWaveStyle(.idle)
  }

  private func stopWaveAnimation() {
    barStack.forEach { $0.layer.removeAnimation(forKey: "wave") }
  }

  /// 应用波形视觉状态（颜色/幅度/节奏）
  private func applyWaveStyle(_ style: WaveStyle) {
    guard barStack.count == 9 else { return }
    currentWaveStyle = style
    let midY = aiWaveContainer.bounds.midY
    let color: UIColor
    var baseOffset: CGFloat = 0
    var ampOffset: CGFloat = 0
    var durationScale: Double = 1
    switch style {
    case .idle:
      color = ClawPanelPalette.brandBlue
    case .recording:
      color = .systemOrange
      baseOffset = 6
      ampOffset = 12
      durationScale = 0.7
    case .call:
      color = .systemGreen
      baseOffset = 10
      ampOffset = 18
      durationScale = 0.6
    }
    currentWaveBaseColor = color
    for (index, bar) in barStack.enumerated() {
      let base: CGFloat = 14 + CGFloat((index % 3) * 8) + baseOffset
      bar.backgroundColor = color
      bar.frame = CGRect(x: CGFloat(index) * 22, y: midY - base / 2, width: 5, height: base)
      bar.layer.removeAnimation(forKey: "wave")
      let anim = CABasicAnimation(keyPath: "bounds.size.height")
      anim.fromValue = base
      anim.toValue = base + 22 + CGFloat(index % 4) * 6 + ampOffset
      anim.duration = (0.5 + Double(index) * 0.09) * durationScale
      anim.autoreverses = true
      anim.repeatCount = .infinity
      bar.layer.add(anim, forKey: "wave")
    }
  }

  /// 按住波形后的实时录音视觉反馈
  private func updateWaveHoldUI(holding: Bool) {
    applyWaveStyle(holding ? .recording : .idle)
    waveHintLabel.text = holding ? "松开转文字…" : "按住说话 · 右滑进入通话"
  }

  /// 右滑进度反馈：波形由当前色渐变为通话绿
  private func updateWaveSlideProgress(_ progress: CGFloat) {
    let clamped = min(max(progress, 0), 1)
    guard barStack.count == 9 else { return }
    let mixed = mixedColor(currentWaveBaseColor, UIColor.systemGreen, clamped)
    barStack.forEach { $0.backgroundColor = mixed }
    waveHintLabel.text = clamped > 0.02 ? "继续右滑进入通话…" : "按住说话 · 右滑进入通话"
    waveHintLabel.textColor = clamped > 0.5 ? UIColor.systemGreen : ClawPanelPalette.keyLabel
  }

  private func resetWaveSlideProgress() {
    if isCallActive { return }
    updateWaveHoldUI(holding: isWaveHeld)
  }

  /// 两色线性混合（波形滑动过渡用）
  private func mixedColor(_ a: UIColor, _ b: UIColor, _ t: CGFloat) -> UIColor {
    var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
    var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
    a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
    b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
    return UIColor(
      red: r1 + (r2 - r1) * t,
      green: g1 + (g2 - g1) * t,
      blue: b1 + (b2 - b1) * t,
      alpha: a1 + (a2 - a1) * t
    )
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
    requestVoicePermissionAndGuide { [weak self] granted in
      DispatchQueue.main.async {
        guard let self, self.isMicHeld else { return }
        guard granted else {
          ClawLog.record(module: "键盘面板", "语音权限未授权，无法使用语音输入")
          self.showResultMessage("需要麦克风和语音识别权限，请在系统设置中开启")
          self.presentPermissionDeniedAlert()
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

  // MARK: - AI 波形交互（短语音 / 实时通话）

  @objc private func waveLongPressed(_ sender: UILongPressGestureRecognizer) {
    switch sender.state {
    case .began:
      guard !isCallActive, !isLoading, keyboardContext.clawPanelTab == PanelTab.ai.rawValue else { return }
      isWaveHeld = true
      slideStartX = wavePanGesture?.translation(in: aiWaveContainer).x
      updateWaveHoldUI(holding: true)
      startWaveVoiceInput()
    case .ended, .cancelled, .failed:
      isWaveHeld = false
      slideStartX = nil
      ClawVoiceInputService.shared.stop()
      updateWaveHoldUI(holding: false)
    default:
      break
    }
  }

  @objc private func wavePanned(_ sender: UIPanGestureRecognizer) {
    guard keyboardContext.clawPanelTab == PanelTab.ai.rawValue, !isCallActive else { return }
    let longPressActive = waveLongPressGesture?.state == .began || waveLongPressGesture?.state == .changed
    switch sender.state {
    case .began, .changed:
      guard longPressActive, isWaveHeld, let startX = slideStartX else { return }
      let translation = sender.translation(in: aiWaveContainer)
      let progress = (translation.x - startX) / 80
      updateWaveSlideProgress(progress)
      if progress >= 1 {
        sender.state = .ended
        enterCallMode()
      }
    case .ended, .cancelled, .failed:
      slideStartX = nil
      resetWaveSlideProgress()
    default:
      break
    }
  }

  /// 短语音：按住波形说话 → STT → AI 聊天 → 文字/朗读回复
  private func startWaveVoiceInput() {
    requestVoicePermissionAndGuide { [weak self] granted in
      DispatchQueue.main.async {
        guard let self, self.isWaveHeld, !self.isCallActive else { return }
        guard granted else {
          self.updateWaveHoldUI(holding: false)
          self.showResultMessage("需要麦克风和语音识别权限，请在系统设置中开启")
          self.presentPermissionDeniedAlert()
          return
        }
        self.updateWaveHoldUI(holding: true)
        ClawVoiceInputService.shared.start { [weak self] result in
          DispatchQueue.main.async {
            guard let self else { return }
            self.updateWaveHoldUI(holding: false)
            switch result {
            case .success(let text):
              let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
              guard !trimmed.isEmpty else {
                self.showResultMessage("没有听清，请按住波形再试一次")
                return
              }
              self.runWaveChat(userText: trimmed)
            case .failure(let error):
              ClawLog.record(module: "键盘面板", "语音识别失败：\(error.localizedDescription)")
              self.showResultMessage("语音识别失败：\(error.localizedDescription)")
            }
          }
        }
      }
    }
  }

  /// AI 语音聊天（短语音与实时通话共用，callMode 控制通话循环）
  private func runWaveChat(userText: String, callMode: Bool = false) {
    if callMode { callRoundInFlight = true }
    isLoading = true
    resultTextView.isHidden = false
    resultTextView.text = "思考中…"
    copyButton.isHidden = true
    sendButton.isHidden = true
    waveHintLabel.text = "AI 思考中…"

    let profile = HeartTargetService.shared.selectedProfile
    var systemPrompt = "你是 ClawTalk 语音助手，用自然、简短、口语化的中文直接回答，不要序号，不要标题。"
    if let profile, !profile.bio.isEmpty {
      systemPrompt += "\n聊天对象背景：\(profile.bio)"
    }
    let recentChat = AIService.shared.clawTalkKeyboardChatLogText(limit: 20)
    if !recentChat.isEmpty {
      systemPrompt += "\n近期对话（供上下文参考）：\n\(recentChat)"
    }

    AIService.shared.chat(
      messages: [
        AIMessage(role: "system", content: systemPrompt),
        AIMessage(role: "user", content: userText),
      ]
    ) { [weak self] result in
      guard let self else { return }
      self.isLoading = false
      switch result {
      case .success(let reply):
        guard !callMode || self.isCallActive else { return }
        self.resultTextView.text = reply
        self.copyButton.isHidden = false
        self.sendButton.isHidden = false
        self.absorbConversation(userText: userText, replyText: reply)
        self.speakReply(reply, callMode: callMode)
      case .failure(let error):
        ClawLog.record(module: "键盘面板", "AI 语音回复失败：\(error.localizedDescription)")
        self.resultTextView.text = "回复失败：\(error.localizedDescription)"
        if callMode, self.isCallActive {
          self.callRoundInFlight = false
          self.restartCallTurn(after: 1.0)
        }
      }
    }
  }

  // MARK: - 实时通话（按住波形后右滑进入）

  private func enterCallMode() {
    guard !isCallActive else { return }
    isCallActive = true
    isWaveHeld = false
    slideStartX = nil
    ClawVoiceInputService.shared.stop()
    endCallButton.isHidden = false
    waveHintLabel.text = "实时通话中…"
    waveHintLabel.textColor = UIColor.systemGreen
    applyWaveStyle(.call)
    // 吸附动画 + 触感反馈
    let snap = CAKeyframeAnimation(keyPath: "transform.scale")
    snap.values = [1.0, 1.12, 0.97, 1.0]
    snap.keyTimes = [0, 0.3, 0.65, 1]
    snap.duration = 0.35
    aiWaveContainer.layer.add(snap, forKey: "callSnap")
    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    showResultMessage("已进入实时通话 · 直接说话即可，点击「结束」退出")
    startCallTurn()
  }

  private func startCallTurn() {
    guard isCallActive, !callRoundInFlight else { return }
    requestVoicePermissionAndGuide { [weak self] granted in
      DispatchQueue.main.async {
        guard let self, self.isCallActive else { return }
        guard granted else {
          self.endCallMode()
          self.showResultMessage("需要麦克风和语音识别权限，请在系统设置中开启")
          self.presentPermissionDeniedAlert()
          return
        }
        self.callRoundInFlight = true
        self.resultTextView.isHidden = false
        self.resultTextView.text = "请说话…"
        ClawVoiceInputService.shared.startTurn(
          partialHandler: { [weak self] partial in
            DispatchQueue.main.async {
              guard let self, self.isCallActive else { return }
              if !partial.isEmpty { self.resultTextView.text = partial }
            }
          },
          onFinal: { [weak self] result in
            DispatchQueue.main.async {
              guard let self else { return }
              self.callRoundInFlight = false
              guard self.isCallActive else { return }
              switch result {
              case .success(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                  self.restartCallTurn(after: 0.5)
                } else {
                  self.runCallChat(userText: trimmed)
                }
              case .failure(let error):
                ClawLog.record(module: "键盘面板", "通话语音识别失败：\(error.localizedDescription)")
                self.resultTextView.text = "识别失败：\(error.localizedDescription)"
                self.restartCallTurn(after: 1.2)
              }
            }
          }
        )
      }
    }
  }

  private func runCallChat(userText: String) {
    runWaveChat(userText: userText, callMode: true)
  }

  private func finishCallRound() {
    callRoundInFlight = false
    restartCallTurn(after: 0.2)
  }

  private func restartCallTurn(after delay: TimeInterval) {
    guard isCallActive else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self, self.isCallActive, !self.callRoundInFlight else { return }
      self.startCallTurn()
    }
  }

  @objc private func endCallTapped() {
    endCallMode()
  }

  private func endCallMode() {
    guard isCallActive else { return }
    isCallActive = false
    callRoundInFlight = false
    ClawVoiceInputService.shared.stop()
    speechSynthesizer.stopSpeaking(at: .immediate)
    endCallButton.isHidden = true
    aiWaveContainer.layer.removeAnimation(forKey: "callSnap")
    waveHintLabel.text = "按住说话 · 右滑进入通话"
    waveHintLabel.textColor = ClawPanelPalette.keyLabel
    applyWaveStyle(.idle)
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    showResultMessage("通话已结束")
  }

  /// 朗读 AI 回复（callMode = 通话循环，朗读完成后自动开始下一轮）
  private func speakReply(_ text: String, callMode: Bool = false) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      if callMode { finishCallRound() }
      return
    }
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
      try session.setActive(true, options: .notifyOthersOnDeactivation)
    } catch {
      ClawLog.record(module: "键盘面板", "朗读音频会话设置失败：\(error.localizedDescription)")
      if callMode { finishCallRound() }
      return
    }
    if callMode { waveHintLabel.text = "AI 回复中…" }
    let utterance = AVSpeechUtterance(string: trimmed)
    utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate
    speechSynthesizer.delegate = self
    speechSynthesizer.speak(utterance)
  }

  // MARK: - 语音权限引导（首次使用）

  private func requestVoicePermissionAndGuide(completion: @escaping (Bool) -> Void) {
    if !hasShownVoiceGuide {
      hasShownVoiceGuide = true
      presentVoiceGuideAlert { [weak self] in
        guard let self else { return }
        ClawVoiceInputService.shared.requestAuthorization(completion: completion)
      }
      return
    }
    ClawVoiceInputService.shared.requestAuthorization(completion: completion)
  }

  private func presentVoiceGuideAlert(afterContinue: @escaping () -> Void) {
    guard let vc = clawParentViewController else {
      afterContinue()
      return
    }
    let alert = UIAlertController(
      title: "语音助手使用引导",
      message: "按住蓝色波形说话，松开后自动转文字并由 AI 回复；按住后向右滑动即可进入「实时通话」，通话中点击「结束」退出。首次使用需要麦克风和语音识别权限，仅用于语音输入。",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "知道了", style: .default) { _ in afterContinue() })
    vc.present(alert, animated: true)
  }

  private func presentPermissionDeniedAlert() {
    guard let vc = clawParentViewController else { return }
    let alert = UIAlertController(
      title: "需要麦克风与语音识别权限",
      message: "请在系统设置中允许 ClawTalk 使用「麦克风」和「语音识别」，然后重新打开键盘重试。",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "知道了", style: .default))
    vc.present(alert, animated: true)
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
        self.sendButton.isHidden = false
        // v049：对话记忆沉淀（当前聊天对象档案）+ 共享对话写入 App Group（供主 App 续聊）
        self.absorbConversation(userText: text, replyText: reply)
      case .failure(let error):
        ClawLog.record(module: "键盘面板", "AI 分析失败：\(error.localizedDescription)")
        self.resultTextView.text = "分析失败：\(error.localizedDescription)"
      }
    }
  }

  /// 键盘 AI 对话记忆沉淀（v049）：
  /// ① 本轮 user+assistant 追加到当前选中聊天对象档案记忆；
  /// ② 同时写入 App Group 共享对话文件（clawtalk.keyboard.chatlog，JSON 数组最近 100 条）。
  private func absorbConversation(userText: String, replyText: String) {
    let trimmedUser = userText.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedReply = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedUser.isEmpty, !trimmedReply.isEmpty else { return }
    if let profileID = HeartTargetService.shared.selectedProfile?.id {
      HeartTargetService.shared.appendMemory(to: profileID, "我：\(trimmedUser)\n助手：\(trimmedReply)")
    }
    Self.appendKeyboardChatLog(user: trimmedUser, assistant: trimmedReply)
  }

  /// 共享对话文件：App Group "clawtalk.keyboard.chatlog"，JSON 数组，最多 100 条。
  private static let keyboardChatLogKey = "clawtalk.keyboard.chatlog"
  private static let keyboardChatLogMaxCount = 100

  private static func appendKeyboardChatLog(user: String, assistant: String) {
    guard let defaults = UserDefaults(suiteName: HamsterConstants.appGroupName) else { return }
    struct ChatLogEntry: Codable {
      let role: String
      let content: String
      let timestamp: Date
    }
    var entries: [ChatLogEntry] = []
    if let data = defaults.data(forKey: keyboardChatLogKey),
       let decoded = try? JSONDecoder().decode([ChatLogEntry].self, from: data) {
      entries = decoded
    }
    entries.append(ChatLogEntry(role: "user", content: user, timestamp: Date()))
    entries.append(ChatLogEntry(role: "assistant", content: assistant, timestamp: Date()))
    if entries.count > keyboardChatLogMaxCount {
      entries = Array(entries.suffix(keyboardChatLogMaxCount))
    }
    defaults.set(try? JSONEncoder().encode(entries), forKey: keyboardChatLogKey)
  }

  /// 结果区提示消息
  private func showResultMessage(_ message: String) {
    resultTextView.isHidden = false
    resultTextView.text = message
    copyButton.isHidden = true
    sendButton.isHidden = true
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

  /// 面板「发送」：把当前结果写入外部输入框（textDocumentProxy）
  @objc private func sendButtonTapped() {
    guard let text = resultTextView.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
    ClawPanelInputBridge.shared.send(text)
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
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

// MARK: - UIGestureRecognizerDelegate（波形长按 + 右滑同时识别）

extension ClawPanelOverlayView: UIGestureRecognizerDelegate {
  public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
    true
  }
}

// MARK: - AVSpeechSynthesizerDelegate（实时通话朗读完成续接）

extension ClawPanelOverlayView: AVSpeechSynthesizerDelegate {
  public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    DispatchQueue.main.async { [weak self] in
      guard let self, self.isCallActive else { return }
      self.finishCallRound()
    }
  }

  public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    DispatchQueue.main.async { [weak self] in
      guard let self, self.isCallActive else { return }
      self.finishCallRound()
    }
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
