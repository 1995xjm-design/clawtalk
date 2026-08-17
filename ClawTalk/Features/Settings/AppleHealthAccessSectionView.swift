import HealthKit
import SwiftUI

/// 健康访问设置（对齐官方 AppleHealthAccessSectionView）：
/// 展示健康数据访问状态 + 请求授权/打开系统设置入口。
struct AppleHealthAccessSectionView: View {
    @State private var isAuthorized = false

    var body: some View {
        List {
            Section {
                HStack {
                    Label("健康数据访问", systemImage: "heart.fill")
                    Spacer()
                    Text(isAuthorized ? "已授权" : "未授权")
                        .font(.caption)
                        .foregroundStyle(isAuthorized ? .green : .orange)
                }
            } header: {
                Text("Apple 健康")
            } footer: {
                Text("用于健康功能卡读取步数、心率等数据；不会上传云端。")
            }
            Section {
                Button {
                    requestAccess()
                } label: {
                    Label(isAuthorized ? "重新授权" : "请求健康访问", systemImage: "checkmark.shield")
                }
                .disabled(!HKHealthStore.isHealthDataAvailable())
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("打开系统设置", systemImage: "gear")
                }
            }
        }
        .navigationTitle("健康访问")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            refresh()
        }
    }

    private func refresh() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let store = HKHealthStore()
        let types: Set<HKObjectType> = [
            HKObjectType.quantityType(forIdentifier: .stepCount)!,
            HKObjectType.quantityType(forIdentifier: .heartRate)!,
            HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!,
        ]
        Task { @MainActor in
            if #available(iOS 17.0, *) {
                let status = try? await store.statusForAuthorizationRequest(toShare: [], read: types)
                isAuthorized = status == .unnecessary
            } else {
                isAuthorized = false
            }
        }
    }

    private func requestAccess() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let store = HKHealthStore()
        let readTypes: Set<HKObjectType> = [
            HKObjectType.quantityType(forIdentifier: .stepCount)!,
            HKObjectType.quantityType(forIdentifier: .heartRate)!,
            HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!,
        ]
        store.requestAuthorization(toShare: [], read: readTypes) { success, _ in
            Task { @MainActor in
                isAuthorized = success
            }
        }
    }
}
