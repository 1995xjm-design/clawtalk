import SwiftUI
import Foundation

/// 口述文档详情页：
/// - 标题可编辑（实时写回 DictationStore）
/// - 内容分段展示 + 要点 + 整理来源（诚实标注 AI/本地）
/// - 一键导出/分享（ShareLink 生成 txt 临时文件）
/// - 原始转写可展开查看、可删除
struct DictationDetailView: View {
    private let store: DictationStore
    @State private var currentNote: DictationNote
    @State private var showRawTranscript = false
    @State private var exportFileURL: URL?
    @Environment(\.dismiss) private var dismiss

    init(note: DictationNote, store: DictationStore) {
        self.store = store
        _currentNote = State(initialValue: note)
    }

    var body: some View {
        List {
            headerSection
            if !currentNote.paragraphs.isEmpty {
                paragraphsSection
            }
            if !currentNote.keyPoints.isEmpty {
                keyPointsSection
            }
            exportSection
            rawTranscriptSection
            deleteSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("文档详情")
        .navigationBarTitleDisplayMode(.inline)
        .task { rebuildExportFile() }
        .onChange(of: currentNote.title) {
            store.update(currentNote)
            rebuildExportFile()
        }
    }

    // MARK: - 头部（标题可编辑 + 整理来源 + 日期）

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                TextField("文档标题", text: $currentNote.title)
                    .font(.title3.weight(.semibold))

                HStack(spacing: 8) {
                    Label(
                        currentNote.organizationLabel,
                        systemImage: currentNote.organizedByAI ? "sparkles" : "exclamationmark.triangle"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(currentNote.organizedByAI ? .teal : .orange)

                    Spacer()

                    Text(Self.dateTimeText(currentNote.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - 内容分段

    private var paragraphsSection: some View {
        Section {
            ForEach(Array(currentNote.paragraphs.enumerated()), id: \.offset) { index, paragraph in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(index + 1). \(paragraph)")
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("正文")
        }
    }

    // MARK: - 要点

    private var keyPointsSection: some View {
        Section {
            ForEach(Array(currentNote.keyPoints.enumerated()), id: \.offset) { index, point in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                    Text(point)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("要点")
        }
    }

    // MARK: - 导出/分享（txt 临时文件）

    private var exportSection: some View {
        Section {
            if let exportFileURL {
                ShareLink(item: exportFileURL, preview: SharePreview("\(currentNote.title) · txt")) {
                    Label("导出/分享为 txt", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.medium))
                }
            } else {
                Label("导出文件生成失败", systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("导出")
        }
    }

    // MARK: - 原始转写 / 删除

    private var rawTranscriptSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showRawTranscript) {
                Text(currentNote.rawTranscript)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } label: {
                Label("原始转写", systemImage: "text.quote")
            }
        }
    }

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                store.delete(id: currentNote.id)
                dismiss()
            } label: {
                HStack {
                    Spacer()
                    Text("删除这篇文档")
                    Spacer()
                }
            }
        }
    }

    // MARK: - 导出文件生成

    private func rebuildExportFile() {
        let content = exportText
        let fileName = "\(Self.safeFileName(currentNote.title))-口述文档.txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try content.data(using: .utf8)?.write(to: url, options: .atomic)
            exportFileURL = url
        } catch {
            exportFileURL = nil
        }
    }

    /// 导出内容：标题 + 整理来源/日期 + 正文分段 + 要点 + 原始转写（如实导出，不造假）。
    private var exportText: String {
        var lines: [String] = []
        lines.append(currentNote.title)
        lines.append("")
        lines.append("整理方式：\(currentNote.organizationLabel)")
        lines.append("口述日期：\(Self.dateTimeText(currentNote.date))")
        lines.append("")
        for (index, paragraph) in currentNote.paragraphs.enumerated() {
            lines.append("\(index + 1). \(paragraph)")
            lines.append("")
        }
        if !currentNote.keyPoints.isEmpty {
            lines.append("要点：")
            for point in currentNote.keyPoints {
                lines.append("- \(point)")
            }
            lines.append("")
        }
        if !currentNote.rawTranscript.isEmpty {
            lines.append("—— 原始转写 ——")
            lines.append(currentNote.rawTranscript)
        }
        return lines.joined(separator: "\n")
    }

    private static func safeFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
        return cleaned.isEmpty ? "口述文档" : cleaned
    }

    // MARK: - 工具

    private static func dateTimeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }
}
