import Foundation
import UserNotifications

/// 审批推送桥（对齐官方 ExecApprovalNotificationBridge）：
/// 注册通知分类（exec/plugin 审批），把远程推送里的 approvalId 规范化，
/// 并支持把待处理审批写入本地，供前台/通知中心点击后跳转。
enum ApprovalKind: String, Codable {
    case exec
    case plugin
}

struct ApprovalNotificationPrompt: Codable, Equatable, Hashable {
    let approvalId: String
    let gatewayDeviceId: String?
    let kind: ApprovalKind

    init(approvalId: String, gatewayDeviceId: String?, kind: ApprovalKind = .exec) {
        self.approvalId = approvalId
        self.gatewayDeviceId = gatewayDeviceId
        self.kind = kind
    }
}

typealias ExecApprovalNotificationPrompt = ApprovalNotificationPrompt

enum ApprovalNotificationBridge {
    static let execCategoryIdentifier = "EXEC_APPROVAL"
    static let pluginCategoryIdentifier = "PLUGIN_APPROVAL"
    static let reviewActionIdentifier = "REVIEW_APPROVAL"

    static func registerCategories(center: UNUserNotificationCenter = .current()) {
        let categories = [
            self.category(kind: .exec, identifier: self.execCategoryIdentifier),
            self.category(kind: .plugin, identifier: self.pluginCategoryIdentifier),
        ]
        center.getNotificationCategories { existingCategories in
            var updated = existingCategories
            for category in categories {
                updated.update(with: category)
            }
            center.setNotificationCategories(updated)
        }
    }

    /// 从推送 userInfo 提取审批提示（统一键名，兼容新旧版本）。
    static func prompt(from userInfo: [AnyHashable: Any]) -> ApprovalNotificationPrompt? {
        if let raw = userInfo["approvalId"] as? String,
           let approvalId = ExecApprovalIdentifier.exact(raw) {
            let kindRaw = userInfo["approvalKind"] as? String
            let kind = ApprovalKind(rawValue: kindRaw ?? "") ?? .exec
            return ApprovalNotificationPrompt(
                approvalId: approvalId,
                gatewayDeviceId: userInfo["gatewayDeviceId"] as? String,
                kind: kind)
        }
        if let raw = userInfo["openclaw.approval.id"] as? String,
           let approvalId = ExecApprovalIdentifier.exact(raw) {
            let kindRaw = userInfo["openclaw.approval.kind"] as? String
            let kind = ApprovalKind(rawValue: kindRaw ?? "") ?? .exec
            return ApprovalNotificationPrompt(
                approvalId: approvalId,
                gatewayDeviceId: userInfo["openclaw.gateway.device"] as? String,
                kind: kind)
        }
        return nil
    }

    /// 本地待处理审批最近一次快照（供点击通知后拉取详情）。
    static func persistPending(_ approvalId: String, gatewayDeviceId: String?) {
        UserDefaults.standard.set(approvalId, forKey: "openclaw.approval.last.id")
        if let gatewayDeviceId {
            UserDefaults.standard.set(gatewayDeviceId, forKey: "openclaw.approval.last.gateway")
        }
    }

    static func lastPendingApprovalId() -> String? {
        UserDefaults.standard.string(forKey: "openclaw.approval.last.id")
    }

    private static func category(kind: ApprovalKind, identifier: String) -> UNNotificationCategory {
        let review = UNNotificationAction(
            identifier: self.reviewActionIdentifier,
            title: kind == .exec ? "审查" : "审查",
            options: [.foreground])
        return UNNotificationCategory(
            identifier: identifier,
            actions: [review],
            intentIdentifiers: [],
            options: [])
    }
}
