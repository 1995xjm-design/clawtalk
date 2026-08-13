import SwiftUI
import UIKit
import Foundation

/// 位置提醒（围栏）列表页：
/// - 授权引导：未授权申请 / 被拒去系统设置 / 定位服务关闭 / 设备不支持（诚实提示）
/// - 围栏列表：名称 / 类型 / 坐标 / 半径 / 事件徽章 / 开关，滑动删除，点按编辑
/// - 新增：右上角「+」弹出简单表单（名称 / 类型 / 事件 / 提醒文案 / 当前位置或手动经纬度 / 半径）
/// - 诚实空状态：没有围栏时如实显示，不造假。
struct GeofenceListView: View {
    @State private var store: GeofenceStore
    @State private var showEditor = false
    @State private var editingRegion: GeofenceRegion?

    init(store: GeofenceStore? = nil) {
        _store = State(initialValue: store ?? GeofenceStore.shared)
    }

    var body: some View {
        List {
            statusSection
            regionsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("位置提醒")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editingRegion = nil
                    showEditor = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showEditor) {
            NavigationStack {
                GeofenceEditView(store: store, region: editingRegion)
            }
        }
        .onAppear {
            store.refreshAuthorizationState()
            store.startMonitoringIfNeeded()
        }
        .overlay(alignment: .bottom) {
            GlobalVoiceInputFloating(settingsStore: SettingsStore())
                .padding(.bottom, 20)
        }
    }

    // MARK: - 授权 / 能力状态（诚实引导，不假装可用）

    @ViewBuilder
    private var statusSection: some View {
        if !store.isLocationServicesEnabled {
            Section {
                Label("系统定位服务未开启，无法使用位置提醒。", systemImage: "location.slash.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("去系统设置开启定位") {
                    openSystemSettings()
                }
            } header: {
                Text("定位服务")
            }
        } else if !store.isMonitoringAvailable {
            Section {
                Label("当前设备 / 模拟器不支持围栏监听，位置提醒不会触发。", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("设备能力")
            }
        } else if store.isDenied {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("定位权限被拒绝，进入 / 离开时不会收到提醒。", systemImage: "location.slash.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("去系统设置开启") {
                        openSystemSettings()
                    }
                }
            } header: {
                Text("定位权限")
            }
        } else if store.authorizationStatus == .notDetermined {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("需要定位权限，才能在你进入 / 离开围栏时提醒。", systemImage: "location.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("允许定位") {
                        store.requestAuthorizationIfNeeded()
                    }
                }
            } header: {
                Text("定位权限")
            }
        } else if store.notificationPermissionDenied {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("通知权限被拒绝，收不到围栏提醒。", systemImage: "bell.slash.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("去系统设置开启") {
                        openSystemSettings()
                    }
                }
            } header: {
                Text("通知权限")
            }
        }
    }

    // MARK: - 围栏列表

    private var regionsSection: some View {
        Section {
            if store.regions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("还没有位置提醒")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("点右上角「+」添加家或公司，进入 / 离开时会收到本地通知。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            } else {
                ForEach(store.regions) { region in
                    regionRow(region)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.delete(id: region.id)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
            }
        } header: {
            Text("我的围栏")
        } footer: {
            if !store.regions.isEmpty {
                Text("围栏事件由系统级监听投递，App 未打开时也能收到提醒。")
            }
        }
    }

    private func regionRow(_ region: GeofenceRegion) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                editingRegion = region
                showEditor = true
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: region.type.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(typeColor(region.type))
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(region.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("\(region.coordinateText) · \(region.radiusText)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            GeofenceEventBadge(event: region.event)
                            if !region.message.isEmpty {
                                Text(region.message)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)

            Toggle("", isOn: enabledBinding(for: region))
                .labelsHidden()
        }
        .padding(.vertical, 2)
    }

    private func enabledBinding(for region: GeofenceRegion) -> Binding<Bool> {
        Binding(
            get: { region.enabled },
            set: { store.setEnabled($0, for: region.id) }
        )
    }

    private func typeColor(_ type: GeofenceType) -> Color {
        switch type {
        case .home: return .green
        case .work: return .blue
        case .custom: return .gray
        }
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

/// 事件徽章：进入时(绿) / 离开时(橙) / 进入和离开(蓝)。
struct GeofenceEventBadge: View {
    let event: GeofenceEvent

    var body: some View {
        Text(event.displayName)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(badgeColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(badgeColor.opacity(0.14), in: Capsule())
    }

    private var badgeColor: Color {
        switch event {
        case .onEntry: return .green
        case .onExit: return .orange
        case .both: return .blue
        }
    }
}

/// 新增 / 编辑围栏表单（sheet）：
/// - 名称 / 类型（家 / 公司 / 自定义）/ 事件（进入 / 离开 / 两者）
/// - 提醒文案（占位示例「到家了，记得收快递」）
/// - 位置：一键「使用当前位置」（复用 LocationCapability）或手动输入经纬度
/// - 半径滑块（50 ~ 1000 米，默认 100）
private struct GeofenceEditView: View {
    @Environment(\.dismiss) private var dismiss

    let store: GeofenceStore
    let region: GeofenceRegion?

    @State private var name: String
    @State private var type: GeofenceType
    @State private var event: GeofenceEvent
    @State private var message: String
    @State private var radius: Double
    @State private var latitudeText: String
    @State private var longitudeText: String
    @State private var isUsingCurrentLocation = false
    @State private var locationError: String?

    init(store: GeofenceStore, region: GeofenceRegion? = nil) {
        self.store = store
        self.region = region
        _name = State(initialValue: region?.name ?? "")
        _type = State(initialValue: region?.type ?? .home)
        _event = State(initialValue: region?.event ?? .both)
        _message = State(initialValue: region?.message ?? "")
        _radius = State(initialValue: region?.radius ?? 100)
        _latitudeText = State(initialValue: region.map { String(format: "%.6f", $0.latitude) } ?? "")
        _longitudeText = State(initialValue: region.map { String(format: "%.6f", $0.longitude) } ?? "")
    }

    var body: some View {
        Form {
            Section("基本信息") {
                TextField("名称（如：家）", text: $name)
                Picker("类型", selection: $type) {
                    ForEach(GeofenceType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                Picker("事件", selection: $event) {
                    ForEach(GeofenceEvent.allCases) { event in
                        Text(event.displayName).tag(event)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("提醒文案") {
                TextField("例如：到家了，记得收快递", text: $message)
                    .textInputAutocapitalization(.never)
            }

            Section("位置") {
                if isUsingCurrentLocation {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在获取当前位置…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        Task { await fetchCurrentLocation() }
                    } label: {
                        Label("使用当前位置", systemImage: "location.fill")
                    }
                }

                TextField("纬度（-90 ~ 90）", text: $latitudeText)
                    .keyboardType(.numbersAndPunctuation)
                TextField("经度（-180 ~ 180）", text: $longitudeText)
                    .keyboardType(.numbersAndPunctuation)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("半径")
                            .font(.subheadline)
                        Spacer()
                        Text(radiusText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $radius, in: 50...1000, step: 50)
                }
                .padding(.vertical, 2)
            }

            if let locationError {
                Section {
                    Label(locationError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle(region == nil ? "新增位置提醒" : "编辑位置提醒")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    save()
                }
            }
        }
    }

    private var radiusText: String {
        radius >= 1000 ? "\(Int(radius / 1000)) 公里" : "\(Int(radius)) 米"
    }

    private func fetchCurrentLocation() async {
        isUsingCurrentLocation = true
        locationError = nil
        defer { isUsingCurrentLocation = false }
        do {
            let result = try await LocationCapability.getLocation()
            latitudeText = String(format: "%.6f", result.latitude)
            longitudeText = String(format: "%.6f", result.longitude)
        } catch {
            locationError = "获取当前位置失败：\(error.localizedDescription)"
        }
    }

    private func parsedLatitude() -> Double? {
        guard let value = Double(latitudeText.trimmingCharacters(in: .whitespacesAndNewlines)),
              (-90...90).contains(value)
        else { return nil }
        return value
    }

    private func parsedLongitude() -> Double? {
        guard let value = Double(longitudeText.trimmingCharacters(in: .whitespacesAndNewlines)),
              (-180...180).contains(value)
        else { return nil }
        return value
    }

    private func save() {
        guard let latitude = parsedLatitude(), let longitude = parsedLongitude() else {
            locationError = "请填写有效经纬度（纬度 -90 ~ 90，经度 -180 ~ 180）"
            return
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            locationError = "请输入围栏名称"
            return
        }
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)

        if let existing = region {
            var updated = existing
            updated.name = trimmedName
            updated.type = type
            updated.event = event
            updated.message = trimmedMessage
            updated.radius = radius
            updated.latitude = latitude
            updated.longitude = longitude
            store.update(updated)
        } else {
            store.add(
                GeofenceRegion(
                    name: trimmedName,
                    latitude: latitude,
                    longitude: longitude,
                    radius: radius,
                    type: type,
                    event: event,
                    message: trimmedMessage
                )
            )
        }
        dismiss()
    }
}
