import Contacts
import Foundation

/// 通讯录能力（官方协议对齐）：contacts.search / contacts.add。
/// 数据层真实读写 CNContactStore；invoke 收发由 NodeConnection 完成，
/// 返回结构与官方 OpenClawContactsSearchPayload / OpenClawContactsAddPayload 一致。
enum ContactsCapability {

    /// 联系人条目（官方 OpenClawContactPayload 结构）。
    struct ContactPayload: Encodable {
        let identifier: String
        let displayName: String
        let givenName: String
        let familyName: String
        let organizationName: String
        let phoneNumbers: [String]
        let emails: [String]
    }

    /// contacts.search 响应：{ "contacts": [...] }（官方 OpenClawContactsSearchPayload）。
    struct ContactsSearchPayload: Encodable {
        let contacts: [ContactPayload]
    }

    /// contacts.add 响应：{ "contact": {...} }（官方 OpenClawContactsAddPayload）。
    struct ContactsAddPayload: Encodable {
        let contact: ContactPayload
    }

    enum ContactsError: LocalizedError {
        case denied
        case invalid
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .denied: return "CONTACTS_PERMISSION_REQUIRED: 通讯录权限被拒绝"
            case .invalid: return "CONTACTS_INVALID: 至少提供姓名、组织、电话或邮箱之一"
            case .failed(let message): return "CONTACTS_FAILED: \(message)"
            }
        }
    }

    private static var payloadKeys: [CNKeyDescriptor] {
        [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
        ]
    }

    // MARK: - Search

    /// 按关键词搜索联系人（空关键词列出前 limit 条，官方同款上限 200）；结果与官方 contacts.search 一致。
    static func search(query: String, limit: Int = 20) async throws -> ContactsSearchPayload {
        let store = try await authorizedStore()
        let clampedLimit = max(1, min(limit, 200))
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercaseQuery = trimmedQuery.lowercased()

        var contacts: [ContactPayload] = []
        let request = CNContactFetchRequest(keysToFetch: payloadKeys)

        try store.enumerateContacts(with: request) { contact, stop in
            if !lowercaseQuery.isEmpty,
               !matches(contact, lowercaseQuery: lowercaseQuery, rawQuery: trimmedQuery) {
                return
            }
            contacts.append(payload(from: contact))
            if contacts.count >= clampedLimit {
                stop.pointee = true
            }
        }

        return ContactsSearchPayload(contacts: contacts)
    }

    // MARK: - Add

    /// 新建联系人；同电话/邮箱已存在时直接返回已有条目避免重复（官方 ContactsService.add 同款行为）。
    static func addContact(
        givenName: String?,
        familyName: String?,
        phoneNumber: String?,
        email: String?,
        organization: String?,
        organizationName: String? = nil,
        displayName: String? = nil,
        phoneNumbers: [String]? = nil,
        emails: [String]? = nil
    ) async throws -> ContactsAddPayload {
        let store = try await authorizedStore()

        let given = givenName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let family = familyName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let org = (organizationName ?? organization)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let display = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let phones = normalizeStrings(phoneNumbers) + (phoneNumber.map { normalizeStrings([$0]) } ?? [])
        let emails = normalizeStrings(emails, lowercased: true)
            + (email.map { normalizeStrings([$0], lowercased: true) } ?? [])

        let hasName = !given.isEmpty || !family.isEmpty || !display.isEmpty
        let hasOrg = !org.isEmpty
        let hasDetails = !phones.isEmpty || !emails.isEmpty
        guard hasName || hasOrg || hasDetails else {
            throw ContactsError.invalid
        }

        if !phones.isEmpty || !emails.isEmpty,
           let existing = try findExistingContact(store: store, phoneNumbers: phones, emails: emails) {
            return ContactsAddPayload(contact: payload(from: existing))
        }

        let contact = CNMutableContact()
        contact.givenName = given
        contact.familyName = family
        contact.organizationName = org
        if given.isEmpty, family.isEmpty, !display.isEmpty {
            contact.givenName = display
        }
        contact.phoneNumbers = phones.map {
            CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: $0))
        }
        contact.emailAddresses = emails.map {
            CNLabeledValue(label: CNLabelHome, value: $0 as NSString)
        }

        let saveRequest = CNSaveRequest()
        saveRequest.add(contact, toContainerWithIdentifier: nil)
        try store.execute(saveRequest)

        // 保存成功后 identifier 已生成，优先回读真实数据。
        let saved = try? store.unifiedContact(withIdentifier: contact.identifier, keysToFetch: payloadKeys)
        return ContactsAddPayload(contact: payload(from: saved ?? contact))
    }

    // MARK: - Private

    private static func authorizedStore() async throws -> CNContactStore {
        let store = CNContactStore()
        let authorized = try await store.requestAccess(for: .contacts)
        guard authorized else { throw ContactsError.denied }
        return store
    }

    private static func matches(_ contact: CNContact, lowercaseQuery: String, rawQuery: String) -> Bool {
        let fullName = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
        let matchesName = fullName.lowercased().contains(lowercaseQuery)
        let matchesOrg = contact.organizationName.lowercased().contains(lowercaseQuery)
        let matchesEmail = contact.emailAddresses.contains { ($0.value as String).lowercased().contains(lowercaseQuery) }
        let matchesPhone = contact.phoneNumbers.contains { $0.value.stringValue.contains(rawQuery) }
        return matchesName || matchesOrg || matchesEmail || matchesPhone
    }

    private static func normalizeStrings(_ values: [String]?, lowercased: Bool = false) -> [String] {
        (values ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { lowercased ? $0.lowercased() : $0 }
    }

    /// 按电话/邮箱查找已存在联系人（官方 ContactsService.findExistingContact/matchContacts 同款逻辑）。
    private static func findExistingContact(
        store: CNContactStore,
        phoneNumbers: [String],
        emails: [String]
    ) throws -> CNContact? {
        var matches: [CNContact] = []

        for phone in phoneNumbers {
            let predicate = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: phone))
            matches.append(contentsOf: try store.unifiedContacts(matching: predicate, keysToFetch: payloadKeys))
        }
        for email in emails {
            let predicate = CNContact.predicateForContacts(matchingEmailAddress: email)
            matches.append(contentsOf: try store.unifiedContacts(matching: predicate, keysToFetch: payloadKeys))
        }

        let normalizedPhones = Set(phoneNumbers.map(normalizePhone).filter { !$0.isEmpty })
        let normalizedEmails = Set(emails.map { $0.lowercased() }.filter { !$0.isEmpty })
        var seen = Set<String>()

        for contact in matches {
            guard seen.insert(contact.identifier).inserted else { continue }
            let contactPhones = Set(contact.phoneNumbers.map { normalizePhone($0.value.stringValue) })
            let contactEmails = Set(contact.emailAddresses.map { String($0.value).lowercased() })

            if !normalizedPhones.isEmpty, !contactPhones.isDisjoint(with: normalizedPhones) {
                return contact
            }
            if !normalizedEmails.isEmpty, !contactEmails.isDisjoint(with: normalizedEmails) {
                return contact
            }
        }
        return nil
    }

    private static func normalizePhone(_ phone: String) -> String {
        let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }
        let normalized = String(String.UnicodeScalarView(digits))
        return normalized.isEmpty ? trimmed : normalized
    }

    /// 官方 OpenClawContactPayload 构造（identifier/displayName/organizationName/phoneNumbers/emails）。
    private static func payload(from contact: CNContact) -> ContactPayload {
        ContactPayload(
            identifier: contact.identifier,
            displayName: CNContactFormatter.string(from: contact, style: .fullName)
                ?? "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespacesAndNewlines),
            givenName: contact.givenName,
            familyName: contact.familyName,
            organizationName: contact.organizationName,
            phoneNumbers: contact.phoneNumbers.map(\.value.stringValue),
            emails: contact.emailAddresses.map { String($0.value) }
        )
    }
}

// MARK: - Params

struct ContactsSearchParams: Decodable {
    let query: String
    let limit: Int?

    /// 官方允许缺失 query（等价于列出全部联系人）；缺失时兜底为空字符串。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.query = try container.decodeIfPresent(String.self, forKey: .query) ?? ""
        self.limit = try container.decodeIfPresent(Int.self, forKey: .limit)
    }

    private enum CodingKeys: String, CodingKey {
        case query
        case limit
    }
}

struct ContactsAddParams: Decodable {
    let givenName: String?
    let familyName: String?
    let phoneNumber: String?
    let email: String?
    let organization: String?
    let organizationName: String?
    let displayName: String?
    let phoneNumbers: [String]?
    let emails: [String]?
}
