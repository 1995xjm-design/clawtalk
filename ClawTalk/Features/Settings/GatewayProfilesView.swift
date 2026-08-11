import SwiftUI

/// 网关管理（任务 D）：多网关档案的列表/切换/增删。
/// 档案独立存储（GatewayProfileStore），切换时写入 SettingsStore 供全局使用。
struct GatewayProfilesView: View {
    @Bindable var store: SettingsStore
    @State private var profileStore: GatewayProfileStore

    @State private var showAddSheet = false
    @State private var editingProfile: GatewayProfile?

    init(store: SettingsStore, profileStore: GatewayProfileStore = GatewayProfileStore()) {
        self.store = store
        _profileStore = State(initialValue: profileStore)
    }

    var body: some View {
        List {
            Section {
                if profileStore.profiles.isEmpty {
                    Text("还没有保存的网关档案。点右上角「+」添加，或在设置页填写网关地址后会自动迁移为第一个档案。")
                        .foregroundStyle(.secondary)
                }
                ForEach(profileStore.profiles) { profile in
                    GatewayProfileRow(
                        profile: profile,
                        isActive: profile.id == profileStore.activeProfileID
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        activateProfile(profile)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            profileStore.delete(profile)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        Button {
                            editingProfile = profile
                        } label: {
                            Label("编辑", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }
            } header: {
                Text("已保存的网关")
            } footer: {
                Text("点击档案即可切换为当前网关；切换会同步地址与令牌到全局设置。")
            }
        }
        .navigationTitle("网关管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            GatewayProfileEditView(profile: nil) { newProfile in
                profileStore.add(
                    name: newProfile.name,
                    url: newProfile.url,
                    token: newProfile.token,
                    note: newProfile.note,
                    activate: true
                )
                profileStore.activate(newProfile, settings: store)
            }
        }
        .sheet(item: $editingProfile) { profile in
            GatewayProfileEditView(profile: profile) { updated in
                profileStore.update(updated)
                if updated.id == profileStore.activeProfileID {
                    profileStore.activate(updated, settings: store)
                }
            }
        }
    }

    private func activateProfile(_ profile: GatewayProfile) {
        guard profile.id != profileStore.activeProfileID else { return }
        profileStore.activate(profile, settings: store)
    }
}

/// 网关档案行：名称/地址/令牌掩码 + 当前标记。
private struct GatewayProfileRow: View {
    let profile: GatewayProfile
    let isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(profile.name.isEmpty ? "未命名网关" : profile.name)
                        .font(.headline)
                    if isActive {
                        Text("当前")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.18), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
                Text(profile.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !profile.token.isEmpty {
                    Text("令牌：••••••")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "arrow.right.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// 添加/编辑网关档案表单。
private struct GatewayProfileEditView: View {
    let profile: GatewayProfile?
    let onSave: (GatewayProfile) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var url: String
    @State private var token: String
    @State private var note: String

    init(profile: GatewayProfile?, onSave: @escaping (GatewayProfile) -> Void) {
        self.profile = profile
        self.onSave = onSave
        _name = State(initialValue: profile?.name ?? "")
        _url = State(initialValue: profile?.url ?? "")
        _token = State(initialValue: profile?.token ?? "")
        _note = State(initialValue: profile?.note ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("名称（如：家里 / 公司 / 测试服）", text: $name)
                    TextField("网关地址（如 https://host）", text: $url)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("网关令牌", text: $token)
                    TextField("备注（可选）", text: $note)
                }
                Section {
                    Button {
                        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmedURL.isEmpty else { return }
                        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
                        let saved = GatewayProfile(
                            id: profile?.id ?? UUID(),
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            url: trimmedURL,
                            token: token.trimmingCharacters(in: .whitespacesAndNewlines),
                            note: trimmedNote.isEmpty ? nil : trimmedNote
                        )
                        onSave(saved)
                        dismiss()
                    } label: {
                        Text(profile == nil ? "保存并设为当前网关" : "保存修改")
                    }
                    .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: {
                    Text("令牌单独保存在 iOS 钥匙串，档案列表只保存地址与名称。")
                }
            }
            .navigationTitle(profile == nil ? "添加网关" : "编辑网关")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
        }
    }
}