import SwiftUI

/// 网关提问卡片（官方 question 协议）：展示问题、选项、多选/其他输入，提交或跳过。
struct QuestionCardView: View {
    var record: QuestionRecord
    var isSubmitting: Bool
    var onSubmit: ([String: [String]]) -> Void
    var onSkip: () -> Void

    @State private var selected: [String: Set<String>] = [:]
    @State private var otherText: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(.blue)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(record.questions.first?.header ?? "网关提问")
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    if let agent = record.agentId {
                        Text("智能体：\(agent)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let remaining = max(0, record.expiresAt.timeIntervalSinceNow)
                    Text("\(Int(remaining))s")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(remaining < 30 ? .red : .secondary)
                        .monospacedDigit()
                }
            }

            ForEach(record.questions) { question in
                questionSection(question)
            }

            HStack(spacing: 12) {
                Button(action: onSkip) {
                    Label("跳过", systemImage: "forward.end")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                .disabled(isSubmitting)

                Button {
                    onSubmit(collectAnswers())
                } label: {
                    if isSubmitting {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    } else {
                        Label("提交", systemImage: "checkmark")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(isSubmitting || !canSubmit)
            }
        }
        .padding(16)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
    }

    @ViewBuilder
    private func questionSection(_ question: Question) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Text(question.question)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                if question.isSecret == true {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(question.options, id: \.self) { option in
                optionRow(option, question: question)
            }

            if question.isOther == true {
                otherRow(question)
            }
        }
        .padding(10)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func optionRow(_ option: QuestionOption, question: Question) -> some View {
        let isSelected = isSelected(option.label, in: question)
        return Button {
            toggle(option.label, in: question)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected
                    ? (question.multiSelect == true ? "checkmark.square.fill" : "largecircle.fill.circle")
                    : (question.multiSelect == true ? "square" : "circle"))
                    .foregroundStyle(isSelected ? Color.blue : Color.secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    if let desc = option.description, !desc.isEmpty {
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(8)
            .background(isSelected ? Color.blue.opacity(0.08) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func otherRow(_ question: Question) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("自定义回答…", text: Binding(
                get: { otherText[question.questionId] ?? "" },
                set: { otherText[question.questionId] = $0 }
            ))
            .font(.subheadline)
            .textFieldStyle(.roundedBorder)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Selection helpers

    private func isSelected(_ label: String, in question: Question) -> Bool {
        selected[question.questionId]?.contains(label) == true
    }

    private func toggle(_ label: String, in question: Question) {
        var set = selected[question.questionId] ?? []
        if question.multiSelect == true {
            if set.contains(label) { set.remove(label) } else { set.insert(label) }
        } else {
            set = [label]
        }
        selected[question.questionId] = set
    }

    private var canSubmit: Bool {
        for question in record.questions {
            let chosen = selected[question.questionId] ?? []
            if !chosen.isEmpty { return true }
            if question.isOther == true, let text = otherText[question.questionId], !text.isEmpty {
                return true
            }
        }
        return false
    }

    private func collectAnswers() -> [String: [String]] {
        var answers: [String: [String]] = [:]
        for question in record.questions {
            var values = Array(selected[question.questionId] ?? [])
            if question.isOther == true, let text = otherText[question.questionId], !text.isEmpty {
                values.append(text)
            }
            if !values.isEmpty {
                answers[question.questionId] = values
            }
        }
        return answers
    }
}