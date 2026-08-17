import Foundation

/// 会话分组持久化（对齐官方 SessionGroupStore）：自定义分组名本地保存，
/// 保证空分组在刷新后仍作为移动目标存在；服务端仍以 session category 字段为准。
enum SessionGroupStore {
    static let defaultsKey = "openclaw:sessions:custom-groups"

    static func load(defaults: UserDefaults = .standard) -> [String] {
        normalized(defaults.stringArray(forKey: defaultsKey) ?? [])
    }

    static func save(_ groups: [String], defaults: UserDefaults = .standard) {
        defaults.set(normalized(groups), forKey: defaultsKey)
    }

    static func remember(_ name: String, defaults: UserDefaults = .standard) {
        save(adding(load(defaults: defaults), name), defaults: defaults)
    }

    static func normalized(_ groups: [String]) -> [String] {
        var seen = Set<String>()
        return groups
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func adding(_ groups: [String], _ name: String) -> [String] {
        normalized(groups + [name])
    }

    /// Web 对齐：改名时原分组存在则原位替换，否则追加新名。
    static func renaming(_ groups: [String], from oldName: String, to newName: String) -> [String] {
        let renamed = groups.contains(oldName)
            ? groups.map { $0 == oldName ? newName : $0 }
            : groups + [newName]
        return normalized(renamed)
    }

    static func removing(_ groups: [String], _ name: String) -> [String] {
        normalized(groups.filter { $0 != name })
    }
}
