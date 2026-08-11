import Foundation
import SwiftUI
import UIKit

enum ChatState: Equatable {
    case idle
    case recording
    case transcribing
    case thinking
    case streaming
    case speaking
}

@Observable
@MainActor
final class ChatViewModel {
    var messages: [Message] = []
    var state: ChatState = .idle {
        didSet {
            guard oldValue != state else { return }
            // 锁屏/灵动岛状态：仅免提对话模式期间存在 Live Activity
            if isConversationMode {
                ClawTalkLiveActivity.update(statusText: Self.liveActivityStatus(for: state))
            }
        }
    }
    var errorMessage: String? {
        didSet { if let errorMessage { LogCollector.record(module: "聊天", errorMessage) } }
    }
    var isConversationMode = false {
        didSet {
            guard oldValue != isConversationMode else { return }
            if isConversationMode {
                ClawTalkLiveActivity.start(
                    channelName: channel.name,
                    initialStatus: Self.liveActivityStatus(for: state)
                )
            } else {
                ClawTalkLiveActivity.endAll()
            }
        }
    }
    var channel: Channel
    /// 页面是否在前台（退出聊天页后置 false：任务继续在后台跑，完成后由 App 层发通知）。
    var isVisible = true
    /// 一次 run 结束后的回调（vm、是否成功、回复摘要 snippet；失败时 snippet 为错误文案）。
    var onRunFinished: (@MainActor (ChatViewModel, Bool, String?) -> Void)?
    private let openClaw = OpenClawClient()
    private let audioCapture = AudioCaptureManager()
    private let audioPlayback = AudioPlaybackManager()
    private let conversationStore = ConversationStore.shared
    private(set) var settings: SettingsStore
    private var channelStore: ChannelStore?
    private var gatewayConnection: GatewayConnection?
    private var transcriptionService: (any TranscriptionService)?
    private var speechService: (any SpeechService)?
    private var sendTask: Task<Void, Never>?
    private var recordingStart: Date?
    private var currentRunId: String?
    private var currentEventSubId: UUID?
    private var ttsStopped = false
    private let ttsConcurrency = TTSConcurrency()
    /// 网关是否支持语音附件（audio 类型）上传。默认 false：OpenClaw 网关语音附件支持未确认，
    /// 语音消息按「录音 → STT → 发文字」降级发送并诚实标注；主智能体确认网关支持后置 true，
    /// WebSocket 发送将带上 attachments(audio/wav) 上传。
    var voiceAttachmentTransportSupported = false

    /// 语音消息附件索引：Message.id → 附件（本地文件 + 元数据），消息气泡据此渲染语音 UI。
    private(set) var voiceAttachments: [UUID: VoiceMessageAttachment] = [:]
    /// 正在录制语音消息（输入区「语音消息」按钮按住期间）。
    private(set) var isRecordingVoiceMessage = false

    /// Stable session key for this channel, used for server-side session management.
    var sessionKey: String {
        if let external = channel.serverSessionKey, !external.isEmpty {
            return external
        }
        let base = "agent:\(channel.agentId):clawtalk-user:\(openClaw.deviceID):\(channel.id.uuidString.prefix(8).lowercased())"
        return channel.sessionVersion > 0 ? "\(base)-v\(channel.sessionVersion)" : base
    }

    init(settings: SettingsStore, channel: Channel, channelStore: ChannelStore? = nil, gatewayConnection: GatewayConnection? = nil) {
        self.settings = settings
        self.channel = channel
        self.channelStore = channelStore
        self.gatewayConnection = gatewayConnection
        self.messages = conversationStore.load(channelId: channel.id)
    }

    // MARK: - Voice Input

    func startRecording() {
        guard state == .idle else { return }
        // 按住说话与语音唤醒共用麦克风：录音前先停唤醒监听，避免两个音频引擎抢麦
        VoiceWakeCapability.shared.stopListening()
        errorMessage = nil
        do {
            try audioCapture.startRecording()
            recordingStart = Date()
            state = .recording
        } catch {
            errorMessage = "麦克风访问失败：\(AppErrorText.localized(error.localizedDescription))"
        }
    }

    func stopRecordingAndSend(images: [Data] = []) {
        guard state == .recording, !isRecordingVoiceMessage else { return }
        if isConversationMode { return }

        let samples = audioCapture.stopRecording()

        // Ignore recordings shorter than 0.5s (accidental taps)
        let duration = Date().timeIntervalSince(recordingStart ?? Date())
        guard duration >= 0.5, samples.count > 8000 else {
            state = .idle
            // 误触取消：麦克风已释放，恢复唤醒监听
            NotificationCenter.default.post(name: .clawTalkWakeRestartRequested, object: nil)
            return
        }

        state = .transcribing

        sendTask = Task {
            do {
                guard let stt = transcriptionService else {
                    throw ChatError.notConfigured("语音转文字服务未初始化")
                }

                let transcript: String
                if let doubao = stt as? DoubaoSTTService {
                    transcript = try await doubao.finishStreaming()
                } else {
                    transcript = try await stt.transcribe(audioSamples: samples)
                }
                guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    state = .idle
                    // Mic released without a transcript: restore wake listening
                    NotificationCenter.default.post(name: .clawTalkWakeRestartRequested, object: nil)
                    return
                }

                await sendMessage(transcript, images: images.isEmpty ? nil : images)
            } catch {
                errorMessage = "转写失败：\(AppErrorText.localized(error.localizedDescription))"
                state = .idle
            }
            // 录音发送流程结束（成功或失败）：麦克风已释放，恢复唤醒监听
            NotificationCenter.default.post(name: .clawTalkWakeRestartRequested, object: nil)
        }
    }

    // MARK: - 语音消息（按住录音 → 松开发送）

    /// 开始录制语音消息（与按住说话共用麦克风，录音前先停唤醒监听）。
    func startVoiceMessageRecording() {
        guard state == .idle, !isConversationMode else { return }
        VoiceWakeCapability.shared.stopListening()
        errorMessage = nil
        do {
            try audioCapture.startRecording()
            recordingStart = Date()
            isRecordingVoiceMessage = true
            state = .recording
        } catch {
            errorMessage = "麦克风访问失败：\(AppErrorText.localized(error.localizedDescription))"
        }
    }

    /// 停止录音并发送语音消息：本地存 WAV → STT 转文字 → 按网关支持情况发送。
    func stopVoiceMessageRecordingAndSend() {
        guard isRecordingVoiceMessage, state == .recording else { return }
        isRecordingVoiceMessage = false

        let samples = audioCapture.stopRecording()
        // 误触（<0.5s）取消：此时文件尚未保存，直接恢复
        let duration = Date().timeIntervalSince(recordingStart ?? Date())
        guard duration >= 0.5, samples.count > 8000 else {
            state = .idle
            NotificationCenter.default.post(name: .clawTalkWakeRestartRequested, object: nil)
            return
        }

        state = .transcribing
        sendTask = Task {
            defer {
                // 录音发送流程结束（成功或失败）：麦克风已释放，恢复唤醒监听
                NotificationCenter.default.post(name: .clawTalkWakeRestartRequested, object: nil)
            }
            do {
                guard let stt = transcriptionService else {
                    throw ChatError.notConfigured("语音转文字服务未初始化")
                }

                let transcript: String
                if let doubao = stt as? DoubaoSTTService {
                    transcript = try await doubao.finishStreaming()
                } else {
                    transcript = try await stt.transcribe(audioSamples: samples)
                }
                guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    state = .idle
                    return
                }

                // 语音文件本地存档（WAV 16kHz），消息带附件标记；网关未确认支持语音附件时
                // 附件仅本地回放，消息按文字发送（诚实标注 sentAsText）。
                var attachment = try VoiceMessageFileStore.save(
                    samples: samples,
                    duration: duration,
                    transcript: transcript
                )
                attachment.sentAsText = !voiceAttachmentTransportSupported
                await sendMessage(transcript, voiceAttachment: attachment)
            } catch {
                errorMessage = "语音消息发送失败：\(AppErrorText.localized(error.localizedDescription))"
                state = .idle
            }
        }
    }

    /// 取某条消息的语音附件（无则返回 nil，气泡按普通文本渲染）。
    func voiceAttachment(for messageID: UUID) -> VoiceMessageAttachment? {
        voiceAttachments[messageID]
    }

    // MARK: - Text Input

    func sendText(_ text: String, images: [Data] = []) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else { return }
        // 允许在语音播放/流式回复时发送新消息：先打断当前语音和正在进行的回复
        if state == .speaking || state == .streaming {
            // 取消上一条正在跑的发送任务，避免新旧发送任务并发导致「发下一句不接话」
            sendTask?.cancel()
            ttsStopped = true
            ttsConcurrency.cancelAll()
            speechService?.stop()
            audioPlayback.stop()
            abortCurrentRun()
        }
        guard state == .idle || state == .speaking || state == .streaming else { return }
        errorMessage = nil

        // Debug: /testimage sends a tiny red pixel to test image pipeline
        if text.trimmingCharacters(in: .whitespacesAndNewlines) == "/testimage" {
            let testImage = Self.makeTestImage()
            sendTask = Task {
                await sendMessage("What do you see in this image?", images: [testImage])
            }
            return
        }

        sendTask = Task {
            await sendMessage(text, images: images.isEmpty ? nil : images)
        }
    }

    private static func makeTestImage() -> Data {
        let size = CGSize(width: 100, height: 100)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            // Draw a simple white circle
            UIColor.white.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 25, y: 25, width: 50, height: 50))
        }
        return image.jpegData(compressionQuality: 0.8) ?? Data()
    }

    // MARK: - Conversation Mode

    func enterConversationMode() {
        guard state == .idle else { return }
        errorMessage = nil
        // 语音唤醒与免提对话共用麦克风：进对话前先停唤醒监听，避免音频引擎冲突
        VoiceWakeCapability.shared.stopListening()

        do {
            try audioCapture.startRecording()
            state = .recording
        } catch {
            LogCollector.record(module: "语音对话", "语音对话模式启动失败：\(AppErrorText.localized(error.localizedDescription))")
            errorMessage = "麦克风访问失败：\(AppErrorText.localized(error.localizedDescription))"
            return
        }

        isConversationMode = true

        // 豆包 STT：实时识别（边说边送）；其他提供商保持整段识别
        if let doubao = transcriptionService as? DoubaoSTTService {
            Task {
                do { try await doubao.startStreaming() }
                catch {
                    LogCollector.record(module: "语音对话", "语音对话模式实时识别启动失败：\(AppErrorText.localized(error.localizedDescription))")
                }
            }
        }
        audioCapture.enableVAD(
            onUtterance: { [weak self] samples in
                Task { @MainActor in
                    self?.handleConversationUtterance(samples)
                }
            },
            onAudioChunk: { [weak self] chunk in
                Task { try? await (self?.transcriptionService as? DoubaoSTTService)?.feedStreaming(samples: chunk) }
            },
            onInterrupt: { [weak self] in
                Task { @MainActor in
                    self?.handleConversationInterrupt()
                }
            }
        )
    }

    func exitConversationMode() {
        isConversationMode = false
        // 不取消在跑任务：退出免提后让当前回复继续完成（完成后由 App 层决定是否发通知）
        ttsConcurrency.cancelAll()
        (transcriptionService as? DoubaoSTTService)?.cancelStreaming()
        audioCapture.stopContinuousRecording()
        speechService?.stop()
        audioPlayback.stop()

        if let idx = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
            messages[idx].isStreaming = false
        }

        state = .idle
        conversationStore.save(messages, channelId: channel.id)
    }

    private func handleConversationUtterance(_ samples: [Float]) {
        guard isConversationMode else { return }

        audioCapture.pauseListening()
        state = .transcribing

        sendTask = Task {
            do {
                guard let stt = transcriptionService else {
                    throw ChatError.notConfigured("语音转文字服务未初始化")
                }

                let transcript: String
                if let doubao = stt as? DoubaoSTTService {
                    transcript = try await doubao.finishStreaming()
                } else {
                    transcript = try await stt.transcribe(audioSamples: samples)
                }
                guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    if isConversationMode {
                        audioCapture.resumeListening()
                        state = .recording
                    }
                    return
                }

                await sendMessage(transcript)
            } catch is CancellationError {
                // Interrupted - don't change state
            } catch {
                errorMessage = "转写失败：\(AppErrorText.localized(error.localizedDescription))"
                if isConversationMode {
                    audioCapture.resumeListening()
                    state = .recording
                } else {
                    state = .idle
                }
            }
        }
    }

    private func handleConversationInterrupt() {
        guard isConversationMode else { return }
        guard state == .speaking || state == .streaming else { return }

        sendTask?.cancel()
        audioPlayback.duckVolume()
        ttsConcurrency.cancelAll()
        speechService?.stop()
        audioPlayback.stop()

        if let idx = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
            messages[idx].isStreaming = false
        }

        audioCapture.resumeListening()
        state = .recording
    }

    // MARK: - Core Send Flow

    private func sendMessage(_ content: String, images: [Data]? = nil, voiceAttachment: VoiceMessageAttachment? = nil) async {
        let userMessage = Message(role: .user, content: content, imageData: images)
        messages.append(userMessage)
        if let voiceAttachment {
            voiceAttachments[userMessage.id] = voiceAttachment
        }
        let userID = userMessage.id

        let assistantMessage = Message(role: .assistant, content: "", isStreaming: true)
        messages.append(assistantMessage)
        let assistantID = assistantMessage.id

        ttsStopped = false
        ttsConcurrency.cancelAll()
        state = .thinking

        // 本次 run 的收尾状态：用于判定是否触发「后台完成」通知（有产出或出错才触发）
        var runFailed = false
        var runErrorText: String?
        var runCancelled = false

        do {
            guard settings.isConfigured else {
                throw ChatError.notConfigured("请在设置中配置你的 OpenClaw 网关。")
            }

            if settings.settings.useWebSocket, let gateway = gatewayConnection,
               gateway.connectionState == .connected {
                do {
                    try await sendMessageViaWebSocket(content, images: images, audioAttachment: voiceAttachment, gateway: gateway)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // WebSocket failed mid-stream — fall back to HTTP
                    // Remove the partial assistant message if empty
                    if let idx = messages.firstIndex(where: { $0.id == assistantID }) {
                        if messages[idx].content.isEmpty {
                            messages.remove(at: idx)
                        } else {
                            // Keep partial response, don't retry
                            messages[idx].isStreaming = false
                            throw error
                        }
                    }
                    // Retry via HTTP (reuse original id so cancellation cleanup still finds it)
                    let retryAssistant = Message(id: assistantID, role: .assistant, content: "", isStreaming: true)
                    messages.append(retryAssistant)
                    try await sendMessageViaHTTP(images: images)
                }
            } else {
                try await sendMessageViaHTTP(images: images)
            }

            notifySuccess()

            if isConversationMode {
                audioCapture.resumeListening()
                state = .recording
            } else {
                state = .idle
            }
            conversationStore.save(messages, channelId: channel.id)

        } catch is CancellationError {
            // Finalize only this task's own message by id, never a newer task's message
            runCancelled = true
            if let idx = messages.firstIndex(where: { $0.id == assistantID }) {
                messages[idx].isStreaming = false
            }
            audioPlayback.stop()
            conversationStore.save(messages, channelId: channel.id)
        } catch {
            let isCancellation = (error as? URLError)?.code == .cancelled
            let classified = ChatError.classify(error)
            runCancelled = isCancellation
            runFailed = !isCancellation
            runErrorText = isCancellation ? nil : classified.errorDescription
            if let idx = messages.firstIndex(where: { $0.id == assistantID }) {
                messages[idx].isStreaming = false
                if messages[idx].content.isEmpty {
                    messages.remove(at: idx)
                }
            }
            if !isCancellation {
                // Tag the user message with the error for retry
                if let userIdx = messages.firstIndex(where: { $0.id == userID }) {
                    messages[userIdx].sendError = classified.errorDescription
                }
                audioPlayback.stop()
                errorMessage = classified.errorDescription
                notifyError()
            } else {
                // Cancellation surfaced as URLError.cancelled: finalize silently
                audioPlayback.stop()
            }

            if isConversationMode {
                audioCapture.resumeListening()
                state = .recording
            } else {
                state = .idle
            }
            conversationStore.save(messages, channelId: channel.id)
        }

        // 收尾回调：仅当本次 run 有产出（assistant 内容非空）或出错时触发，避免空转触发；
        // App 层在退出聊天页后据此发「回复完成/失败」本地通知。
        guard !runCancelled else { return }
        let hasOutput: Bool
        if let idx = messages.firstIndex(where: { $0.id == assistantID }) {
            hasOutput = !messages[idx].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } else {
            hasOutput = false
        }
        if hasOutput || runFailed {
            let snippet: String?
            if runFailed {
                snippet = runErrorText ?? "请查看"
            } else if let idx = messages.firstIndex(where: { $0.id == assistantID }) {
                snippet = Self.completionSnippet(for: messages[idx].content)
            } else {
                snippet = nil
            }
            onRunFinished?(self, !runFailed, snippet)
        }
    }

    // MARK: - WebSocket Send Path

    private func sendMessageViaWebSocket(_ content: String, images: [Data]? = nil, audioAttachment: VoiceMessageAttachment? = nil, gateway: GatewayConnection) async throws {
        // Subscribe to chat events BEFORE sending to avoid missing any
        let (subId, eventStream) = gateway.subscribeChatEvents()
        currentEventSubId = subId
        defer {
            gateway.unsubscribeChatEvents(id: subId)
            currentEventSubId = nil
            currentRunId = nil
        }

        let idempotencyKey = UUID().uuidString
        let response: GatewayConnection.ChatSendResponse
        if let audioAttachment, voiceAttachmentTransportSupported {
            // 网关确认支持语音附件（audio）时走附件上传（默认未启用）。
            // HTTP 兜底路径不支持附件，失败时按现有逻辑降级为纯文字发送。
            var params: [String: AnyCodable] = [
                "sessionKey": AnyCodable(sessionKey),
                "message": AnyCodable(content),
                "thinking": AnyCodable(""),
                "idempotencyKey": AnyCodable(idempotencyKey),
                "timeoutMs": AnyCodable(30000),
            ]
            let audioData = (try? Data(contentsOf: audioAttachment.localFileURL)) ?? Data()
            var allAttachments: [[String: AnyCodable]] = []
            if let images, !images.isEmpty {
                allAttachments.append(contentsOf: images.map { data in
                    [
                        "type": AnyCodable("image"),
                        "mimeType": AnyCodable("image/jpeg"),
                        "content": AnyCodable(data.base64EncodedString()),
                    ]
                })
            }
            allAttachments.append([
                "type": AnyCodable("audio"),
                "mimeType": AnyCodable("audio/wav"),
                "filename": AnyCodable(audioAttachment.localFileURL.lastPathComponent),
                "content": AnyCodable(audioData.base64EncodedString()),
            ])
            params["attachments"] = AnyCodable(allAttachments.map { AnyCodable($0) })

            let data = try await gateway.request(method: "chat.send", params: params)
            response = try JSONDecoder().decode(GatewayConnection.ChatSendResponse.self, from: data)
        } else {
            response = try await gateway.chatSend(
                sessionKey: sessionKey,
                message: content,
                images: images,
                idempotencyKey: idempotencyKey
            )
        }
        let runId = response.runId
        currentRunId = runId

        state = .streaming

        var fullResponse = ""
        var sentenceBuf = ""

        // Start audio playback engine if voice output is enabled
        if settings.settings.voiceOutputEnabled, speechService != nil {
            try audioPlayback.start()
            if isConversationMode { audioCapture.pauseListening() }
            state = .speaking
        }

        for await event in eventStream {
            try Task.checkCancellation()

            // Only handle events for our run
            guard event.runId == runId || event.runId == idempotencyKey else { continue }

            switch event.state {
            case "delta":
                if let text = event.message?.content?.first(where: { $0.type == "text" })?.text {
                    // The delta payload contains accumulated text, compute the new chunk
                    let delta: String
                    if text.count > fullResponse.count {
                        delta = String(text.dropFirst(fullResponse.count))
                    } else {
                        delta = text
                    }
                    fullResponse = text
                    sentenceBuf += delta

                    if let idx = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
                        messages[idx].content = fullResponse
                    }

                    // Pipeline TTS (concurrent: don't block LLM delta loop)
                    if settings.settings.voiceOutputEnabled, !ttsStopped,
                       let tts = speechService,
                       let boundary = sentenceBuf.lastSentenceBoundary() {
                        let sentence = String(sentenceBuf.prefix(boundary))
                        sentenceBuf = String(sentenceBuf.dropFirst(boundary))
                        ttsConcurrency.enqueue(sentence: sentence, tts: tts, playback: audioPlayback)
                    }
                }

            case "final":
                if let text = event.message?.content?.first(where: { $0.type == "text" })?.text {
                    fullResponse = text
                    if let idx = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
                        messages[idx].content = fullResponse
                    }
                }
                break // Exit the for-await loop after processing final

            case "error":
                let msg = event.errorMessage ?? "智能体错误"
                throw ChatError.notConfigured(msg)

            default:
                continue
            }

            // Break after final
            if event.state == "final" { break }
        }

        // Flush remaining TTS
        try await flushRemainingTTS(sentenceBuf)
        await ttsConcurrency.waitForAll()

        // Mark done
        if let idx = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
            messages[idx].isStreaming = false
        }

        // Wait for audio (skip if user stopped TTS)
        if settings.settings.voiceOutputEnabled, !ttsStopped {
            audioPlayback.markStreamingDone()
            await audioPlayback.waitUntilFinished()
            audioPlayback.stop()
        }
    }

    // MARK: - HTTP Send Path

    private func sendMessageViaHTTP(images: [Data]? = nil) async throws {
        // Prefer cached device auth token from gateway, fall back to settings token.
        let resolvedToken = OpenClawClient.resolveHTTPToken(
            settingsToken: settings.gatewayToken,
            gatewayURL: settings.settings.gatewayURL
        )
        try await streamHTTP(token: resolvedToken, images: images)
    }

    /// Drive the HTTP streaming loop with the given token.
    /// On a 401, clears the stale device token and retries once with the settings token.
    private func streamHTTP(token: String, images: [Data]?, isRetry: Bool = false) async throws {
        // Send full conversation history — the gateway HTTP API does not
        // persist sessions between requests, so each call needs full context.
        let eventStream = openClaw.stream(
            messages: messages.filter { !$0.isStreaming },
            gatewayURL: settings.settings.gatewayURL,
            token: token,
            model: channel.modelString,
            apiMode: settings.settings.agentAPIMode,
            sessionKey: sessionKey,
            messageChannel: "webchat"
        )

        state = .streaming

        var fullResponse = ""
        var sentenceBuf = ""

        if settings.settings.voiceOutputEnabled, speechService != nil {
            try audioPlayback.start()
            if isConversationMode { audioCapture.pauseListening() }
            state = .speaking
        }

        do {
            for try await event in eventStream {
                try Task.checkCancellation()

                switch event {
                case .textDelta(let token):
                    fullResponse += token
                    sentenceBuf += token

                    if let idx = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
                        messages[idx].content = fullResponse
                    }

                    if settings.settings.voiceOutputEnabled, !ttsStopped,
                       let tts = speechService,
                       let boundary = sentenceBuf.lastSentenceBoundary() {
                        let sentence = String(sentenceBuf.prefix(boundary))
                        sentenceBuf = String(sentenceBuf.dropFirst(boundary))
                        ttsConcurrency.enqueue(sentence: sentence, tts: tts, playback: audioPlayback)
                    }

                case .modelIdentified(let model):
                    if let idx = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
                        messages[idx].modelName = model
                    }

                case .completed(let tokenUsage, let responseId):
                    if let idx = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
                        messages[idx].tokenUsage = tokenUsage
                        messages[idx].responseId = responseId
                    }
                }
            }
        } catch let error as OpenClawError where !isRetry {
            // On 401/403, clear stale device token and retry once with settings token
            if case .httpErrorDetailed(let code, _, _) = error, code == 401 || code == 403 {
                let identity = DeviceIdentityManager.loadOrCreate()
                let host = URL(string: settings.settings.gatewayURL)?.host ?? settings.settings.gatewayURL
                DeviceAuthTokenStore.clearToken(deviceId: identity.deviceId, role: "user", gatewayHost: host)
                fullResponse = ""
                if let idx = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
                    messages[idx].content = ""
                }
                try await streamHTTP(token: settings.gatewayToken, images: images, isRetry: true)
                return
            }
            if case .httpError(let code) = error, code == 401 || code == 403 {
                let identity = DeviceIdentityManager.loadOrCreate()
                let host = URL(string: settings.settings.gatewayURL)?.host ?? settings.settings.gatewayURL
                DeviceAuthTokenStore.clearToken(deviceId: identity.deviceId, role: "user", gatewayHost: host)
                fullResponse = ""
                if let idx = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
                    messages[idx].content = ""
                }
                try await streamHTTP(token: settings.gatewayToken, images: images, isRetry: true)
                return
            }
            throw error
        }

        try await flushRemainingTTS(sentenceBuf)
        await ttsConcurrency.waitForAll()

        if let idx = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
            messages[idx].isStreaming = false
        }

        if settings.settings.voiceOutputEnabled, !ttsStopped {
            audioPlayback.markStreamingDone()
            await audioPlayback.waitUntilFinished()
            audioPlayback.stop()
        }
    }

    // MARK: - TTS Helper

    private func flushRemainingTTS(_ sentenceBuf: String) async throws {
        if settings.settings.voiceOutputEnabled, !ttsStopped,
           let tts = speechService,
           !sentenceBuf.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ttsConcurrency.enqueue(sentence: sentenceBuf, tts: tts, playback: audioPlayback)
        }
    }

    // MARK: - Server History

    /// Load chat history from the server via WebSocket.
    /// Replaces local messages if the server has a session for this channel.
    func loadServerHistory() {
        guard settings.settings.useWebSocket,
              let gateway = gatewayConnection,
              gateway.connectionState == .connected
        else { return }

        Task {
            do {
                let history = try await gateway.chatHistory(sessionKey: sessionKey, limit: 100)
                guard let serverMessages = history.messages, !serverMessages.isEmpty else { return }

                let converted = serverMessages.compactMap { msg -> Message? in
                    guard let role = msg.role,
                          let messageRole = MessageRole(rawValue: role)
                    else { return nil }

                    let text: String
                    if let stringVal = msg.content?.stringValue {
                        text = stringVal
                    } else if let parts = msg.content?.arrayValue {
                        // Extract text from content parts array
                        text = parts.compactMap { part -> String? in
                            guard let dict = part.dictValue,
                                  dict["type"]?.stringValue == "text"
                            else { return nil }
                            return dict["text"]?.stringValue
                        }.joined()
                    } else {
                        return nil
                    }

                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    return Message(role: messageRole, content: text)
                }

                guard !converted.isEmpty else { return }

                // Only populate from server when local is empty — never
                // overwrite local messages to prevent data loss.
                if messages.isEmpty {
                    messages = converted
                    conversationStore.save(messages, channelId: channel.id)
                }
            } catch {
                // Non-fatal — server may not have history for this session
                LogCollector.record(module: "历史记录", "会话历史加载失败：\(AppErrorText.localized(error.localizedDescription))")
            }
        }
    }

    // MARK: - Lifecycle

    func configure(transcription: (any TranscriptionService)?, speech: any SpeechService) {
        self.transcriptionService = transcription
        self.speechService = speech
    }

    func clearHistory() {
        messages.removeAll()
        conversationStore.clear(channelId: channel.id)
        channel.sessionVersion += 1
        channelStore?.update(channel)
    }

    /// Save the current conversation state without modifying the live messages array.
    func saveCurrentState() {
        conversationStore.save(messages, channelId: channel.id)
    }

    /// Stop all active audio and cancel any in-flight tasks.
    func stop() {
        abortCurrentRun()
        sendTask?.cancel()

        // Finalize any in-progress streaming message before saving
        if let idx = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
            messages[idx].isStreaming = false
            if messages[idx].content.isEmpty { messages.remove(at: idx) }
        }
        conversationStore.save(messages, channelId: channel.id)

        if isConversationMode {
            isConversationMode = false
            audioCapture.stopContinuousRecording()
        } else if state == .recording {
            _ = audioCapture.stopRecording()
        }
        speechService?.stop()
        audioPlayback.stop()
        state = .idle
    }

    func stopSpeaking() {
        ttsStopped = true
        ttsConcurrency.cancelAll()
        speechService?.stop()
        audioPlayback.stop()
        if state == .speaking {
            // Keep streaming text, just stop audio
            state = .streaming
        }
    }

    /// Live Activity 文案：把当前聊天状态映射为锁屏展示文本。
    private static func liveActivityStatus(for state: ChatState) -> String {
        switch state {
        case .idle, .recording:
            return "等待你说…"
        case .transcribing:
            return "正在转写…"
        case .thinking:
            return "正在思考…"
        case .streaming:
            return "正在回复…"
        case .speaking:
            return "正在朗读…"
        }
    }

    /// Send chat.abort for the current WebSocket run, if any.
    private func abortCurrentRun() {
        guard let runId = currentRunId,
              let gateway = gatewayConnection,
              gateway.connectionState == .connected
        else { return }

        let key = sessionKey
        // Clean up event subscription
        if let subId = currentEventSubId {
            gateway.unsubscribeChatEvents(id: subId)
            currentEventSubId = nil
        }
        currentRunId = nil

        Task {
            _ = try? await gateway.chatAbort(sessionKey: key, runId: runId)
        }
    }

    var audioLevel: Float {
        audioCapture.currentLevel
    }

    // MARK: - Message Management

    func deleteMessage(id: UUID) {
        if let attachment = voiceAttachments.removeValue(forKey: id) {
            VoiceMessageFileStore.delete(attachment)
        }
        messages.removeAll { $0.id == id }
        conversationStore.save(messages, channelId: channel.id)
    }

    /// Inject images from a node capability directly into the chat.
    func injectImages(_ images: [Data], caption: String?) {
        let message = Message(role: .assistant, content: caption ?? "", imageData: images)
        messages.append(message)
        conversationStore.save(messages, channelId: channel.id)
    }

    // MARK: - Retry

    /// Retry sending a failed user message.
    func retryMessage(id: UUID) {
        guard state == .idle else { return }
        guard let idx = messages.firstIndex(where: { $0.id == id && $0.role == .user && $0.hasFailed }) else { return }

        let content = messages[idx].content
        let images = messages[idx].imageData

        // Clear the error on the original message
        messages[idx].sendError = nil
        errorMessage = nil

        // Remove the original user message — sendMessage will re-add it
        messages.remove(at: idx)

        let attachment = voiceAttachments.removeValue(forKey: id)
        sendTask = Task {
            await sendMessage(content, images: images, voiceAttachment: attachment)
        }
    }

    // MARK: - Haptics

    /// 把回复内容截成通知摘要（60 字内，过长加省略号；空内容返回 nil）。
    private static func completionSnippet(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let limit = 60
        return trimmed.count > limit ? String(trimmed.prefix(limit)) + "…" : trimmed
    }

    private func notifySuccess() {
        guard settings.settings.hapticsEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func notifyError() {
        guard settings.settings.hapticsEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}

enum ChatError: LocalizedError {
    case notConfigured(String)
    case authenticationFailed(String)
    case networkError(String)
    case serverError(Int, String)
    case agentError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let msg): return msg
        case .authenticationFailed(let msg): return msg
        case .networkError(let msg): return msg
        case .serverError(let code, let msg): return "服务器错误（\(code)）：\(msg)"
        case .agentError(let msg): return msg
        }
    }

    var isRetryable: Bool {
        switch self {
        case .notConfigured: return false
        case .authenticationFailed: return true
        case .networkError, .serverError, .agentError: return true
        }
    }

    /// Classify an error from OpenClawClient or URLSession into a ChatError.
    static func classify(_ error: Error) -> ChatError {
        if let openClawError = error as? OpenClawError {
            switch openClawError {
            case .httpError(let code), .httpErrorDetailed(let code, _, _):
                switch code {
                case 401, 403:
                    return .authenticationFailed("认证失败，请重试，或在设置中检查网关令牌。")
                case 408, 429:
                    return .networkError("请求超时或触发限流，请重试。")
                case 400, 422:
                    return .agentError("请求无效，智能体无法处理这条消息。")
                case 500...599:
                    return .serverError(code, "网关遇到错误，请重试。")
                default:
                    return .serverError(code, "网关返回了未知错误。")
                }
            case .invalidURL:
                return .notConfigured("网关 URL 无效，请在设置中检查。")
            case .insecureConnection:
                return .notConfigured("必须使用 HTTPS，请在设置中更新网关 URL。")
            case .invalidResponse, .emptyResponse:
                return .agentError("智能体返回了无效或空的响应。")
            case .responseError(let msg):
                return .agentError(Self.localizedGatewayMessage(msg))
            case .toolError(let msg), .toolNotFound(let msg):
                return .agentError(msg)
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                return .networkError("没有网络连接。")
            case .timedOut:
                return .networkError("连接超时，请检查网络和网关。")
            case .cannotFindHost, .cannotConnectToHost:
                return .networkError("无法连接网关，请检查 URL 和网络。")
            case .secureConnectionFailed:
                return .networkError("SSL/TLS 连接失败。")
            case .cancelled:
                return .networkError("请求已取消。")
            default:
                return .networkError(AppErrorText.localized(urlError.localizedDescription))
            }
        }

        if error is CancellationError {
            return .networkError("已取消")
        }

        return .agentError(Self.localizedGatewayMessage(error.localizedDescription))
    }

    /// 把网关返回的错误转成本地化提示（按系统语言中英）。
    static func localizedGatewayMessage(_ msg: String) -> String {
        AppErrorText.localized(msg)
    }
}

extension String {
    func lastSentenceBoundary() -> Int? {
        // 整句送 TTS：只在句末标点切，超 30 字兜底硬切，句内由服务端流式断句自然衔接
        let terminators: [Character] = [".", "!", "?", "\n", "。", "！", "？"]
        guard let lastIndex = self.lastIndex(where: { terminators.contains($0) }) else {
            if self.count > 30 {
                if let spaceIdx = self.lastIndex(of: " ") {
                    return self.distance(from: self.startIndex, to: self.index(after: spaceIdx))
                }
                return 30
            }
            return nil
        }
        let pos = self.distance(from: self.startIndex, to: self.index(after: lastIndex))
        return pos > 4 ? pos : nil
    }
}

// MARK: - TTS Concurrency Manager

/// 并发 TTS 管线：句子送入后立即返回，不阻塞 LLM delta 循环。
/// 内部串行队列保证音频块按顺序到达播放器（避免句子乱序），
/// 同时允许 LLM 继续接收 delta 并排队下一句。
/// 按句序号顺序入队的音频缓冲：并发合成，但播放器收到的顺序不乱
private actor TTSBufferSequencer {
    private var expected = 0
    private var pending: [Int: [Data]] = [:]

    func feed(seq: Int, chunk: Data, playback: AudioPlaybackManager) {
        if seq == expected {
            playback.enqueue(pcmData: chunk)
        } else {
            pending[seq, default: []].append(chunk)
        }
    }

    func finish(seq: Int, playback: AudioPlaybackManager) {
        if seq != expected { return }
        expected += 1
        while let chunks = pending.removeValue(forKey: expected) {
            for chunk in chunks {
                playback.enqueue(pcmData: chunk)
            }
            expected += 1
        }
    }

    func reset() {
        expected = 0
        pending.removeAll()
    }
}

@MainActor
final class TTSConcurrency {
    private var tasks: [Task<Void, Never>] = []
    private let sequencer = TTSBufferSequencer()
    private var seqCounter = 0

    func enqueue(sentence: String, tts: any SpeechService, playback: AudioPlaybackManager) {
        let seq = seqCounter
        seqCounter += 1
        let task = Task {
            do {
                let audioStream = tts.streamSpeech(text: sentence)
                for try await chunk in audioStream {
                    await sequencer.feed(seq: seq, chunk: chunk, playback: playback)
                }
                await sequencer.finish(seq: seq, playback: playback)
            } catch {
                LogCollector.record(module: "朗读", "TTS 合成失败（重试前）：\(AppErrorText.localized(error.localizedDescription))")
                // ?? TTS ????????????????"???????"
                if !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    if Task.isCancelled { return }
                    do {
                        let audioStream = tts.streamSpeech(text: sentence)
                        for try await chunk in audioStream {
                            await sequencer.feed(seq: seq, chunk: chunk, playback: playback)
                        }
                        await sequencer.finish(seq: seq, playback: playback)
                    } catch {
                        LogCollector.record(module: "朗读", "TTS 合成失败（重试后仍失败）：\(AppErrorText.localized(error.localizedDescription))")
                        // ??????????
                        await sequencer.finish(seq: seq, playback: playback)
                    }
                } else {
                    await sequencer.finish(seq: seq, playback: playback)
                }
            }
        }
        tasks.append(task)
    }

    /// 等待所有排队的 TTS 任务完成（在 flushRemainingTTS 之后调用）。
    func waitForAll() async {
        await Task.yield()
        while !tasks.isEmpty {
            let t = tasks.removeFirst()
            await t.value
        }
    }

    func cancelAll() {
        for t in tasks { t.cancel() }
        tasks.removeAll()
        seqCounter = 0
        Task { await sequencer.reset() }
    }
}
