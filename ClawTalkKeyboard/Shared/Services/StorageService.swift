import Foundation

// MARK: - 存储服务
class StorageService {

    static let shared = StorageService()

    private let userDefaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        // 使用App Groups的UserDefaults实现跨进程数据共享
        if let defaults = UserDefaults(suiteName: AppConstants.appGroupId) {
            userDefaults = defaults
        } else {
            userDefaults = UserDefaults.standard
        }
    }

    // MARK: - Keys
    private enum Keys {
        static let userPreferences = "user_preferences"
        static let keyboardRoleIds = "keyboard_role_ids"
        static let currentRoleId = "current_role_id"
        static let hasCompletedGuide = "has_completed_guide"
        static let selectedTagIds = "selected_tag_ids"
        static let userGender = "user_gender"
        static let userBirthday = "user_birthday"
        static let keyboardType = "keyboard_type"
        static let hapticEnabled = "haptic_enabled"
        static let soundEnabled = "sound_enabled"
    }

    // MARK: - User Preferences
    func saveUserPreferences(_ preferences: UserPreferences) {
        if let data = try? encoder.encode(preferences) {
            userDefaults.set(data, forKey: Keys.userPreferences)
            userDefaults.synchronize()
        }
    }

    func getUserPreferences() -> UserPreferences {
        guard let data = userDefaults.data(forKey: Keys.userPreferences),
              let preferences = try? decoder.decode(UserPreferences.self, from: data) else {
            return UserPreferences()
        }
        return preferences
    }

    // MARK: - Guide Status
    var hasCompletedGuide: Bool {
        get { userDefaults.bool(forKey: Keys.hasCompletedGuide) }
        set {
            userDefaults.set(newValue, forKey: Keys.hasCompletedGuide)
            userDefaults.synchronize()
        }
    }

    // MARK: - Keyboard Roles
    func saveKeyboardRoleIds(_ ids: Set<String>) {
        userDefaults.set(Array(ids), forKey: Keys.keyboardRoleIds)
        userDefaults.synchronize()
    }

    func getKeyboardRoleIds() -> Set<String> {
        let array = userDefaults.stringArray(forKey: Keys.keyboardRoleIds) ?? []
        return Set(array)
    }

    func addRoleToKeyboard(_ roleId: String) {
        var ids = getKeyboardRoleIds()
        ids.insert(roleId)
        saveKeyboardRoleIds(ids)
    }

    func removeRoleFromKeyboard(_ roleId: String) {
        var ids = getKeyboardRoleIds()
        ids.remove(roleId)
        saveKeyboardRoleIds(ids)
    }

    func isRoleAddedToKeyboard(_ roleId: String) -> Bool {
        return getKeyboardRoleIds().contains(roleId)
    }

    // MARK: - Current Role
    var currentRoleId: String? {
        get { userDefaults.string(forKey: Keys.currentRoleId) }
        set {
            userDefaults.set(newValue, forKey: Keys.currentRoleId)
            userDefaults.synchronize()
        }
    }

    // MARK: - Selected Tags
    func saveSelectedTagIds(_ ids: Set<String>) {
        userDefaults.set(Array(ids), forKey: Keys.selectedTagIds)
        userDefaults.synchronize()
    }

    func getSelectedTagIds() -> Set<String> {
        let array = userDefaults.stringArray(forKey: Keys.selectedTagIds) ?? []
        return Set(array)
    }

    // MARK: - User Gender
    var userGender: UserPreferences.Gender? {
        get {
            guard let rawValue = userDefaults.string(forKey: Keys.userGender) else { return nil }
            return UserPreferences.Gender(rawValue: rawValue)
        }
        set {
            userDefaults.set(newValue?.rawValue, forKey: Keys.userGender)
            userDefaults.synchronize()
        }
    }

    // MARK: - User Birthday
    var userBirthday: Date? {
        get { userDefaults.object(forKey: Keys.userBirthday) as? Date }
        set {
            userDefaults.set(newValue, forKey: Keys.userBirthday)
            userDefaults.synchronize()
        }
    }

    // MARK: - Keyboard Type
    var keyboardType: KeyboardType {
        get {
            let rawValue = userDefaults.integer(forKey: Keys.keyboardType)
            return KeyboardType(rawValue: rawValue) ?? .qwerty
        }
        set {
            userDefaults.set(newValue.rawValue, forKey: Keys.keyboardType)
            userDefaults.synchronize()
        }
    }

    // MARK: - Haptic Feedback
    var hapticEnabled: Bool {
        get {
            // 默认开启
            if userDefaults.object(forKey: Keys.hapticEnabled) == nil {
                return true
            }
            return userDefaults.bool(forKey: Keys.hapticEnabled)
        }
        set {
            userDefaults.set(newValue, forKey: Keys.hapticEnabled)
            userDefaults.synchronize()
        }
    }

    // MARK: - Sound Feedback
    var soundEnabled: Bool {
        get { userDefaults.bool(forKey: Keys.soundEnabled) }
        set {
            userDefaults.set(newValue, forKey: Keys.soundEnabled)
            userDefaults.synchronize()
        }
    }

    // MARK: - Clear All Data
    func clearAllData() {
        let keys = [
            Keys.userPreferences,
            Keys.keyboardRoleIds,
            Keys.currentRoleId,
            Keys.hasCompletedGuide,
            Keys.selectedTagIds,
            Keys.userGender,
            Keys.userBirthday,
            Keys.keyboardType,
            Keys.hapticEnabled,
            Keys.soundEnabled
        ]

        for key in keys {
            userDefaults.removeObject(forKey: key)
        }
        userDefaults.synchronize()
    }
}
