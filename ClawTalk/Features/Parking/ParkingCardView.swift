import SwiftUI

/// 副主页「停车位置」卡：最近一条停车摘要（地址 + 时间），无记录时诚实空态；点击进入停车页。
/// 与 ReminderCardView/HabitCardView 同款圆角卡片结构，自带 NavigationLink。
struct ParkingCardView: View {
    @State private var store: ParkingStore

    init(store: ParkingStore? = nil) {
        _store = State(initialValue: store ?? ParkingStore())
    }

    var body: some View {
        NavigationLink {
            ParkingView(store: store)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Image(systemName: "car.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Color.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 3) {
                    Text("停车位置")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    ParkingCardSummary(store: store)
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
        .onAppear {
            store.reload()
        }
    }
}

/// 停车卡摘要文案：最近一条地址 + 时间；无记录诚实空态，不造假。
struct ParkingCardSummary: View {
    let store: ParkingStore

    var body: some View {
        Text(summaryText)
    }

    private var summaryText: String {
        guard let latest = store.latestRecord else {
            return "尚未记录停车位置，点这里记录"
        }
        let place = latest.address ?? String(format: "%.5f, %.5f", latest.latitude, latest.longitude)
        return "\(place) · \(ParkingDateFormat.string(from: latest.recordedAt))"
    }
}
