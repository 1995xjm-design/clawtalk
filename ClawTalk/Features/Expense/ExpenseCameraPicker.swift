import Foundation
import PhotosUI
import SwiftUI
import UIKit

/// 记账拍照：UIImagePickerController 相机封装（模拟器/无相机设备由页面回退相册）。
struct ExpenseCameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onImage: onImage)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onImage: (UIImage) -> Void

        init(onImage: @escaping (UIImage) -> Void) {
            self.onImage = onImage
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onImage(image)
            }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

/// OCR 文本 → 记账草稿：先走语音解析规则（¥28 / 28元 / 花了28 等），
/// 再补收据小票特有模式（合计/总计/总额行、末尾独立金额行）；
/// 仍解析不出返回 nil，由页面弹手动补齐（诚实，不做假解析）。
enum ExpenseOCRTextParser {

    static func parse(_ raw: String) -> ExpenseVoiceParser.Draft? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // 1) 先走语音解析规则（¥28 / 28元 / 花了28 / 收到工资8000 等）
        if let draft = ExpenseVoiceParser.parse(text) {
            return draft
        }

        // 2) 收据小票：合计/总计/总额/应付/实收/应收（取最后一次匹配，总额通常在末尾）
        if let amount = lastAmount(
            matching: #"(?:合计|总计|总额|应付|实收|应收|付款金额|消费金额|金额)[:：]?\s*[¥￥]?\s*(\d+(?:\.\d+)?)"#,
            in: text
        ) {
            return makeDraft(amount: amount, from: text)
        }

        // 3) 收据小票：最后一行是独立金额（如 "28.00" / "¥28.00"）
        let lines: [String] = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let lastLine = lines.last, let amount = standaloneAmount(line: lastLine) {
            return makeDraft(amount: amount, from: text)
        }

        return nil
    }

    // MARK: - 金额

    /// 关键字金额：返回最后一次匹配（收据总额行通常在末尾）。
    private static func lastAmount(matching pattern: String, in text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        for match in matches.reversed() where match.numberOfRanges > 1 {
            let range = match.range(at: 1)
            guard range.location != NSNotFound else { continue }
            if let amount = Double(nsText.substring(with: range)), amount > 0 {
                return amount
            }
        }
        return nil
    }

    /// 独立金额行：纯数字（可带 ¥/￥ 前缀），最多两位小数。
    private static func standaloneAmount(line: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: #"^[¥￥]?\s*(\d{1,7}(?:\.\d{1,2})?)$"#) else { return nil }
        let nsLine = line as NSString
        guard let match = regex.firstMatch(in: line, options: [], range: NSRange(location: 0, length: nsLine.length)),
              match.numberOfRanges > 1 else { return nil }
        let range = match.range(at: 1)
        guard let amount = Double(nsLine.substring(with: range)), amount > 0 else { return nil }
        return amount
    }

    // MARK: - 草稿

    private static func makeDraft(amount: Double, from text: String) -> ExpenseVoiceParser.Draft? {
        guard amount > 0 else { return nil }
        let isIncome = ExpenseVoiceParser.classifyIncome(text: text)
        return ExpenseVoiceParser.Draft(
            amount: amount,
            type: isIncome ? .income : .expense,
            category: category(from: text),
            note: text
        )
    }

    /// 类别关键词（与 ExpenseVoiceParser 同表，OCR 收据场景复用；识别不出回退「其他」）。
    private static func category(from text: String) -> ExpenseCategory {
        let rules: [(ExpenseCategory, [String])] = [
            (.medical, ["医院", "看病", "挂号", "检查", "诊所", "药"]),
            (.housing, ["房租", "房贷", "租房", "水电", "水费", "电费", "燃气", "物业"]),
            (.transport, ["打车", "出租车", "滴滴", "车费", "地铁", "公交", "加油", "油费", "停车", "高铁", "火车", "机票"]),
            (.entertainment, ["电影", "游戏", "娱乐", "KTV", "唱歌", "门票", "演唱会", "充值", "健身", "会员"]),
            (.food, ["吃饭", "早餐", "午餐", "晚餐", "午饭", "晚饭", "宵夜", "夜宵", "咖啡", "奶茶", "外卖", "点餐", "餐厅", "火锅", "烧烤", "零食", "水果", "买菜", "吃"]),
            (.shopping, ["买衣服", "衣服", "买鞋", "鞋", "购物", "包包", "化妆品", "超市", "商场", "网购", "淘宝", "京东", "买"])
        ]
        for (category, keywords) in rules {
            if keywords.contains(where: { text.contains($0) }) {
                return category
            }
        }
        return .other
    }

}