import SwiftUI
import UIKit

/// AI 分身页（F1）：输入一句话 + 选口吻 → 生成草稿 → 保存/复制。
/// 诚实标注：基于本地档案做「风格模拟」，不是真正克隆。
struct CloneTalkView: View {
    @State private var viewModel: CloneTalkViewModel
    var onBack: (() -> Void)?

    init(
        settingsStore: SettingsStore,
        memoryProfileStore: MemoryProfileStore? = nil,
        onBack: (() -> Void)? = nil
    ) {
        _viewModel = State(initialValue: CloneTalkViewModel(
            settingsStore: settingsStore,
            memoryStore: memoryProfileStore
        ))
        self.onBack = onBack
    }

    var body: some View {
        VStack(spacing: 0) {
            navBar
            Divider().opacity(0.3)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    profileHint
                    inputCard
                    stylePicker
                    generateButton
                    resultCard
                    if !viewModel.drafts.isEmpty {
                        draftsSection
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
        }
    }

    // MARK: - 导航栏

    private var navBar: some View {
        ZStack {
            Text("AI 分身")
                .font(.headline)
            HStack {
                if let onBack {
                    Button(action: onBack) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                            .padding(10)
                            .background(Color(.systemGray5), in: Circle())
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 52)
    }

    // MARK: - 档案提示

    private var profileHint: some View {
        Label(
            viewModel.profileCount > 0
                ? "已读取 \(viewModel.profileCount) 条本地档案作为口吻参考"
                : "暂无本地档案，将按常见口语习惯模仿",
            systemImage: "person.text.rectangle"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    // MARK: - 输入区

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("想说什么 / 想让分身写什么")
                .font(.subheadline.weight(.medium))
            TextEditor(text: $viewModel.inputText)
                .frame(minHeight: 90)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topLeading) {
                    if viewModel.inputText.isEmpty {
                        Text("例如：明天开会怎么跟领导汇报进度")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - 风格选择

    private var stylePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("口吻风格")
                .font(.subheadline.weight(.medium))
            Picker("口吻风格", selection: $viewModel.style) {
                ForEach(CloneStyle.allCases) { style in
                    Text(style.rawValue).tag(style)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - 生成按钮

    private var generateButton: some View {
        Button {
            Task { await viewModel.generate() }
        } label: {
            HStack(spacing: 8) {
                if viewModel.isGenerating {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                    Text("分身思考中…")
                } else {
                    Image(systemName: "sparkles")
                    Text("生成草稿")
                }
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(
                viewModel.isGenerating ? Color.gray : Color.openClawRed,
                in: RoundedRectangle(cornerRadius: 12)
            )
        }
        .disabled(viewModel.isGenerating)
    }

    // MARK: - 结果区

    @ViewBuilder
    private var resultCard: some View {
        if let errorMessage = viewModel.errorMessage {
            Text(errorMessage)
                .font(.footnote)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        if !viewModel.generatedText.isEmpty || viewModel.isGenerating {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("生成结果")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text("风格模拟 · 非真正克隆")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(viewModel.generatedText.isEmpty ? "正在生成…" : viewModel.generatedText)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                if !viewModel.generatedText.isEmpty {
                    HStack(spacing: 12) {
                        Button {
                            UIPasteboard.general.string = viewModel.generatedText
                        } label: {
                            Label("复制", systemImage: "doc.on.doc")
                                .font(.subheadline)
                        }
                        .buttonStyle(.bordered)
                        Button {
                            viewModel.saveDraft()
                        } label: {
                            Label(viewModel.didSaveCurrent ? "已保存" : "保存草稿", systemImage: "bookmark")
                                .font(.subheadline)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.didSaveCurrent)
                    }
                }
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: - 草稿列表

    private var draftsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("草稿（\(viewModel.drafts.count)）")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button("清空", role: .destructive) {
                    viewModel.clearDrafts()
                }
                .font(.footnote)
            }
            ForEach(viewModel.drafts) { draft in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(draft.style.rawValue)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color.openClawRed)
                        Spacer()
                        Text(Self.timeText(draft.createdAt))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(draft.text)
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    Button("删除", role: .destructive) {
                        viewModel.deleteDraft(draft)
                    }
                    .font(.caption)
                }
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }
}
