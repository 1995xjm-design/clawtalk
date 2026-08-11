import Foundation
import Observation
import SwiftUI

/// 能力面板（「连接与状态」功能组）。
///
/// 优先探测网关 capabilities 查询接口（HTTP GET /capabilities、/v1/capabilities）；
/// 网关未提供时，诚实展示本地已接线的能力清单（与 NodeConnection 向网关声明的
/// caps/commands 一致），来源标注「本地清单」。
struct CapabilityEntry: Identifiable, Equatable {
    enum Source: String, Equatable {
        case remote = "网关返回"
        case local = "本地清单"
    }

    let id: String
    let name: String
    let icon: String
    let commandCount: Int
    let detail: String
    let source: Source
    let statusNote: String
}

/// 本地能力元数据（镜像 NodeConnection.declaredCaps/declaredCommands）。
struct CapabilityInfo: Identifiable, Equatable {
    let name: String
    let title: String
    let icon: String
    let commands: [String]
    let detail: String

    var id: String { name }
}

@MainActor
@Observable
final class CapabilitiesViewModel {

    private(set) var entries: [CapabilityEntry] = []
    private(set) var source: CapabilityEntry.Source?
    private(set) var message: String?
    private(set) var isLoading = false

    func load(settings: SettingsStore, nodeConnected: Bool) async {
        isLoading = true
        defer { isLoading = false }

        let base = settings.settings.gatewayURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard !base.isEmpty else {
            entries = Self.localEntries(nodeConnected: false)
            source = .local
            message = "未配置网关：以下为本地已接线的能力清单。"
            return
        }

        if let remoteNames = await Self.fetchRemoteCapabilities(base: base, token: settings.gatewayToken),
           !remoteNames.isEmpty {
            entries = remoteNames.map { name in
                let meta = Self.localCapabilities.first { $0.name == name }
                return CapabilityEntry(
                    id: name,
                    name: meta?.title ?? name,
                    icon: meta?.icon ?? "square.grid.2x2",
                    commandCount: meta?.commands.count ?? 0,
                    detail: meta?.detail ?? "网关提供的能力",
                    source: .remote,
                    statusNote: "网关返回"
                )
            }
            source = .remote
            message = "能力列表来自网关 capabilities 接口。"
            return
        }

        entries = Self.localEntries(nodeConnected: nodeConnected)
        source = .local
        message = "未检测到网关 capabilities 查询接口，以下为本地已接线的能力清单（与 NodeConnection 声明一致）。"
    }

    static func localEntries(nodeConnected: Bool) -> [CapabilityEntry] {
        localCapabilities.map { capability in
            CapabilityEntry(
                id: capability.name,
                name: capability.title,
                icon: capability.icon,
                commandCount: capability.commands.count,
                detail: capability.detail,
                source: .local,
                statusNote: nodeConnected ? "节点已连接 · 网关可调用" : "已声明 · 等待节点连接"
            )
        }
    }

    /// 尽力探测网关 capabilities 接口；返回能力名数组；无接口或解析失败返回 nil。
    static func fetchRemoteCapabilities(base: String, token: String) async -> [String]? {
        for path in ["/capabilities", "/v1/capabilities"] {
            guard let url = URL(string: "\(base)\(path)") else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            if !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { continue }

            if let names = try? JSONDecoder().decode([String].self, from: data), !names.isEmpty {
                return names
            }
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let names = object["capabilities"] as? [String], !names.isEmpty { return names }
                if let names = object["data"] as? [String], !names.isEmpty { return names }
            }
        }
        return nil
    }

    /// 本地清单：与 NodeConnection.declaredCaps / declaredCommands 一致（14 类能力 / 25 命令）。
    static let localCapabilities: [CapabilityInfo] = [
        CapabilityInfo(name: "device", title: "设备信息", icon: "iphone.gen3", commands: ["device.status", "device.info"], detail: "设备型号、状态、电量等"),
        CapabilityInfo(name: "notifications", title: "通知", icon: "bell.badge", commands: ["system.notify"], detail: "向 iPhone 发送本地通知"),
        CapabilityInfo(name: "location", title: "定位", icon: "location", commands: ["location.get"], detail: "分享当前位置（需定位权限）"),
        CapabilityInfo(name: "contacts", title: "通讯录", icon: "person.crop.circle.badge.checkmark", commands: ["contacts.search", "contacts.add"], detail: "搜索/添加联系人（需通讯录权限）"),
        CapabilityInfo(name: "calendar", title: "日历", icon: "calendar", commands: ["calendar.events", "calendar.add"], detail: "读取/创建日历事件（需日历权限）"),
        CapabilityInfo(name: "reminders", title: "提醒事项", icon: "checklist", commands: ["reminders.list", "reminders.add"], detail: "读取/添加提醒（需提醒权限）"),
        CapabilityInfo(name: "motion", title: "运动", icon: "figure.walk", commands: ["motion.activity", "motion.pedometer"], detail: "活动/步数数据（需运动权限）"),
        CapabilityInfo(name: "photos", title: "照片", icon: "photo.on.rectangle.angled", commands: ["photos.latest"], detail: "读取最近照片（需照片权限）"),
        CapabilityInfo(name: "camera", title: "相机", icon: "camera", commands: ["camera.list", "camera.snap"], detail: "拍照并回传（需相机权限）"),
        CapabilityInfo(name: "screen", title: "屏幕", icon: "rectangle.inset.filled.and.person.filled", commands: ["screen.snapshot"], detail: "屏幕截图"),
        CapabilityInfo(name: "canvas", title: "画布", icon: "square.3.layers.3d", commands: ["canvas.present", "canvas.navigate", "canvas.evalJS", "canvas.snapshot", "canvas.reset"], detail: "网页画布控制"),
        CapabilityInfo(name: "voice", title: "语音唤醒", icon: "waveform", commands: ["voicewake.set", "voicewake.get"], detail: "唤醒词配置"),
        CapabilityInfo(name: "health", title: "健康", icon: "heart", commands: ["health.steps"], detail: "健康数据步数（需健康权限）"),
        CapabilityInfo(name: "media", title: "媒体", icon: "music.note.list", commands: ["media.list"], detail: "最近媒体文件"),
    ]
}

/// 能力面板页。由主智能体接入工具页/设置页（NavigationLink）。
struct CapabilitiesView: View {
    let settings: SettingsStore
    var nodeConnection: NodeConnection?

    @State private var model: CapabilitiesViewModel

    init(settings: SettingsStore, nodeConnection: NodeConnection? = nil) {
        self.settings = settings
        self.nodeConnection = nodeConnection
        _model = State(initialValue: CapabilitiesViewModel())
    }

    private var nodeStatusText: String {
        if let nodeConnection, case .connected = nodeConnection.connectionState {
            return "已连接"
        }
        return "未连接"
    }

    var body: some View {
        List {
            if let source = model.source {
                Section {
                    Label(
                        source == .remote ? "数据来源：网关返回" : "数据来源：本地清单",
                        systemImage: source == .remote ? "antenna.radiowaves.left.and.right" : "iphone"
                    )
                    .font(.subheadline)

                    if let message = model.message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                if model.entries.isEmpty {
                    Text("暂无能力信息")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.entries) { entry in
                        HStack(spacing: 12) {
                            Image(systemName: entry.icon)
                                .foregroundStyle(Color.openClawRed)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(entry.name)
                                        .font(.subheadline.weight(.semibold))
                                    Text(entry.statusNote)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Text(entry.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if entry.source == .local {
                                Text("\(entry.commandCount) 命令")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            } else {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                Text("能力列表")
            }

            Section {
                LabeledContent("节点（NodeConnection）", value: nodeStatusText)
            } footer: {
                Text("本地清单与 NodeConnection 向网关声明的能力一致；网关侧是否接受以连接回执为准。若网关提供 capabilities 查询接口，本页会自动优先展示网关返回。")
            }
        }
        .navigationTitle("能力")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("刷新") {
                    Task { await reload() }
                }
                .disabled(model.isLoading)
            }
        }
        .task {
            await reload()
        }
    }

    private func reload() async {
        await model.load(settings: settings, nodeConnected: nodeStatusText == "已连接")
    }
}
