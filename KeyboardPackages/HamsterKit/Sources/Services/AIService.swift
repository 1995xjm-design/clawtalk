import Foundation

/// 支持的 AI 提供商
public enum AIProvider: String, Codable, CaseIterable {
  case openai      = "OpenAI"
  case openrouter  = "OpenRouter"
  case claude      = "Claude"
  case kimi        = "Kimi"
  case minimax     = "MiniMax"
  case glm         = "GLM"
  case deepseek    = "DeepSeek"

  public var baseURL: String {
    switch self {
    case .openai:     return "https://api.openai.com/v1"
    case .openrouter: return "https://openrouter.ai/api/v1"
    case .claude:     return "https://api.anthropic.com/v1"
    case .kimi:       return "https://api.moonshot.cn/v1"
    case .minimax:    return "https://api.minimax.chat/v1"
    case .glm:        return "https://open.bigmodel.cn/api/paas/v4"
    case .deepseek:   return "https://api.deepseek.com/v1"
    }
  }

  public var defaultModel: String {
    switch self {
    case .openai:     return "gpt-4o"
    case .openrouter: return "openai/gpt-4o"
    case .claude:     return "claude-opus-4-6"
    case .kimi:       return "moonshot-v1-8k"
    case .minimax:    return "abab6.5s-chat"
    case .glm:        return "glm-4-flash"
    case .deepseek:   return "deepseek-chat"
    }
  }

  /// 使用 OpenAI 兼容协议的提供商
  public var isOpenAICompat: Bool { self != .claude }
}

/// AI Prompt 模板
public struct AIPrompt: Codable, Identifiable {
  public let id: UUID
  public var name: String
  public var content: String

  public init(id: UUID = UUID(), name: String, content: String) {
    self.id = id
    self.name = name
    self.content = content
  }
}

/// AI 对话消息
public struct AIMessage: Codable {
  public let role: String   // "user" | "assistant" | "system"
  public let content: String

  public init(role: String, content: String) {
    self.role = role
    self.content = content
  }
}

/// AI Token 用量
public struct AIUsage: Codable {
  public let inputTokens: Int
  public let outputTokens: Int
  public var totalTokens: Int { inputTokens + outputTokens }

  public init(inputTokens: Int, outputTokens: Int) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
  }
}

/// AI 服务 - 统一封装 OpenAI / OpenRouter / Claude API
public class AIService {
  public static let shared = AIService()

  private let defaults = UserDefaults(suiteName: HamsterConstants.appGroupName)

  // MARK: - Config Storage

  public var selectedProvider: AIProvider {
    get {
      let raw = defaults?.string(forKey: "ai_provider") ?? AIProvider.claude.rawValue
      return AIProvider(rawValue: raw) ?? .claude
    }
    set { defaults?.set(newValue.rawValue, forKey: "ai_provider") }
  }

  public var selectedModel: String {
    get { defaults?.string(forKey: "ai_model") ?? selectedProvider.defaultModel }
    set { defaults?.set(newValue, forKey: "ai_model") }
  }

  public func apiKey(for provider: AIProvider) -> String {
    defaults?.string(forKey: "ai_key_\(provider.rawValue)") ?? ""
  }

  public func setApiKey(_ key: String, for provider: AIProvider) {
    defaults?.set(key, forKey: "ai_key_\(provider.rawValue)")
  }

  // MARK: - Prompt Management

  private let promptsKey = "ai_prompts"

  public var savedPrompts: [AIPrompt] {
    get {
      guard let data = defaults?.data(forKey: promptsKey),
            let prompts = try? JSONDecoder().decode([AIPrompt].self, from: data)
      else { return defaultPrompts }
      return prompts
    }
    set {
      defaults?.set(try? JSONEncoder().encode(newValue), forKey: promptsKey)
    }
  }

  private var defaultPrompts: [AIPrompt] {
    [
      AIPrompt(name: "输入习惯分析", content: "请分析以下我的输入记录，总结我的输入习惯、常用词汇、关注话题，并给出洞察：\n\n"),
      AIPrompt(name: "剪贴板内容整理", content: "以下是我最近的剪贴板内容，请帮我整理、分类，提取关键信息：\n\n"),
      AIPrompt(name: "写作风格分析", content: "请分析以下文本样本，描述我的写作风格特点：\n\n"),
      AIPrompt(name: "自由问答", content: ""),
    ]
  }

  public func addPrompt(_ prompt: AIPrompt) {
    var prompts = savedPrompts
    prompts.append(prompt)
    savedPrompts = prompts
  }

  public func updatePrompt(_ prompt: AIPrompt) {
    var prompts = savedPrompts
    if let idx = prompts.firstIndex(where: { $0.id == prompt.id }) {
      prompts[idx] = prompt
    }
    savedPrompts = prompts
  }

  public func deletePrompt(id: UUID) {
    savedPrompts = savedPrompts.filter { $0.id != id }
  }

  // MARK: - ClawTalk 语音助手通道（v049，App Group 共享）

  /// ClawTalk 主 App 写入的语音助手通道配置（App Group "group.7518554"）。
  public struct ClawTalkChannelConfig {
    public let channelRawValue: String
    public let gatewayURL: String
    public let gatewayToken: String
    public let agentID: String
    public let deepSeekConfigured: Bool

    public init(channelRawValue: String, gatewayURL: String, gatewayToken: String, agentID: String, deepSeekConfigured: Bool) {
      self.channelRawValue = channelRawValue
      self.gatewayURL = gatewayURL
      self.gatewayToken = gatewayToken
      self.agentID = agentID
      self.deepSeekConfigured = deepSeekConfigured
    }

    /// 网关是否可用（地址与令牌都非空）
    public var isGatewayUsable: Bool {
      !gatewayURL.isEmpty && !gatewayToken.isEmpty
    }
  }

  /// 读取 ClawTalk 语音助手通道配置（键与主 App SettingsStore.syncGatewayToAppGroup 一致）。
  /// 键盘扩展读不到主 App 的 Keychain（deepseek_api_key），降级规则：
  /// 有网关地址/令牌 → 走网关 OpenAI 兼容通道；否则用本键盘自身 AIProvider 配置兜底。
  public func clawTalkChannelConfig() -> ClawTalkChannelConfig? {
    guard let suite = UserDefaults(suiteName: HamsterConstants.appGroupName) else { return nil }
    let url = suite.string(forKey: "gateway_url") ?? ""
    let token = suite.string(forKey: "gateway_token") ?? ""
    guard !url.isEmpty, !token.isEmpty else { return nil }
    return ClawTalkChannelConfig(
      channelRawValue: suite.string(forKey: "voice_agent_channel") ?? "",
      gatewayURL: url,
      gatewayToken: token,
      agentID: suite.string(forKey: "agent_id") ?? "main",
      deepSeekConfigured: suite.bool(forKey: "deepseek_configured")
    )
  }

  /// 是否可用 ClawTalk 网关通道（键盘 = 语音助手统一通道）。
  public var clawTalkGatewayUsable: Bool {
    clawTalkChannelConfig()?.isGatewayUsable ?? false
  }

  /// 读取主 App 记忆中心导出的个人记忆摘要（clawtalk.memory.summary，JSON 数组）。
  public func clawTalkMemorySummaryText() -> String {
    guard let suite = UserDefaults(suiteName: HamsterConstants.appGroupName),
          let data = suite.data(forKey: "clawtalk.memory.summary"),
          let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    else { return "" }
    let lines = array.compactMap { item -> String? in
      guard let summary = item["summary"] as? String, !summary.isEmpty else { return nil }
      let category = item["category"] as? String ?? ""
      let title = item["title"] as? String ?? ""
      if !title.isEmpty, title != summary {
        return "【\(category)】\(title)：\(summary)"
      }
      return "【\(category)】\(summary)"
    }
    return Array(lines.prefix(30)).joined(separator: "\n")
  }

  /// 读取键盘↔主 App 共享对话（clawtalk.keyboard.chatlog，JSON 数组，最近 100 条）。
  public func clawTalkKeyboardChatLogText(limit: Int = 20) -> String {
    guard let suite = UserDefaults(suiteName: HamsterConstants.appGroupName),
          let data = suite.data(forKey: "clawtalk.keyboard.chatlog"),
          let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    else { return "" }
    let lines = array.compactMap { item -> String? in
      guard let role = item["role"] as? String, let content = item["content"] as? String else { return nil }
      let who = role == "user" ? "我" : "助手"
      return "\(who)：\(content)"
    }
    return Array(lines.suffix(max(limit, 0))).joined(separator: "\n")
  }

  /// 把 App Group 记忆摘要追加到 system prompt（「用户个人背景：…」）。
  private func injectingClawTalkMemory(into messages: [AIMessage]) -> [AIMessage] {
    let background = clawTalkMemorySummaryText()
    guard !background.isEmpty else { return messages }
    let suffix = "\n\n用户个人背景：\n\(background)"
    if let idx = messages.firstIndex(where: { $0.role == "system" }) {
      var updated = messages
      updated[idx] = AIMessage(role: "system", content: messages[idx].content + suffix)
      return updated
    }
    return [AIMessage(role: "system", content: "用户个人背景：\n\(background)")] + messages
  }

  // MARK: - Chat

  /// 发送消息到当前选定的 AI 提供商
  public func chat(
    messages: [AIMessage],
    completion: @escaping (Result<String, Error>) -> Void
  ) {
    chatWithUsage(messages: messages) { result in
      completion(result.map { $0.0 })
    }
  }

  /// 发送消息并返回 token 用量
  public func chatWithUsage(
    messages: [AIMessage],
    completion: @escaping (Result<(String, AIUsage?), Error>) -> Void
  ) {
    // v049 统一通道：主 App 已配置 ClawTalk 网关（App Group 共享）→ 键盘 AI 面板走同一网关；
    // 键盘扩展读不到主 App 的 Keychain（deepseek_api_key），有网关地址/令牌就用网关，
    // 否则回退本键盘自身 AIProvider 配置（默认行为不变）。
    if let channel = clawTalkChannelConfig(), channel.isGatewayUsable {
      chatClawTalkGatewayWithUsage(messages: injectingClawTalkMemory(into: messages), channel: channel, completion: completion)
      return
    }

    let provider = selectedProvider
    let key = apiKey(for: provider)
    guard !key.isEmpty else {
      ClawLog.record(module: "键盘AI", "\(provider.rawValue) API Key 未配置")
      completion(.failure(AIError.noAPIKey(provider)))
      return
    }
    switch provider {
    case .claude:
      chatClaudeWithUsage(messages: injectingClawTalkMemory(into: messages), apiKey: key, completion: completion)
    default:
      chatOpenAICompatWithUsage(messages: injectingClawTalkMemory(into: messages), provider: provider, apiKey: key, completion: completion)
    }
  }

  // MARK: - OpenAI-compatible (OpenAI + OpenRouter)

  private func chatOpenAICompatWithUsage(
    messages: [AIMessage],
    provider: AIProvider,
    apiKey: String,
    completion: @escaping (Result<(String, AIUsage?), Error>) -> Void
  ) {
    let urlString = "\(provider.baseURL)/chat/completions"
    postOpenAICompatRequest(
      urlString: urlString,
      authorization: "Bearer \(apiKey)",
      model: selectedModel,
      label: provider.rawValue,
      messages: messages,
      extraHeaders: provider == .openrouter ? ["X-Title": "ClawTalk iOS"] : [:],
      completion: completion
    )
  }

  /// ClawTalk 统一通道：网关 OpenAI 兼容 /v1/chat/completions（baseURL=网关地址 + /v1）。
  private func chatClawTalkGatewayWithUsage(
    messages: [AIMessage],
    channel: ClawTalkChannelConfig,
    completion: @escaping (Result<(String, AIUsage?), Error>) -> Void
  ) {
    let base = channel.gatewayURL
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let urlString = "\(base)/v1/chat/completions"
    postOpenAICompatRequest(
      urlString: urlString,
      authorization: "Bearer \(channel.gatewayToken)",
      model: "openclaw:\(channel.agentID)",
      label: "ClawTalk网关",
      messages: messages,
      extraHeaders: [:],
      completion: completion
    )
  }

  /// OpenAI 兼容 POST /chat/completions 公共实现（键盘自带提供商与 ClawTalk 网关共用）。
  private func postOpenAICompatRequest(
    urlString: String,
    authorization: String,
    model: String,
    label: String,
    messages: [AIMessage],
    extraHeaders: [String: String],
    completion: @escaping (Result<(String, AIUsage?), Error>) -> Void
  ) {
    guard let url = URL(string: urlString) else {
      ClawLog.record(module: "键盘AI", "AI 请求 URL 无效：\(urlString)")
      DispatchQueue.main.async { completion(.failure(AIError.parseError)) }
      return
    }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue(authorization, forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    for (key, value) in extraHeaders {
      req.setValue(value, forHTTPHeaderField: key)
    }
    let body: [String: Any] = [
      "model": model,
      "messages": messages.map { ["role": $0.role, "content": $0.content] },
      "max_tokens": 4096,
    ]
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)

    let log = LogService.shared
    log.log("→ \(label) \(model) \(urlString) msgs=\(messages.count)", tag: "AI")

    URLSession.shared.dataTask(with: req) { data, response, error in
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      if let error = error {
        log.log("✗ network error: \(error.localizedDescription)", level: .error, tag: "AI")
        ClawLog.record(module: "键盘AI", "AI 网络错误：\(error.localizedDescription)")
        DispatchQueue.main.async { completion(.failure(error)) }; return
      }
      guard let data else {
        log.log("✗ empty response (HTTP \(status))", level: .error, tag: "AI")
        ClawLog.record(module: "键盘AI", "AI 空响应（HTTP \(status)）")
        DispatchQueue.main.async { completion(.failure(AIError.emptyResponse)) }; return
      }
      let rawBody = String(data: data, encoding: .utf8) ?? "<binary>"
      guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        log.log("✗ parse error (HTTP \(status)) body=\(rawBody.prefix(400))", level: .error, tag: "AI")
        ClawLog.record(module: "键盘AI", "AI 解析失败（HTTP \(status)）")
        DispatchQueue.main.async { completion(.failure(AIError.parseError)) }; return
      }
      if let errObj = json["error"] as? [String: Any], let msg = errObj["message"] as? String {
        log.log("✗ API error (HTTP \(status)): \(msg) | raw=\(rawBody.prefix(400))", level: .error, tag: "AI")
        ClawLog.record(module: "键盘AI", "AI API 错误（HTTP \(status)）：\(msg)")
        DispatchQueue.main.async { completion(.failure(AIError.apiError(msg))) }; return
      }
      guard let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
      else {
        log.log("✗ unexpected JSON (HTTP \(status)) body=\(rawBody.prefix(400))", level: .error, tag: "AI")
        ClawLog.record(module: "键盘AI", "AI 响应结构异常（HTTP \(status)）")
        DispatchQueue.main.async { completion(.failure(AIError.parseError)) }; return
      }
      var usage: AIUsage?
      if let usageObj = json["usage"] as? [String: Any] {
        let input = usageObj["prompt_tokens"] as? Int ?? 0
        let output = usageObj["completion_tokens"] as? Int ?? 0
        usage = AIUsage(inputTokens: input, outputTokens: output)
        log.log("✓ OK HTTP \(status) in=\(input) out=\(output)", tag: "AI")
      } else {
        log.log("✓ OK HTTP \(status) (no usage info)", tag: "AI")
      }
      DispatchQueue.main.async { completion(.success((content, usage))) }
    }.resume()
  }

  // MARK: - Claude (Anthropic Messages API)

  private func chatClaudeWithUsage(
    messages: [AIMessage],
    apiKey: String,
    completion: @escaping (Result<(String, AIUsage?), Error>) -> Void
  ) {
    let urlString = "https://api.anthropic.com/v1/messages"
    let url = URL(string: urlString)!
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let systemMsg = messages.first(where: { $0.role == "system" })?.content
    let chatMsgs = messages.filter { $0.role != "system" }
    let model = selectedModel

    var body: [String: Any] = [
      "model": model,
      "max_tokens": 4096,
      "messages": chatMsgs.map { ["role": $0.role, "content": $0.content] },
    ]
    if let sys = systemMsg, !sys.isEmpty { body["system"] = sys }
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)

    let log = LogService.shared
    log.log("→ Claude \(model) \(urlString) msgs=\(messages.count)", tag: "AI")

    URLSession.shared.dataTask(with: req) { data, response, error in
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      if let error = error {
        log.log("✗ network error: \(error.localizedDescription)", level: .error, tag: "AI")
        ClawLog.record(module: "键盘AI", "AI 网络错误：\(error.localizedDescription)")
        DispatchQueue.main.async { completion(.failure(error)) }; return
      }
      guard let data else {
        log.log("✗ empty response (HTTP \(status))", level: .error, tag: "AI")
        ClawLog.record(module: "键盘AI", "AI 空响应（HTTP \(status)）")
        DispatchQueue.main.async { completion(.failure(AIError.emptyResponse)) }; return
      }
      let rawBody = String(data: data, encoding: .utf8) ?? "<binary>"
      guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        log.log("✗ parse error (HTTP \(status)) body=\(rawBody.prefix(400))", level: .error, tag: "AI")
        ClawLog.record(module: "键盘AI", "AI 解析失败（HTTP \(status)）")
        DispatchQueue.main.async { completion(.failure(AIError.parseError)) }; return
      }
      if let errObj = json["error"] as? [String: Any], let msg = errObj["message"] as? String {
        log.log("✗ API error (HTTP \(status)): \(msg) | raw=\(rawBody.prefix(400))", level: .error, tag: "AI")
        ClawLog.record(module: "键盘AI", "AI API 错误（HTTP \(status)）：\(msg)")
        DispatchQueue.main.async { completion(.failure(AIError.apiError(msg))) }; return
      }
      guard let content = json["content"] as? [[String: Any]],
            let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String
      else {
        log.log("✗ unexpected JSON (HTTP \(status)) body=\(rawBody.prefix(400))", level: .error, tag: "AI")
        ClawLog.record(module: "键盘AI", "AI 响应结构异常（HTTP \(status)）")
        DispatchQueue.main.async { completion(.failure(AIError.parseError)) }; return
      }
      var usage: AIUsage?
      if let usageObj = json["usage"] as? [String: Any] {
        let input = usageObj["input_tokens"] as? Int ?? 0
        let output = usageObj["output_tokens"] as? Int ?? 0
        usage = AIUsage(inputTokens: input, outputTokens: output)
        log.log("✓ OK HTTP \(status) in=\(input) out=\(output)", tag: "AI")
      } else {
        log.log("✓ OK HTTP \(status) (no usage info)", tag: "AI")
      }
      DispatchQueue.main.async { completion(.success((text, usage))) }
    }.resume()
  }

  // MARK: - Errors

  public enum AIError: LocalizedError {
    case noAPIKey(AIProvider)
    case emptyResponse
    case parseError
    case apiError(String)

    public var errorDescription: String? {
      switch self {
      case .noAPIKey(let p): return "请先在设置中填入 \(p.rawValue) API Key"
      case .emptyResponse: return "AI 返回了空响应"
      case .parseError: return "解析 AI 响应失败"
      case .apiError(let msg): return "AI API 错误：\(msg)"
      }
    }
  }
}
