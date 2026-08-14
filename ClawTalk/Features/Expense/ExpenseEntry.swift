import Foundation
import SwiftUI

/// 记账类型：收入 / 支出。
enum ExpenseType: String, Codable, CaseIterable, Identifiable, Equatable {
    case income = "收入"
    case expense = "支出"

    var id: String { rawValue }
}

/// 记账类别：餐饮 / 交通 / 购物 / 居住 / 娱乐 / 医疗 / 其他。
/// 语音解析按关键词映射（见 ExpenseVoiceParser），手动添加可自由选择。
enum ExpenseCategory: String, Codable, CaseIterable, Identifiable, Equatable {
    case food = "餐饮"
    case transport = "交通"
    case shopping = "购物"
    case housing = "居住"
    case entertainment = "娱乐"
    case medical = "医疗"
    case other = "其他"

    var id: String { rawValue }
}

/// 一条账目（本地存储，UserDefaults JSON，见 ExpenseStore）。
struct ExpenseEntry: Identifiable, Codable, Equatable {
    let id: UUID
    /// 记账日期（按日分组用；语音记账取录音开始时间，手动添加默认今天）
    let date: Date
    /// 金额（元，>0；语音解析/手动填写均校验）
    let amount: Double
    /// 收入 / 支出
    let type: ExpenseType
    /// 类别：餐饮 / 交通 / 购物 / 居住 / 娱乐 / 医疗 / 其他
    let category: ExpenseCategory
    /// 备注（语音记账存转写原文，手动填写可自由输入）
    let note: String
    /// 附带照片文件名（存 Application Support/ClawTalk/ExpensePhotos/，nil = 无照片）
    let photoFileName: String?
    /// 条目创建时间（预留：编辑/迁移时保留原始时间戳）
    let createdAt: Date

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        amount: Double,
        type: ExpenseType,
        category: ExpenseCategory,
        note: String,
        photoFileName: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.date = date
        self.amount = amount
        self.type = type
        self.category = category
        self.note = note
        self.photoFileName = photoFileName
        self.createdAt = createdAt
    }
}

// MARK: - 金额显示

extension Double {
    /// 金额显示：保留两位小数（如 28 → "28.00"）
    var expenseAmountText: String {
        String(format: "%.2f", self)
    }
}

// MARK: - 类别展示（图标 / 主题色，供列表行与主页卡片使用）

extension ExpenseCategory {
    /// SF Symbols 图标
    var iconName: String {
        switch self {
        case .food: return "fork.knife"
        case .transport: return "car.fill"
        case .shopping: return "bag.fill"
        case .housing: return "house.fill"
        case .entertainment: return "gamecontroller.fill"
        case .medical: return "cross.case.fill"
        case .other: return "ellipsis.circle.fill"
        }
    }

    /// 类别主题色（深色/浅色下均有对比度）
    var themeColor: Color {
        switch self {
        case .food: return .orange
        case .transport: return .blue
        case .shopping: return .pink
        case .housing: return .brown
        case .entertainment: return .purple
        case .medical: return .red
        case .other: return .gray
        }
    }
}

extension ExpenseType {
    /// 类型图标（收入/支出）
    var iconName: String {
        switch self {
        case .income: return "arrow.down.left.circle.fill"
        case .expense: return "arrow.up.right.circle.fill"
        }
    }

    /// 类型主题色
    var themeColor: Color {
        switch self {
        case .income: return .green
        case .expense: return .orange
        }
    }
}