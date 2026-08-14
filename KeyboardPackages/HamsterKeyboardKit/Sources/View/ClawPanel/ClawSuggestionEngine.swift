import Combine
import Foundation
import HamsterKit

/// 实时建议引擎：用户打字/语音沟通时，防抖后调用 AI 服务生成 2-3 条简短接话建议。
/// 输出发布到 `suggestions`，由键盘/面板的建议条展示。
public final class ClawSuggestionEngine {
  public static let shared = ClawSuggestionEngine()

  /// 建议内容（最多 3 条）
  @Published public private(set) var suggestions: [String] = []

  /// 总开关（默认开启）
  public var isEnabled = true

  private var debounceWorkItem: DispatchWorkItem?
  private var lastRequestedText = ""
  private var requestInFlight = false

  private init() {}

  /// 投喂最近输入文本（提交上屏 / 面板输入变化 / 语音结果）
  public func feed(_ text: String) {
    guard isEnabled else { return }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    // 隐私模式下不触发 AI 建议
    guard ClawTalkPrivacyService.shared.isCollectionEnabled else { return }
    guard trimmed != lastRequestedText else { return }

    debounceWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      self?.requestSuggestions(for: trimmed)
    }
    debounceWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: workItem)
  }

  /// 清空建议（面板关闭/键盘收起时）
  public func clear() {
    debounceWorkItem?.cancel()
    suggestions = []
  }

  /// 建议被发送后调用：清除当前建议，避免重复发送陈旧内容。
  public func consume(_ text: String) {
    if suggestions.contains(text) {
      suggestions = []
    }
  }

  private func requestSuggestions(for text: String) {
    guard !requestInFlight else { return }
    lastRequestedText = text
    requestInFlight = true

    let systemPrompt = "你是轻量输入助手。请根据用户最近输入的内容，生成 2 条简短、自然、可直接发送的接话建议。每条不超过 12 个字，不要序号，不要引号，用换行符分隔，只输出建议本身。"
    AIService.shared.chat(
      messages: [
        AIMessage(role: "system", content: systemPrompt),
        AIMessage(role: "user", content: text),
      ]
    ) { [weak self] result in
      DispatchQueue.main.async {
        guard let self else { return }
        self.requestInFlight = false
        switch result {
        case .success(let reply):
          let lines = reply
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
          self.suggestions = Array(lines.prefix(3))
        case .failure(let error):
          ClawLog.record(module: "键盘建议", "AI 建议生成失败：\(error.localizedDescription)")
          self.suggestions = []
        }
      }
    }
  }
}
