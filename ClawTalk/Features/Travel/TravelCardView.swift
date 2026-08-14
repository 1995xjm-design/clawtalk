import SwiftUI

/// 主页「差旅管家」卡：最近出行 + 剩余天数（或诚实空态），点击进入差旅管家列表。
///
/// 主智能体接线：在 HomeTabView 快捷入口卡片网格（LazyVGrid）里加一行：
///     TravelCardView()
struct TravelCardView: View {
    @State private var store: TravelStore
    @State private var careReminderStore: CareReminderStore

    init(store: TravelStore? = nil, careReminderStore: CareReminderStore? = nil) {
        _store = State(initialValue: store ?? TravelStore())
        _careReminderStore = State(initialValue: careReminderStore ?? CareReminderStore())
    }

    /// 最近一条出行：优先未结束的最近出发，否则最早的一条。
    private var latestTrip: TravelTrip? {
        let active = store.trips.filter { $0.travelStatus != .history }
        if let earliestActive = active.min(by: { $0.departureDate < $1.departureDate }) {
            return earliestActive
        }
        return store.trips.min(by: { $0.departureDate < $1.departureDate })
    }

    var body: some View {
        NavigationLink {
            TravelListView(store: store, careReminderStore: careReminderStore)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Image(systemName: "airplane.departure.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Color.teal)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 3) {
                    Text("差旅管家")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(summaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 128, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
        .buttonStyle(.plain)
    }

    /// 摘要：无出行 → 诚实空态；有出行 → 目的地 + 状态/剩余天数。
    private var summaryText: String {
        guard let trip = latestTrip else {
            return "暂无出行安排，点此添加"
        }
        switch trip.travelStatus {
        case .upcoming:
            return "\(trip.destination) · \(trip.daysUntilDeparture) 天后出发"
        case .ongoing:
            return "\(trip.destination) · 出行中"
        case .history:
            return "最近：\(trip.destination)（已结束）"
        }
    }
}
