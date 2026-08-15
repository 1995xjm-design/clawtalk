import SwiftUI
import UIKit

/// 档案截图识别确认视图：显示识别出的名字（可编辑）+ 头像预览 + 来源说明，
/// 用户确认后写入记忆档案库（MemoryProfileStore）。
/// 识别不出名字时诚实提示，允许手动输入后入库，不造假。
struct ProfileRecognizeSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// 用户从聊天/相册选中的档案截图。
    let image: UIImage
    /// 用于初始化 MemoryProfileStore（网关配置等）。
    var settings: SettingsStore
    /// 入库成功回调（可选）。
    var onSaved: (() -> Void)?

    @State private var isRecognizing = true
    @State private var recognitionFailed = false
    @State private var nameCandidates: [String] = []
    @State private var nameText = ""
    @State private var avatarImage: UIImage?
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            Group {
                if isRecognizing {
                    recognizingView
                } else if recognitionFailed {
                    failedView
                } else {
                    resultView
                }
            }
            .navigationTitle("识别档案截图")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .alert("提示", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(notice ?? "")
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            await runRecognition()
        }
    }

    // MARK: - 识别中

    private var recognizingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("正在识别名字和头像…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 识别失败（诚实提示 + 手动输入兜底）

    private var failedView: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("未能从截图中识别出名字")
                    .font(.headline)
                Text("可能是图片不清晰或不是档案页截图。你可以手动输入名字后入库。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                originalImagePreview
                nameField
                saveButtons
            }
            .padding(20)
        }
    }

    // MARK: - 识别成功

    private var resultView: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let avatar = avatarImage {
                    Image(uiImage: avatar)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 96, height: 96)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(Color(.systemGray4), lineWidth: 1))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("识别出的名字")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    nameField
                    if nameCandidates.count > 1 {
                        HStack(spacing: 8) {
                            ForEach(nameCandidates, id: \.self) { candidate in
                                Button(candidate) { nameText = candidate }
                                    .font(.caption)
                                    .buttonStyle(.bordered)
                                    .tint(.openClawRed)
                            }
                        }
                    }
                }

                sourceNote
                saveButtons
            }
            .padding(20)
        }
    }

    private var nameField: some View {
        TextField("输入名字", text: $nameText)
            .textFieldStyle(.roundedBorder)
            .font(.body)
            .submitLabel(.done)
    }

    private var originalImagePreview: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxHeight: 120)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(.systemGray4), lineWidth: 1)
            )
    }

    private var sourceNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
            Text("来源：相册选中的聊天档案截图（AI 识别，请确认名字无误）")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var saveButtons: some View {
        HStack(spacing: 12) {
            Button("取消") { dismiss() }
                .buttonStyle(.bordered)
            Button {
                saveProfile()
            } label: {
                Text("确认入库")
            }
            .buttonStyle(.borderedProminent)
            .tint(.openClawRed)
            .disabled(nameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.top, 4)
    }

    // MARK: - 逻辑

    private func runRecognition() async {
        let service = ProfileRecognitionService()
        guard let result = await service.recognize(from: image) else {
            recognitionFailed = true
            isRecognizing = false
            return
        }
        nameCandidates = result.nameCandidates
        avatarImage = result.avatarImage
        if let first = result.nameCandidates.first {
            nameText = first
        }
        recognitionFailed = result.nameCandidates.isEmpty
        isRecognizing = false
    }

    private func saveProfile() {
        let trimmed = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            notice = "请先填写名字"
            return
        }

        let store = MemoryProfileStore(settings: settings)
        let prefix = trimmed + " 的聊天对象档案"
        if store.allEntries.contains(where: { $0.summary.hasPrefix(prefix) }) {
            notice = "已存在同名档案，未重复添加"
            return
        }
        store.addProfileEntry(
            category: .fact,
            summary: prefix + "（来自档案截图 AI 识别）",
            source: "手机 · 档案截图识别",
            date: Date()
        )
        if settings.settings.hapticsEnabled {
            Haptics.impact(.light)
        }
        onSaved?()
        dismiss()
    }
}
