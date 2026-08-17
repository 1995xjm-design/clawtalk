import SwiftUI

/// 系统代理聊天（对齐官方 SettingsSystemAgentChat 精简）：
/// 与网关系统代理（openclaw:main）交互：发送消息、查看回复、回答问题。
struct SettingsSystemAgentChatScreen: View {
    var gatewayConnection: GatewayConnection

    enum AccessState: Equatable {
        case unknown
        case allowed
        case restricted(String)
    }

    @State private var accessState: AccessState = .unknown
    @State private var inputText = ""
    @State private var transcript: [ChatLine] = []
    @State private var pendingQuestion: QuestionLine?
    @State private var busy = false
    @State private var errorText: String?

    private struct ChatLine: Identifiable {
        let id = UUID()
        let role: String
        let text: String
    }

    private struct QuestionLine: Identifiable {
        let id = UUID()
        let question: String
        let sessionKey: String
    }

    var body: some View {
        List {
            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            Section("访问状态") {
                HStack {
                    Text("系统代理聊天")
                    Spacer()
                    switch accessState {
                    case .unknown:
                        Text("检查中…").font(.caption).foregroundStyle(.secondary)
                    case .allowed:
                        Label("可用", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                    case .restricted(let reason):
                        Text(reason).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            Section("对话") {
                if transcript.isEmpty && !busy {
                    Text("发送消息与系统代理对话。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(transcript) { line in
                    HStack(alignment: .top) {
                        Text(line.role == "assistant" ? "AI" : "我")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(line.role == "assistant" ? Color.openClawRed : .secondary)
                            .frame(width: 24, alignment: .leading)
                        Text(line.text)
                            .font(.subheadline)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if busy {
                    HStack {
                        ProgressView()
                        Text("思考中…").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            if let pendingQuestion {
                Section("待回答问题") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(pendingQuestion.question)
                            .font(.subheadline)
                        HStack {
                            Button("回答") {
                                answerQuestion(pendingQuestion)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(busy)
                            Button("跳过") {
                                skipQuestion(pendingQuestion)
                            }
                            .buttonStyle(.bordered)
                            .disabled(busy)
                        }
                    }
                }
            }
            Section {
                HStack(spacing: 8) {
                    TextField("输入消息…", text: $inputText)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.send)
                        .onSubmit { send() }
                    Button("发送") { send() }
                        .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                }
            }
        }
        .navigationTitle("系统代理聊天")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshAccess() }
    }

    private func refreshAccess() async {
        do {
            let data = try await gatewayConnection.request(method: "system.info", params: nil, timeoutMs: 10)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let info = try? decoder.decode(SystemInfo.self, from: data)
            if info?.processInstanceId != nil {
                accessState = .allowed
            } else {
                accessState = .restricted("网关未返回系统信息")
            }
        } catch {
            accessState = .restricted(error.localizedDescription)
        }
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        transcript.append(ChatLine(role: "user", text: text))
        busy = true
        errorText = nil
        Task {
            do {
                let data = try await gatewayConnection.request(
                    method: "chat.start",
                    params: [
                        "agentId": AnyCodable("main"),
                        "message": AnyCodable(text),
                        "sessionKey": AnyCodable("agent:main:system-agent-chat"),
                    ],
                    timeoutMs: 30)
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let result = try? decoder.decode(SystemAgentChatResult.self, from: data)
                let reply = result?.reply ?? result?.message ?? "（无回复）"
                transcript.append(ChatLine(role: "assistant", text: reply))
            } catch {
                errorText = error.localizedDescription
                transcript.append(ChatLine(role: "assistant", text: "错误：\(error.localizedDescription)"))
            }
            busy = false
        }
    }

    private func answerQuestion(_ question: QuestionLine) {
        busy = true
        Task {
            do {
                _ = try await gatewayConnection.request(
                    method: "question.resolve",
                    params: ["question": AnyCodable(question.question)],
                    timeoutMs: 15)
                pendingQuestion = nil
            } catch {
                errorText = error.localizedDescription
            }
            busy = false
        }
    }

    private func skipQuestion(_ question: QuestionLine) {
        pendingQuestion = nil
    }
}

private struct SystemAgentChatResult: Codable {
    var reply: String?
    var message: String?
    var sessionKey: String?
    var ok: Bool?
}
