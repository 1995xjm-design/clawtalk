import SwiftUI

/// 副主页卡片模型：圆角卡片所需数据 + 目标页类型。
struct HomeCard<Destination: View>: Identifiable {
    let id: String
    let title: String
    let icon: String
    let color: Color
    let summary: String
    /// 点击卡片后进入的目标页（占位阶段接占位页，后续由各功能组替换）
    let destination: Destination
}

/// 副主页卡片视图组件：圆角卡片，图标 + 标题 + 摘要，点击进入 destination。
struct HomeCardView<Destination: View>: View {
    let card: HomeCard<Destination>

    var body: some View {
        NavigationLink {
            card.destination
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Image(systemName: card.icon)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(card.color)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 3) {
                    Text(card.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(card.summary)
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
        .accessibilityLabel("\(card.title)卡片")
        .accessibilityValue(card.summary)
        .accessibilityHint("点按进入\(card.title)功能页")
    }
}
