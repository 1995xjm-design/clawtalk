import SwiftUI
import AVKit

/// 系统投屏按钮（AVRoutePickerView 的 SwiftUI 封装，F2）：
/// 点按弹出系统投屏面板（AirPlay / 隔空播放设备选择）。
struct RoutePickerButton: UIViewRepresentable {
    /// 按钮图标颜色（浅色背景下建议传深色，深色背景下传浅色）。
    var tintColor: UIColor = .white

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = tintColor
        view.activeTintColor = tintColor
        view.prioritizesVideoDevices = true
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = tintColor
        uiView.activeTintColor = tintColor
    }
}
