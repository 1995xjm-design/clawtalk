import PhotosUI
import SwiftUI
import UIKit
import Vision

/// C11：聊天档案·截图 AI 识别（头像 + 名字 -> 确认 -> 入库）。
/// 从相册选一张聊天/通讯录截图，Vision OCR 提取名字候选 + 人脸框裁剪头像，
/// 用户确认（可编辑名字/选分类）后写入档案（L3 长期档案 + App Group 共享 + 网关沉淀）。
struct MemoryProfileScannerView: View {
    let store: MemoryProfileStore

    @Environment(\.dismiss) private var dismiss

    @State private var pickerItem: PhotosPickerItem?
    @State private var pickedImage: UIImage?
    @State private var avatar: UIImage?
    @State private var nameCandidates: [String] = []
    @State private var selectedName = ""
    @State private var isAnalyzing = false
    @State private var analysisError: String?
    @State private var category: MemoryProfile.Category = .fact
    @State private var didConfirm = false

    var body: some View {
        NavigationStack {
            Group {
                if didConfirm {
                    confirmedView
                } else if pickedImage == nil {
                    pickerPrompt
                } else {
                    reviewForm
                }
            }
            .navigationTitle("截图识别档案")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    // MARK: - 步骤 1：选择截图

    private var pickerPrompt: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "person.text.rectangle")
                .font(.system(size: 56))
                .foregroundStyle(Color.openClawRed)
            Text("从聊天截图识别联系人")
                .font(.title3.weight(.semibold))
            Text("选一张包含头像和名字的聊天截图，自动提取名字和头像，确认后存入档案。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label("选择截图", systemImage: "photo.on.rectangle.angled")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.openClawRed)
            .padding(.top, 8)
            Spacer()
        }
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            Task { await loadAndAnalyze(newItem) }
        }
    }

    // MARK: - 步骤 2：识别结果确认

    private var reviewForm: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    avatarView
                        .frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("识别结果")
                            .font(.headline)
                        if isAnalyzing {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("正在识别名字和头像…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else if let analysisError {
                            Text(analysisError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        } else {
                            Text("请确认名字，可手动修改")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("名字") {
                if nameCandidates.isEmpty && !isAnalyzing {
                    TextField("输入联系人名字", text: $selectedName)
                } else {
                    TextField("联系人名字", text: $selectedName)
                    if !nameCandidates.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(nameCandidates, id: \.self) { candidate in
                                    Button {
                                        selectedName = candidate
                                    } label: {
                                        Text(candidate)
                                            .font(.subheadline)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(
                                                Capsule().fill(
                                                    selectedName == candidate
                                                        ? Color.openClawRed.opacity(0.15)
                                                        : Color(.systemGray6)))
                                            .foregroundStyle(selectedName == candidate ? Color.openClawRed : .primary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }

            Section("分类") {
                Picker("分类", selection: $category) {
                    ForEach(MemoryProfile.Category.displayOrder) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.menu)
            }

            Section {
                Button {
                    confirmAndSave()
                } label: {
                    Text("确认并存入档案")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .disabled(trimmedName.isEmpty || isAnalyzing)
            }

            Section {
                Button("重新选择截图") {
                    resetForRePick()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 步骤 3：已入库

    private var confirmedView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("已存入档案")
                .font(.title3.weight(.semibold))
            Text("「\(trimmedName)」已记入「\(category.rawValue)」，并同步到记忆共享。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("完成") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(.openClawRed)
            Spacer()
        }
    }

    private var avatarView: some View {
        Group {
            if let avatar {
                Image(uiImage: avatar)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(Circle())
    }

    private var trimmedName: String {
        selectedName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 识别

    private func loadAndAnalyze(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data)
        else {
            analysisError = "无法读取所选图片"
            return
        }
        pickedImage = image
        avatar = nil
        nameCandidates = []
        selectedName = ""
        analysisError = nil
        isAnalyzing = true
        await analyze(image)
    }

    @MainActor
    private func analyze(_ original: UIImage) async {
        let image = Self.downscaled(original, maxDimension: 1600)
        guard let cgImage = image.cgImage else {
            isAnalyzing = false
            analysisError = "图片格式不支持"
            return
        }

        var detectedFace: CGRect?
        var ocrLines: [String] = []

        await Task.detached(priority: .userInitiated) {
            // 人脸框（头像裁剪）
            if let face = Self.detectLargestFace(cgImage: cgImage) {
                detectedFace = face
            }
            // OCR 文字
            ocrLines = Self.recognizeText(cgImage: cgImage)
        }.value

        nameCandidates = Self.nameCandidates(from: ocrLines)
        selectedName = nameCandidates.first ?? ""
        if let detectedFace, let cropped = Self.cropAvatar(image, faceRect: detectedFace) {
            avatar = cropped
        } else {
            avatar = image
        }
        isAnalyzing = false
    }

    private func confirmAndSave() {
        let name = trimmedName
        guard !name.isEmpty else { return }
        store.addProfileEntry(
            category: category,
            summary: "从聊天截图识别到联系人「\(name)」",
            source: "手机 · 截图识别")
        didConfirm = true
    }

    private func resetForRePick() {
        pickedImage = nil
        pickerItem = nil
        avatar = nil
        nameCandidates = []
        selectedName = ""
        analysisError = nil
        isAnalyzing = false
        didConfirm = false
    }

    // MARK: - Vision 工具

    /// 缩小图片，避免超大截图拖慢 OCR/人脸识别。
    nonisolated private static func downscaled(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    nonisolated private static func detectLargestFace(cgImage: CGImage) -> CGRect? {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        guard let results = request.results, !results.isEmpty else { return nil }
        let box = results.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }!.boundingBox
        // Vision 坐标系原点在左下，转成 UIKit 左上。
        return CGRect(
            x: box.origin.x,
            y: 1 - box.origin.y - box.height,
            width: box.width,
            height: box.height)
    }

    nonisolated private static func recognizeText(cgImage: CGImage) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    /// 从 OCR 文本行里挑「疑似名字」候选：2-6 字、无标点数字、排除常见虚词。
    nonisolated private static func nameCandidates(from lines: [String]) -> [String] {
        let stopwords: Set<String> = [
            "你好", "早上好", "晚上好", "谢谢", "再见", "收到", "好的", "可以", "在吗", "我", "你", "他", "她",
            "今天", "明天", "昨天", "现在", "这个", "那个", "什么", "怎么", "为什么", "知道", "感觉", "觉得",
            "时间", "时候", "地方", "问题", "东西", "消息", "语音", "视频", "通话", "聊天", "联系人",
        ]
        var seen = Set<String>()
        return lines.compactMap { line in
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 2, text.count <= 6,
                  text.rangeOfCharacter(from: CharacterSet.alphanumerics.union(.punctuationCharacters)) == nil,
                  !text.contains(" "),
                  !stopwords.contains(text),
                  seen.insert(text).inserted
            else { return nil }
            return text
        }
    }

    nonisolated private static func cropAvatar(_ image: UIImage, faceRect: CGRect) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        var rect = CGRect(
            x: faceRect.origin.x * width,
            y: faceRect.origin.y * height,
            width: faceRect.width * width,
            height: faceRect.height * height)
        // 向外扩 40% 背景，并夹成正方形。
        let side = max(rect.width, rect.height) * 1.4
        let center = CGPoint(x: rect.midX, y: rect.midY)
        rect = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard rect.width > 1, rect.height > 1,
              let cropped = cgImage.cropping(to: rect)
        else { return nil }
        return UIImage(cgImage: cropped)
    }
}
