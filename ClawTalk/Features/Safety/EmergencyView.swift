import SwiftUI

/// 紧急求助设置页：开关 + 联系人列表 + 求助文案 + 位置开关 +
/// 「模拟触发」测试 + 最近一次触发结果 + 系统限制诚实说明。
struct EmergencyView: View {
    let store: EmergencyStore

    @State private var newContact = ""
    @State private var sosMessageDraft = ""

    var body: some View {
        Form {
            enabledSection
            contactsSection
            messageSection
            triggerSection
            recentResultSection
            limitationsSection
        }
        .navigationTitle("紧急求助")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if sosMessageDraft.isEmpty {
                sosMessageDraft = store.config.sosMessage
            }
        }
    }

    // MARK: - 开关

    private var enabledSection: some View {
        Section {
            Toggle("启用紧急求助", isOn: Binding(
                get: { store.config.enabled },
                set: { store.setEnabled($0) }
            ))
            if store.config.enabled {
                Label("主页显示红色 SOS 按钮：点击触发，10 秒内可长按取消。", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("紧急求助")
        } footer: {
            Text("iOS 不允许 App 检测电源键连按，本功能使用主页 SOS 按钮 + 锁屏小组件/深链入口代替。")
        }
    }

    // MARK: - 联系人

    private var contactsSection: some View {
        Section {
            if store.config.emergencyContacts.isEmpty {
                Text("尚未添加联系人。请添加电话号码（触发后需手动拨号）或网关频道名（触发后经网关发送）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.config.emergencyContacts, id: \.self) { contact in
                    HStack(spacing: 10) {
                        Image(systemName: EmergencyConfig.kind(of: contact).icon)
                            .foregroundStyle(.red)
                        Text(contact)
                        Spacer()
                        if case .phone = EmergencyConfig.kind(of: contact) {
                            Button("拨号") { store.manualCall(contact: contact) }
                                .font(.caption)
                                .buttonStyle(.borderless)
                        }
                    }
                }
                .onDelete { store.removeContact(at: $0) }
            }

            HStack {
                TextField("电话号码或频道名", text: $newContact)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("添加") {
                    store.addContact(newContact)
                    newContact = ""
                }
                .disabled(newContact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("紧急联系人")
        } footer: {
            Text("电话号码（如 +86 13812345678）：iOS 不允许自动拨号，触发后需手动拨号。频道名（如「家」）：需与主页频道列表中的频道名一致，触发后经网关发送到该频道会话；发送结果会诚实显示「已发送/未发送」。")
        }
    }

    // MARK: - 求助信息

    private var messageSection: some View {
        Section {
            TextField("求助文案", text: $sosMessageDraft, axis: .vertical)
                .lineLimit(2...4)
                .onChange(of: sosMessageDraft) { _, newValue in
                    store.setSOSMessage(newValue)
                }
            Toggle("附带当前位置", isOn: Binding(
                get: { store.config.includeLocation },
                set: { store.setIncludeLocation($0) }
            ))
        } header: {
            Text("求助信息")
        } footer: {
            Text("开启位置后，触发时尝试获取当前位置（15 秒超时兜底），拼成「紧急求助：我在[地址/坐标]，请尽快联系我。」；取不到位置时诚实使用下方文案，不塞假位置。")
        }
    }

    // MARK: - 测试

    private var triggerSection: some View {
        Section {
            Button {
                store.triggerSOS(simulated: true)
            } label: {
                Label("模拟触发（测试）", systemImage: "play.circle")
                    .frame(maxWidth: .infinity)
            }
            .disabled(store.phase != .idle)
        } header: {
            Text("测试")
        } footer: {
            Text("模拟触发只测试本地通知与响铃/震动链路，不会向任何联系人发送消息。")
        }
    }

    // MARK: - 最近一次触发

    @ViewBuilder
    private var recentResultSection: some View {
        if case .countingDown(let remaining) = store.phase {
            Section {
                HStack {
                    Label("\(remaining) 秒后发送，可取消", systemImage: "timer")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("取消") { store.cancelSOS() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
            } header: {
                Text("触发中")
            }
        }

        if let summary = store.lastTriggerSummary {
            Section {
                Label(
                    summary,
                    systemImage: store.phase == .sending ? "arrow.triangle.2.circlepath" : "checkmark.shield.fill"
                )
                .foregroundStyle(store.phase == .sending ? .secondary : .green)

                if !store.lastSendResults.isEmpty {
                    ForEach(store.lastSendResults) { result in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: result.delivered ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(result.delivered ? .green : .red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.contact)
                                Text(result.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if let failure = store.notificationFailure {
                    Label(failure, systemImage: "bell.slash.fill")
                        .foregroundStyle(.red)
                }

                if store.phase == .finished {
                    Button("复位") { store.resetSOS() }
                }
            } header: {
                Text("最近一次触发")
            }
        }
    }

    // MARK: - 系统限制说明（诚实标注）

    private var limitationsSection: some View {
        Section {
            Label(
                "自动拨号 110/120：iOS 不允许 App 自动拨号。紧急联系人中的电话只能通过「拨号」按钮跳转系统拨号盘，需手动确认拨打。",
                systemImage: "phone.badge.exclamationmark"
            )
            Label(
                "电源键连按 5 次：iOS 无公开 API 检测，未实现。使用主页 SOS 按钮 + 锁屏小组件/深链（clawtalk://sos）代替。",
                systemImage: "lock.open"
            )
            Label(
                "触发后 10 秒内可取消：主页 SOS 按钮长按或本页「取消」按钮，防止误触。",
                systemImage: "hand.raised.fill"
            )
            Label(
                "本地通知使用「时效性」级别；更高一级的「紧急」通知需要 Apple 单独授权的关键通知能力，未申请。",
                systemImage: "bell.fill"
            )
        } header: {
            Text("系统限制说明（诚实标注）")
        }
    }
}

/// 主页「紧急求助」卡：红色 SOS 大按钮（点击触发 + 长按取消）+ 设置入口。
/// 接线：主智能体在 HomeTabView 的快捷入口 LazyVGrid 中加入
/// `EmergencyHomeCardView(store: EmergencyStore.shared)`。
struct EmergencyHomeCardView: View {
    let store: EmergencyStore

    /// 长按松手后 Button 的 tap 会接着触发一次，用短时间窗口吞掉这次误触发
    @State private var suppressNextTapUntil: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("紧急求助", systemImage: "sos")
                    .font(.headline)
                    .foregroundStyle(.red)
                Spacer()
                NavigationLink {
                    EmergencyView(store: store)
                } label: {
                    Image(systemName: "gearshape.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            triggerButton

            if let summary = store.lastTriggerSummary, store.phase != .idle {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    /// 未开启 → 点按跳设置页；已开启 → 点击触发、长按取消
    @ViewBuilder
    private var triggerButton: some View {
        if store.config.enabled {
            Button(action: performTapAction) {
                buttonLabel
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 1.0)
                    .onEnded { _ in
                        suppressNextTapUntil = Date().addingTimeInterval(0.6)
                        store.cancelSOS()
                    }
            )
        } else {
            NavigationLink {
                EmergencyView(store: store)
            } label: {
                buttonLabel
            }
            .buttonStyle(.plain)
        }
    }

    private func performTapAction() {
        if let until = suppressNextTapUntil, Date() < until {
            suppressNextTapUntil = nil
            return
        }
        if store.phase == .finished {
            store.resetSOS()
            return
        }
        store.triggerSOS()
    }

    private var buttonLabel: some View {
        VStack(spacing: 6) {
            Text("SOS")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
            Text(subtitleText)
                .font(.caption)
                .opacity(0.85)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, minHeight: 96)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(buttonColor)
        )
    }

    private var buttonColor: Color {
        switch store.phase {
        case .idle: return store.config.enabled ? .red : .gray
        case .countingDown, .sending: return .orange
        case .finished: return .green
        }
    }

    private var subtitleText: String {
        switch store.phase {
        case .idle:
            return store.config.enabled ? "点击触发 · 长按取消" : "未开启 · 点按去设置"
        case .countingDown(let remaining):
            return "已触发 · \(remaining) 秒内长按取消"
        case .sending:
            return "发送中 · 正在通知联系人"
        case .finished:
            let delivered = store.lastSendResults.filter(\.delivered).count
            let failed = store.lastSendResults.count - delivered
            if delivered > 0 { return "已发送 \(delivered) 个联系人 · 点按复位" }
            if failed > 0 { return "\(failed) 个联系人未发送 · 点按复位" }
            return "已完成 · 点按复位"
        }
    }
}
