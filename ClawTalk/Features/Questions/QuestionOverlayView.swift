import SwiftUI

/// 网关提问浮层：有 pending 提问时置顶展示，支持提交/跳过。
/// 与 ApprovalOverlayView 并列挂在根视图 overlay。
struct QuestionOverlayView: View {
    var gatewayConnection: GatewayConnection

    @State private var submittingIDs: Set<String> = []

    var body: some View {
        let questions = gatewayConnection.pendingQuestions
        ZStack {
            if !questions.isEmpty {
                Color.black.opacity(0.38)
                    .ignoresSafeArea()
                    .allowsHitTesting(true)
                    .onTapGesture {
                        // 点击遮罩不取消（提问需要显式决策）
                    }
                    .transition(.opacity)

                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(questions) { record in
                            QuestionCardView(
                                record: record,
                                isSubmitting: submittingIDs.contains(record.id),
                                onSubmit: { answers in
                                    submit(record, answers: answers)
                                },
                                onSkip: {
                                    skip(record)
                                }
                            )
                            .transition(.scale(scale: 0.98).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 24)
                    .frame(maxWidth: 460)
                }
                .transition(.scale(scale: 0.98).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: questions.map(\.id))
        .task(id: questions.map(\.id)) {
            while !Task.isCancelled {
                gatewayConnection.pruneExpiredQuestions()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func submit(_ record: QuestionRecord, answers: [String: [String]]) {
        guard !submittingIDs.contains(record.id) else { return }
        submittingIDs.insert(record.id)
        Task {
            defer { submittingIDs.remove(record.id) }
            try? await gatewayConnection.resolveQuestion(id: record.id, answers: answers)
        }
    }

    private func skip(_ record: QuestionRecord) {
        guard !submittingIDs.contains(record.id) else { return }
        submittingIDs.insert(record.id)
        Task {
            defer { submittingIDs.remove(record.id) }
            try? await gatewayConnection.cancelQuestion(id: record.id)
        }
    }
}