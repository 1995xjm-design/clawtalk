import SwiftUI

/// 网关自定义头：以键值对列表形式编辑，保存到 AppSettings.customHeaders，
/// 由 OpenClawClient 在发起 OpenClaw 网关请求时附加。
struct GatewayHeadersView: View {
    let settings: SettingsStore

    @State private var newName = ""
    @State private var newValue = ""

    var body: some View {
        List {
            Section {
                if settings.settings.customHeaders.isEmpty {
                    Text("暂无自定义头")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(settings.settings.customHeaders.keys.sorted(), id: \.self) { name in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                if let value = settings.settings.customHeaders[name] {
                                    Text(value)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                            Button {
                                settings.settings.customHeaders.removeValue(forKey: name)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("删除请求头")

                        }
                    }
                }
            } header: {
                Text("已添加的头")
            } footer: {
                Text("自定义头仅附加到 OpenClaw 网关请求（聊天/响应接口），不会用于其他服务；名称留空的项会被忽略。")
            }

            Section {
                TextField("名称（如 x-api-key）", text: $newName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("值", text: $newValue)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("添加") {
                    addHeader()
                }
                .disabled(trimmedName.isEmpty)
            } header: {
                Text("添加新头")
            }
        }
        .navigationTitle("网关自定义头")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var trimmedName: String {
        newName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedValue: String {
        newValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addHeader() {
        let name = trimmedName
        guard !name.isEmpty else { return }
        settings.settings.customHeaders[name] = trimmedValue
        newName = ""
        newValue = ""
    }
}