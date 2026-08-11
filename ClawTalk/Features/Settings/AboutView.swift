import SwiftUI
import UIKit

/// 关于：App 版本、设备信息与当前网关连接状态。
struct AboutView: View {
    let settings: SettingsStore
    var gatewayConnection: GatewayConnection

    var body: some View {
        List {
            Section("App") {
                LabeledContent("名称", value: "ClawTalk")
                LabeledContent("版本", value: appVersion)
                LabeledContent("构建号", value: appBuild)
            }

            Section("设备") {
                LabeledContent("机型", value: deviceModel)
                LabeledContent("系统", value: systemVersion)
            }

            Section("网关") {
                LabeledContent("地址", value: settings.settings.gatewayURL.isEmpty ? "未配置" : settings.settings.gatewayURL)
                LabeledContent("状态", value: gatewayStatusText)
                LabeledContent("接口方式", value: settings.settings.agentAPIMode.rawValue)
            }

            Section {
                Text("ClawTalk — 语音优先的 OpenClaw 移动客户端。")
            } footer: {
                Text("连接异常时，可在「日志与诊断」中查看错误详情。")
            }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    private var systemVersion: String {
        "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
    }

    private var gatewayStatusText: String {
        switch gatewayConnection.connectionState {
        case .connected: return "已连接"
        case .connecting: return "连接中…"
        case .disconnected: return "未连接"
        }
    }

    /// 设备型号：优先展示常用机型的市场名称，未知型号回退到标识符。
    private var deviceModel: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce(into: "") { partial, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            partial.append(String(UnicodeScalar(UInt8(value))))
        }
        if let name = Self.marketingNames[identifier] {
            return name
        }
        return "\(UIDevice.current.localizedModel)（\(identifier)）"
    }

    private static let marketingNames: [String: String] = [
        "iPhone14,7": "iPhone 14",
        "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro",
        "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone14,4": "iPhone 13 mini",
        "iPhone14,5": "iPhone 13",
        "iPhone14,2": "iPhone 13 Pro",
        "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone13,1": "iPhone 12 mini",
        "iPhone13,2": "iPhone 12",
        "iPhone13,3": "iPhone 12 Pro",
        "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone15,4": "iPhone 15",
        "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro",
        "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,1": "iPhone 16 Pro",
        "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,3": "iPhone 16",
        "iPhone17,4": "iPhone 16 Plus",
        "iPhone17,5": "iPhone 16e",
    ]
}