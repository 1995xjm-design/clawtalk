import Foundation
import UIKit
import Vision

/// 聊天对象档案截图识别结果。
struct ProfileRecognitionResult {
    /// 按「像名字」程度排序的名字候选（可能为空）。
    var nameCandidates: [String]
    /// 从截图中裁剪出的头像预览（人脸检测失败时退回左上角候选区，以用户确认为准）。
    var avatarImage: UIImage?
    /// 原始截图，用于界面展示来源。
    var originalImage: UIImage
}

/// 用系统 Vision OCR 从聊天对象档案截图（含头像+名字）中识别名字文本与头像区域。
/// 诚实原则：只取高置信度文本；名字候选取「最像名字」的行并过滤 UI 噪音；
/// 识别不出名字时返回空候选，由界面提示用户手动输入，不造假。
struct ProfileRecognitionService {
    /// 识别置信度下限。
    private static let minConfidence: Float = 0.5
    /// 聊天/资料页常见 UI 噪音词，命中即排除（消息/设置/聊天 等）。
    private static let noiseKeywords: [String] = [
        "消息", "设置", "聊天", "备注", "标签", "地区", "微信号", "更多", "添加",
        "通讯录", "视频", "语音", "照片", "收藏", "位置", "个人", "签名", "群聊",
        "置顶", "提醒", "权限", "朋友圈", "服务", "公众号", "搜索", "拍一拍",
        "删除", "拉黑", "加入", "企业", "名片", "详情", "昵称", "时间", "今天",
        "昨天", "上午", "下午", "刚刚", "星期", "在线", "忙碌", "状态", "扫一扫",
        "发消息", "通话", "订单", "钱包", "付款", "账单", "资料", "修改", "编辑"
    ]

    /// 对一张截图做识别：返回名字候选 + 头像预览 + 原图；无法识别时返回 nil（界面诚实提示）。
    func recognize(from image: UIImage) async -> ProfileRecognitionResult? {
        guard let cgImage = image.cgImage else { return nil }
        let textLines = recognizeTextLines(in: cgImage)
        let faceRects = detectFaceRects(in: cgImage)
        let nameCandidates = Self.bestNameCandidates(from: textLines)
        let avatar = Self.cropAvatar(in: image, faceRects: faceRects)
        return ProfileRecognitionResult(
            nameCandidates: nameCandidates,
            avatarImage: avatar,
            originalImage: image
        )
    }

    // MARK: - OCR

    /// 提取高置信度文本行（vision 归一化坐标 -> 图片坐标，原点左上）。
    private func recognizeTextLines(in cgImage: CGImage) -> [(text: String, boundingBox: CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.minimumTextHeight = 0.01

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        var lines: [(String, CGRect)] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence >= Self.minConfidence else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let box = observation.boundingBox
            let rect = CGRect(
                x: box.minX * width,
                y: (1 - box.maxY) * height,
                width: box.width * width,
                height: box.height * height
            )
            lines.append((text, rect))
        }
        return lines
    }

    // MARK: - 名字候选

    /// 过滤噪音后按「像名字」程度排序去重，返回最多 3 个候选。
    static func bestNameCandidates(from lines: [(text: String, boundingBox: CGRect)]) -> [String] {
        let sorted = lines
            .map { (text: $0.text, score: nameScore($0.text)) }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
        var seen = Set<String>()
        var unique: [String] = []
        for item in sorted where seen.insert(item.text).inserted {
            unique.append(item.text)
        }
        return Array(unique.prefix(3))
    }

    /// 名字打分：命中噪音词/过短/过长/含标点/纯数字 一律排除；2-6 字中文名得分最高。
    private static func nameScore(_ raw: String) -> Int {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2, text.count <= 16 else { return 0 }
        guard !noiseKeywords.contains(where: { text.contains($0) }) else { return 0 }

        let scalars = text.unicodeScalars
        let cjkCount = scalars.filter { isCJK($0) }.count
        let letterCount = scalars.filter { CharacterSet.letters.contains($0) }.count
        let digitCount = scalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        let punctuationCount = scalars.filter {
            CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0)
        }.count

        // 数字为主的行（手机号/时间）不是名字
        if digitCount > letterCount + cjkCount { return 0 }
        // 没有任何中英文字符（纯符号）不是名字
        guard cjkCount + letterCount >= 2 else { return 0 }
        // 含标点的行（句子/按钮文案）不是名字
        if punctuationCount > 0 { return 0 }

        var score = 0
        if cjkCount > 0 { score += 200 }
        score += min(cjkCount, 6) * 30
        score += min(letterCount, 10) * 15
        // 2-4 字纯中文名最典型，加权重
        if cjkCount >= 2, cjkCount <= 4, cjkCount == text.count { score += 60 }
        // 过长惩罚
        if text.count > 8 { score -= 40 }
        return score
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }

    // MARK: - 头像区域

    /// 人脸检测（可选）：返回归一化坐标下的人脸框（vision 坐标系，原点左下）。
    private func detectFaceRects(in cgImage: CGImage) -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        return (request.results ?? []).map { $0.boundingBox }
    }

    /// 裁剪头像预览：优先取人脸框（外扩成方形）；无人脸时退回左上角候选区。
    static func cropAvatar(in image: UIImage, faceRects: [CGRect]) -> UIImage? {
        let width = image.size.width
        let height = image.size.height
        guard width > 0, height > 0 else { return nil }

        var target: CGRect
        if let face = faceRects.first {
            let faceRect = CGRect(
                x: face.minX * width,
                y: (1 - face.maxY) * height,
                width: face.width * width,
                height: face.height * height
            )
            let side = max(faceRect.width, faceRect.height) * 1.8
            target = CGRect(
                x: faceRect.midX - side / 2,
                y: faceRect.midY - side / 2,
                width: side,
                height: side
            )
        } else {
            // 聊天资料页头像通常在左上区域：取顶部方形候选区
            let side = min(width * 0.42, height * 0.36)
            target = CGRect(x: (width - side) * 0.06, y: (height - side) * 0.04, width: side, height: side)
        }
        return crop(image: image, to: target)
    }

    /// 把目标矩形钳制到图片内并裁剪（返回预览图，最终以用户确认为准）。
    static func crop(image: UIImage, to rect: CGRect) -> UIImage? {
        let bounds = CGRect(origin: .zero, size: image.size)
        let clamped = rect.intersection(bounds)
        guard !clamped.isEmpty, clamped.width > 1, clamped.height > 1 else { return nil }
        return UIGraphicsImageRenderer(size: clamped.size).image { _ in
            image.draw(at: CGPoint(x: -clamped.minX, y: -clamped.minY))
        }
    }
}
