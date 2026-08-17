import SwiftUI

/// 网关工作板面板：workboard.boards.list + workboard.cards.list/create/move/archive/dispatch。
/// 默认 7 列：todo / scheduled / ready / running / review / blocked / done。
struct WorkboardPanelView: View {
    var gatewayConnection: GatewayConnection

    @State private var boards: [WorkboardBoard] = []
    @State private var selectedBoardID: String?
    @State private var cards: [WorkboardCard] = []
    @State private var busy = false
    @State private var errorText: String?

    private let defaultColumns = ["todo", "scheduled", "ready", "running", "review", "blocked", "done"]

    var body: some View {
        List {
            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section("看板") {
                if boards.isEmpty && !busy {
                    Text("无看板")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(boards) { board in
                    Button {
                        selectedBoardID = board.id
                        Task { await loadCards(boardID: board.id ?? "") }
                    } label: {
                        HStack {
                            Label(board.name ?? board.id ?? "看板", systemImage: "square.grid.3x2")
                            Spacer()
                            if selectedBoardID == board.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.openClawRed)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Section("卡片") {
                if cards.isEmpty && !busy {
                    Text(selectedBoardID == nil ? "请先选择看板" : "无卡片")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(cards) { card in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(columnColor(card.column))
                            .frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.title ?? card.id ?? "卡片")
                                .font(.subheadline.weight(.medium))
                            if let column = card.column {
                                Text(columnLabel(column))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Menu {
                            Button("移动到待办", systemImage: "arrow.right.circle") {
                                Task { await moveCard(card, to: "todo") }
                            }
                            Button("移动到准备", systemImage: "arrow.right.circle") {
                                Task { await moveCard(card, to: "ready") }
                            }
                            Button("移动到运行", systemImage: "arrow.right.circle") {
                                Task { await moveCard(card, to: "running") }
                            }
                            Button("派发执行", systemImage: "play.circle") {
                                Task { await dispatchCard(card) }
                            }
                            Divider()
                            Button("归档", systemImage: "archivebox", role: .destructive) {
                                Task { await archiveCard(card) }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("工作板")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await refreshAll() }
                } label: {
                    if busy { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(busy)
            }
        }
        .task {
            await refreshAll()
        }
    }

    // MARK: - RPC

    private func refreshAll() async {
        busy = true
        errorText = nil
        defer { busy = false }
        do {
            let data = try await gatewayConnection.request(method: "workboard.boards.list", timeoutMs: 20)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            boards = (try? decoder.decode(WorkboardBoardsResponse.self, from: data))?.boards ?? []
            if let first = boards.first {
                selectedBoardID = first.id
                await loadCards(boardID: first.id ?? "")
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func loadCards(boardID: String) async {
        do {
            let data = try await gatewayConnection.request(
                method: "workboard.cards.list",
                params: ["boardId": AnyCodable(boardID)],
                timeoutMs: 20
            )
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            cards = (try? decoder.decode(WorkboardCardsResponse.self, from: data))?.cards ?? []
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func moveCard(_ card: WorkboardCard, to column: String) async {
        busy = true
        defer { busy = false }
        do {
            var params: [String: AnyCodable] = ["column": AnyCodable(column)]
            if let cardID = card.id { params["cardId"] = AnyCodable(cardID) }
            if let boardID = card.boardId { params["boardId"] = AnyCodable(boardID) }
            _ = try await gatewayConnection.request(method: "workboard.cards.move", params: params, timeoutMs: 20)
            if let boardID = selectedBoardID { await loadCards(boardID: boardID) }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func dispatchCard(_ card: WorkboardCard) async {
        busy = true
        defer { busy = false }
        do {
            var params: [String: AnyCodable] = [:]
            if let cardID = card.id { params["cardId"] = AnyCodable(cardID) }
            if let boardID = card.boardId { params["boardId"] = AnyCodable(boardID) }
            _ = try await gatewayConnection.request(method: "workboard.cards.dispatch", params: params, timeoutMs: 20)
            if let boardID = selectedBoardID { await loadCards(boardID: boardID) }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func archiveCard(_ card: WorkboardCard) async {
        busy = true
        defer { busy = false }
        do {
            var params: [String: AnyCodable] = [:]
            if let cardID = card.id { params["cardId"] = AnyCodable(cardID) }
            if let boardID = card.boardId { params["boardId"] = AnyCodable(boardID) }
            _ = try await gatewayConnection.request(method: "workboard.cards.archive", params: params, timeoutMs: 20)
            if let boardID = selectedBoardID { await loadCards(boardID: boardID) }
        } catch {
            errorText = error.localizedDescription
        }
    }

    // MARK: - Display

    private func columnColor(_ column: String?) -> Color {
        switch column {
        case "todo": return .gray
        case "scheduled": return .cyan
        case "ready": return .orange
        case "running": return .blue
        case "review": return .purple
        case "blocked": return .red
        case "done": return .green
        default: return .gray
        }
    }

    private func columnLabel(_ column: String) -> String {
        switch column {
        case "todo": return "待办"
        case "scheduled": return "计划"
        case "ready": return "准备"
        case "running": return "运行"
        case "review": return "审查"
        case "blocked": return "受阻"
        case "done": return "完成"
        default: return column
        }
    }
}

// MARK: - Models

struct WorkboardBoardsResponse: Codable {
    var boards: [WorkboardBoard]?
}

struct WorkboardBoard: Codable, Identifiable {
    var id: String?
    var name: String?
    var columns: [String]?
}

struct WorkboardCardsResponse: Codable {
    var cards: [WorkboardCard]?
}

struct WorkboardCard: Codable, Identifiable {
    var id: String?
    var boardId: String?
    var title: String?
    var column: String?
    var status: String?
    var createdAt: String?
    var updatedAt: String?
}