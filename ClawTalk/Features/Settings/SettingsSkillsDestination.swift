import SwiftUI

/// 技能设置（对齐官方 SettingsSkillsDestination 精简）：
/// 已安装技能列表（skills.status）+ 启用/停用（skills.enable/disable）。
struct SettingsSkillsDestination: View {
    var gatewayConnection: GatewayConnection

    @State private var skills: [InstalledSkillItem] = []
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        List {
            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            Section("已安装技能") {
                if skills.isEmpty && !busy {
                    Text("无技能或网关未支持 skills.status")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(skills) { skill in
                    HStack(spacing: 10) {
                        Image(systemName: "puzzlepiece.fill")
                            .foregroundStyle(skill.enabled == true ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(skill.name ?? skill.id ?? "技能")
                                .font(.subheadline.weight(.medium))
                            if let description = skill.description, !description.isEmpty {
                                Text(description)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { skill.enabled ?? false },
                            set: { newValue in
                                Task { await setEnabled(skill, enabled: newValue) }
                            }))
                        .labelsHidden()
                        .disabled(busy)
                    }
                }
            }
        }
        .navigationTitle("技能设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await refresh() }
                } label: {
                    if busy { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(busy)
            }
        }
        .task { await refresh() }
    }

    private func refresh() async {
        busy = true
        errorText = nil
        defer { busy = false }
        do {
            let data = try await gatewayConnection.request(
                method: "skills.status",
                params: ["agentId": AnyCodable("main")],
                timeoutMs: 20)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            skills = (try? decoder.decode(SkillsStatusEnvelope.self, from: data))?.skills ?? []
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func setEnabled(_ skill: InstalledSkillItem, enabled: Bool) async {
        busy = true
        defer { busy = false }
        let method = enabled ? "skills.enable" : "skills.disable"
        do {
            var params: [String: AnyCodable] = ["agentId": AnyCodable("main")]
            if let id = skill.id, !id.isEmpty {
                params["id"] = AnyCodable(id)
            }
            if let slug = skill.slug, !slug.isEmpty {
                params["slug"] = AnyCodable(slug)
            }
            _ = try await gatewayConnection.request(method: method, params: params, timeoutMs: 20)
            await refresh()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct InstalledSkillItem: Codable, Identifiable {
    var id: String? { skillId ?? slug ?? name }
    var skillId: String?
    var slug: String?
    var name: String?
    var version: String?
    var enabled: Bool?
    var description: String?

    private enum CodingKeys: String, CodingKey {
        case skillId = "id"
        case slug, name, version, enabled, description
    }
}

private struct SkillsStatusEnvelope: Codable {
    var skills: [InstalledSkillItem]?
    var ok: Bool?
}
