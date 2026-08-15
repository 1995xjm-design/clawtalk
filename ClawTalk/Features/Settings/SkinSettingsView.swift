import PhotosUI
import SwiftUI

/// 皮肤设置页：主题（深/浅/跟随系统）、壁纸、全局毛玻璃、灵动岛。
/// 由设置页「皮肤」入口打开（原「外观」区重构）。
struct SkinSettingsView: View {
    @Bindable var store: SettingsStore

    @State private var showThemePhotoPicker = false
    @State private var themePhotoItem: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            Form {
                themeSection
                wallpaperSection
                effectSection
                liveActivitySection
            }
            .navigationTitle("皮肤")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - 主题（深/浅/跟随系统）

    private var themeSection: some View {
        Section {
            Picker("主题", selection: $store.settings.appearance) {
                Text("深色").tag(Appearance.dark)
                Text("浅色").tag(Appearance.light)
                Text("跟随系统").tag(Appearance.system)
            }
            .pickerStyle(.segmented)
            .onChange(of: store.settings.appearance) { _, _ in
                store.save()
            }
        } header: {
            Text("主题")
        } footer: {
            Text("跟随系统：App 自动跟随 iOS 深色/浅色模式切换。")
        }
    }

    // MARK: - 壁纸（原「外观」区改名）

    private var wallpaperSection: some View {
        Section {
            HStack(spacing: 12) {
                Button {
                    applyNoWallpaper()
                } label: {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(.systemGroupedBackground))
                        .frame(width: 54, height: 96)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(
                                    store.settings.homeThemeSource == .noWallpaper
                                        ? Color.accentColor : Color(.separator).opacity(0.5),
                                    lineWidth: store.settings.homeThemeSource == .noWallpaper ? 2.5 : 1
                                )
                        )
                        .overlay(
                            Image(systemName: "rectangle.on.rectangle.slash")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("无壁纸（默认纯色）")
                ForEach(0..<HomeWallpaper.builtinCount, id: \.self) { id in
                    Button {
                        store.updateSettings { settings in
                            settings.homeThemeSource = .systemWallpaper
                            settings.homeWallpaperID = id
                            settings.homeWallpaperChosen = true
                        }
                    } label: {
                        if let image = HomeWallpaper.builtinImage(id: id, size: CGSize(width: 54, height: 96)) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 54, height: 96)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(
                                            store.settings.homeThemeSource == .systemWallpaper && store.settings.homeWallpaperID == id
                                                ? Color.accentColor : Color.clear,
                                            lineWidth: 2.5
                                        )
                                )
                        }
                    }
                    .buttonStyle(.plain)
                        .accessibilityLabel("选择壁纸\(id + 1)")
                }
                Spacer()

            }
            Button {
                showThemePhotoPicker = true
            } label: {
                Label(
                    store.settings.homeThemeSource == .customPhoto ? "更换自定义壁纸" : "从相册选择壁纸",
                    systemImage: "photo.on.rectangle"
                )
            }
            .photosPicker(isPresented: $showThemePhotoPicker, selection: $themePhotoItem, matching: .images)
            .onChange(of: themePhotoItem) { _, item in
                guard let item else { return }
                Task {
                    defer { themePhotoItem = nil }
                    guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                    if let path = HomeWallpaper.saveCustomPhoto(data) {
                        store.updateSettings { settings in
                            settings.customWallpaperPath = path
                            settings.homeThemeSource = .customPhoto
                            settings.homeWallpaperChosen = true
                        }
                    }
                }
            }
            HStack {
                Text("模糊强度")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Slider(value: $store.settings.homeBlurStrength, in: 0.1...1.0)
            }
            .onChange(of: store.settings.homeBlurStrength) { _, _ in
                store.save()
            }
            Button("恢复默认壁纸") {
                applyNoWallpaper()
            }
        } header: {
            Text("壁纸")
        } footer: {
            Text("无壁纸=默认纯色跟随深浅；选壁纸后深浅仅改变叠加与卡片。")
        }
    }

    private func applyNoWallpaper() {
        store.updateSettings { settings in
            settings.homeThemeSource = .noWallpaper
            settings.homeWallpaperID = 0
            settings.homeWallpaperChosen = false
            settings.customWallpaperPath = nil
        }
    }

    // MARK: - 全局毛玻璃

    private var effectSection: some View {
        Section {
            HStack {
                Text("全局毛玻璃")
                Spacer()
                Button {
                    store.settings.globalGlassEnabled.toggle()
                    store.save()
                } label: {
                    Text(store.settings.globalGlassEnabled ? "已开启" : "关闭")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(
                                store.settings.globalGlassEnabled
                                    ? Color.green.opacity(0.18)
                                    : Color(.systemGray5)
                            )
                        )
                        .foregroundStyle(store.settings.globalGlassEnabled ? Color.green : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("效果")
        } footer: {
            Text("开启后主页与频道背景启用磨砂材质（配合壁纸效果最佳）。")
        }
    }

    // MARK: - 灵动岛 / Live Activity

    private var liveActivitySection: some View {
        Section {
            Picker("风格", selection: $store.settings.liveActivityStyle) {
                ForEach(LiveActivityStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: store.settings.appearance) { _, _ in
                store.save()
            }
            .onChange(of: store.settings.liveActivityStyle) { _, _ in
                refreshLiveActivityStyle()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("样式预览（\(store.settings.liveActivityStyle.displayName)）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LiveActivityPreviewCard(
                    style: store.settings.liveActivityStyle,
                    channelName: "语音助手",
                    statusText: "正在聆听…"
                )
            }
            .padding(.vertical, 4)

            Button {
                ClawTalkLiveActivity.start(
                    channelName: "语音助手",
                    initialStatus: "正在聆听…"
                )
            } label: {
                Label("开始预览", systemImage: "play.circle.fill")
            }
            .buttonStyle(.bordered)

            Toggle("随 agent 切换", isOn: $store.settings.liveActivityFollowAgent)
                .onChange(of: store.settings.liveActivityFollowAgent) { _, _ in
                    refreshLiveActivityStyle()
                }
        } header: {
            Text("灵动岛")
        } footer: {
            Text("免提对话期间的锁屏/灵动岛卡片风格：简约=仅状态；标准=频道名+状态；详细=图标+频道名+状态两行。开启「随 agent 切换」后，切换频道/agent 时卡片自动改为新 agent 名称。Live Activity 本地更新仅在 App 前台/后台任务期间生效（未配置 APNs 推送更新）。「开始预览」会真实启动灵动岛卡片。")
        }
    }

    /// 灵动岛风格/「随 agent 切换」变更后，用当前卡片状态按新风格重刷。
    private func refreshLiveActivityStyle() {
        store.save()
        ClawTalkLiveActivity.update(
            statusText: "免提对话",
            icon: "💬"
        )
    }
}

/// 灵动岛样式预览卡：模拟「锁屏顶部灵动岛」视觉（黑胶囊 + 相机挖孔）+ 当前风格卡片文案。
/// 纯 SwiftUI 绘制，不实际启动 Live Activity；点选档位立即重绘（绑定 store 直接驱动）。
private struct LiveActivityPreviewCard: View {
    let style: LiveActivityStyle
    let channelName: String
    let statusText: String

    var body: some View {
        VStack(spacing: 0) {
            // 顶部灵动岛：黑胶囊 + 相机挖孔
            ZStack {
                Capsule()
                    .fill(Color.black)
                    .frame(width: 116, height: 32)
                HStack(spacing: 14) {
                    Circle()
                        .fill(Color.black)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().strokeBorder(Color(white: 0.22), lineWidth: 1))
                    Circle()
                        .fill(Color(white: 0.16))
                        .frame(width: 7, height: 7)
                }
            }
            .frame(height: 46)
            .padding(.top, 10)

            // 当前档位的卡片内容
            Group {
                switch style {
                case .minimal:
                    Text(statusText)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                case .standard:
                    Text("\(channelName) · \(statusText)")
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                case .detailed:
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("💬")
                            Text(channelName)
                                .font(.headline)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        Text(statusText)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.black))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1)
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .accessibilityLabel("灵动岛样式预览：\(style.displayName)")
    }
}
/// 深/浅/跟随系统 → preferredColorScheme（nil=跟随系统）。
extension AppSettings {
    var preferredColorScheme: ColorScheme? {
        switch appearance {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }
}