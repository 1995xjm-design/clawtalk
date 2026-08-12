import SwiftUI
import CoreLocation
import MapKit
import PhotosUI
import UIKit

/// 停车位置页：
/// - 大按钮「记录当前停车位置」：CLLocationManager 一次性取坐标 + CLGeocoder 反向地址；
/// - 未授权/定位关闭时诚实显示原因，并引导去系统设置；
/// - 记录列表：点击行或导航按钮用系统地图驾车路线找回，相机按钮拍照附注（PhotosPicker），滑动删除/备注；
/// - 全部数据只存本机（UserDefaults + Application Support），失败显示真实原因，不造假。
struct ParkingView: View {
    @State private var store: ParkingStore

    // 定位状态（诚实反馈，不造假）
    @State private var isLocating = false
    @State private var statusMessage: String?
    @State private var showSettingsGuide = false
    @State private var settingsGuideReason = ""

    // 拍照附注（PhotosPicker 选一张存本地）
    @State private var photoTargetRecordID: String?
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var showPhotoPicker = false

    // 备注编辑
    @State private var editingRecord: ParkingRecord?
    @State private var draftNote = ""

    @Environment(\.openURL) private var openURL

    init(store: ParkingStore? = nil) {
        _store = State(initialValue: store ?? ParkingStore())
    }

    var body: some View {
        List {
            Section {
                recordButtonSection
            } header: {
                Text("一键记录")
            }

            Section {
                if store.records.isEmpty {
                    ContentUnavailableView {
                        Label("还没有停车记录", systemImage: "car")
                    } description: {
                        Text("点上方按钮记录当前位置，之后可以导航找回。\n数据只保存在本机。")
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(store.records) { record in
                        recordRow(record)
                    }
                }
            } header: {
                Text(store.records.isEmpty ? "" : "停车记录")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("停车位置")
        .navigationBarTitleDisplayMode(.inline)
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoPickerItem, matching: .images)
        .onChange(of: photoPickerItem) { _, newItem in
            attachPhotoIfNeeded(newItem)
        }
        .sheet(item: $editingRecord) { _ in
            noteEditSheet
        }
        .alert("无法记录停车位置", isPresented: $showSettingsGuide) {
            Button("去设置") {
                openSettings()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(settingsGuideReason)
        }
        .alert("提示", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    // MARK: - 记录按钮

    private var recordButtonSection: some View {
        VStack(spacing: 10) {
            Button {
                recordCurrentLocation()
            } label: {
                HStack(spacing: 10) {
                    if isLocating {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "car.fill")
                    }
                    Text(isLocating ? "正在获取位置…" : "记录当前停车位置")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(.white)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.blue)
                )
            }
            .buttonStyle(.plain)
            .disabled(isLocating)

            if let statusMessage {
                Label(statusMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - 定位

    private func recordCurrentLocation() {
        statusMessage = nil

        guard CLLocationManager.locationServicesEnabled() else {
            statusMessage = "定位服务已关闭，请到系统「设置」里打开"
            return
        }

        let manager = CLLocationManager()
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            statusMessage = "请在系统弹窗中允许定位，然后再次点击「记录」"
        case .denied, .restricted:
            settingsGuideReason = "定位权限未开启，无法获取当前位置。请到系统设置允许 ClawTalk 使用定位。"
            showSettingsGuide = true
        case .authorizedWhenInUse, .authorizedAlways:
            startLocationCapture()
        @unknown default:
            statusMessage = "定位状态未知，请稍后重试"
        }
    }

    private func startLocationCapture() {
        isLocating = true
        statusMessage = nil
        Task {
            defer { isLocating = false }
            do {
                let location = try await ParkingLocationFetcher().fetch()
                let address = await reverseGeocode(location)
                guard let record = store.addRecord(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    address: address
                ) else {
                    statusMessage = "记录保存失败，请重试"
                    return
                }
                statusMessage = "已记录：\(record.address ?? Self.coordinateText(record))"
            } catch let error as ParkingLocationError {
                statusMessage = error.message
            } catch {
                statusMessage = "定位失败：\(AppErrorText.localized(error.localizedDescription))"
            }
        }
    }

    /// 反向地址解析；失败返回 nil（列表诚实显示坐标），不造假地址。
    private func reverseGeocode(_ location: CLLocation) async -> String? {
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            guard let placemark = placemarks.first else { return nil }
            return Self.formattedAddress(from: placemark)
        } catch {
            LogCollector.record(module: "停车位置", "反向地址解析失败：\(AppErrorText.localized(error.localizedDescription))")
            return nil
        }
    }

    private static func formattedAddress(from placemark: CLPlacemark) -> String? {
        let parts = [
            placemark.country,
            placemark.administrativeArea,
            placemark.locality,
            placemark.subLocality,
            placemark.thoroughfare,
            placemark.subThoroughfare
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        let joined = parts.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    private static func coordinateText(_ record: ParkingRecord) -> String {
        String(format: "%.5f, %.5f", record.latitude, record.longitude)
    }

    // MARK: - 记录行

    private func recordRow(_ record: ParkingRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                navigate(to: record)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.title3)
                        .foregroundStyle(.blue)
                        .frame(width: 30)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.address ?? Self.coordinateText(record))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)

                        Text(ParkingDateFormat.string(from: record.recordedAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let note = record.note, !note.isEmpty {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }

                        if let photoPath = record.photoPath,
                           let photoURL = store.photoURL(fileName: photoPath) {
                            ParkingPhotoThumbnail(url: photoURL)
                                .frame(height: 90)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(spacing: 10) {
                Button {
                    navigate(to: record)
                } label: {
                    Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                        .font(.title3)
                }

                Button {
                    photoTargetRecordID = record.id
                    photoPickerItem = nil
                    showPhotoPicker = true
                } label: {
                    Image(systemName: record.photoPath == nil ? "camera.fill" : "photo.fill")
                        .font(.title3)
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.blue)
            .padding(.top, 2)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                store.delete(id: record.id)
            } label: {
                Label("删除", systemImage: "trash")
            }

            Button {
                editingRecord = record
                draftNote = record.note ?? ""
            } label: {
                Label("备注", systemImage: "square.and.pencil")
            }
            .tint(.blue)
        }
    }

    // MARK: - 备注编辑

    private var noteEditSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextField("备注（如：B3 层 27 号车位）", text: $draftNote, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .padding()

                Spacer(minLength: 0)
            }
            .navigationTitle("停车备注")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        editingRecord = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saveNote()
                    }
                    .disabled(draftNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func saveNote() {
        guard var record = editingRecord else { return }
        let trimmed = draftNote.trimmingCharacters(in: .whitespacesAndNewlines)
        record.note = trimmed.isEmpty ? nil : trimmed
        store.update(record)
        editingRecord = nil
    }

    // MARK: - 拍照附注

    private func attachPhotoIfNeeded(_ newItem: PhotosPickerItem?) {
        guard let recordID = photoTargetRecordID, let newItem else {
            photoPickerItem = nil
            return
        }
        photoPickerItem = nil
        Task {
            do {
                let data: Data
                if let loaded = try await newItem.loadTransferable(type: Data.self) {
                    data = loaded
                } else if let fileURL = try await newItem.loadTransferable(type: URL.self) {
                    data = try Data(contentsOf: fileURL)
                } else {
                    store.errorMessage = "读取所选照片失败，请换一张重试"
                    return
                }
                guard let fileName = store.savePhoto(data) else { return }
                guard let index = store.records.firstIndex(where: { $0.id == recordID }) else {
                    store.deletePhoto(fileName: fileName)
                    return
                }
                var record = store.records[index]
                if let oldPhotoPath = record.photoPath {
                    store.deletePhoto(fileName: oldPhotoPath)
                }
                record.photoPath = fileName
                store.update(record)
            } catch {
                store.errorMessage = "保存照片失败：\(AppErrorText.localized(error.localizedDescription))"
            }
        }
    }

    // MARK: - 导航 / 设置

    /// 系统地图导航：MKMapItem.openMaps + 驾车路线（不引第三方 SDK）。
    private func navigate(to record: ParkingRecord) {
        let coordinate = CLLocationCoordinate2D(latitude: record.latitude, longitude: record.longitude)
        let placemark = MKPlacemark(coordinate: coordinate)
        let mapItem = MKMapItem(placemark: placemark)
        mapItem.name = record.address ?? "停车位置"
        let options: [String: Any] = [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
        ]
        MKMapItem.openMaps(with: [mapItem], launchOptions: options)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

// MARK: - 定位获取

/// 停车位置定位错误（面向用户的诚实文案）。
enum ParkingLocationError: LocalizedError {
    case timeout
    case denied

    var message: String {
        switch self {
        case .timeout:
            return "定位超时，请到开阔处重试"
        case .denied:
            return "定位权限未开启，无法获取位置"
        }
    }

    var errorDescription: String? {
        message
    }
}

/// 一次性定位：CLLocationManager.requestLocation + 15 秒超时兜底（不无限转圈）。
final class ParkingLocationFetcher: NSObject, CLLocationManagerDelegate {
    private var manager: CLLocationManager?
    private var continuation: CheckedContinuation<CLLocation, Error>?

    func fetch() async throws -> CLLocation {
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        self.manager = manager
        manager.requestLocation()

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            Task {
                try? await Task.sleep(for: .seconds(15))
                finish(throwing: ParkingLocationError.timeout)
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let location = locations.last {
            finish(returning: location)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let nsError = error as NSError
        if nsError.domain == kCLErrorDomain && nsError.code == CLError.denied.rawValue {
            finish(throwing: ParkingLocationError.denied)
        } else {
            finish(throwing: error)
        }
    }

    private func finish(returning location: CLLocation) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: location)
    }

    private func finish(throwing error: Error) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(throwing: error)
    }
}

// MARK: - 照片缩略图

/// 本地停车照片缩略图（从 Application Support 读取；加载失败诚实显示占位）。
struct ParkingPhotoThumbnail: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.secondarySystemFill))
                    .overlay(
                        Image(systemName: "photo")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 90)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task {
            image = UIImage(contentsOfFile: url.path)
        }
    }
}
