//
//  AppleContactsTools.swift
//  SwiftAgentKitMac
//
//  Contacts, read-only: the model needs an address to write to and a name
//  to greet, nothing more. Behind a protocol so the tool is tested without
//  an address book.
//

#if os(macOS)
import Contacts
import Foundation
import SwiftAgentKit

public struct ContactCard: Equatable, Sendable {
    public let name: String
    public let emails: [String]
    public let phones: [String]
    public let organization: String?
    public init(name: String, emails: [String], phones: [String], organization: String?) {
        self.name = name; self.emails = emails; self.phones = phones; self.organization = organization
    }
    public var line: String {
        var parts = [name]
        if let organization, !organization.isEmpty { parts.append("(\(organization))") }
        if !emails.isEmpty { parts.append("✉ " + emails.joined(separator: ", ")) }
        if !phones.isEmpty { parts.append("☎ " + phones.joined(separator: ", ")) }
        return parts.joined(separator: "  ")
    }
}

public protocol ContactsStoring: Sendable {
    func requestAccess() async -> Bool
    func search(_ query: String, limit: Int) throws -> [ContactCard]
}

public final class CNStore: ContactsStoring, @unchecked Sendable {
    private let store = CNContactStore()
    public init() {}

    public static func access() -> AppleAccess {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited: return .granted
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    public func requestAccess() async -> Bool {
        if Self.access() == .granted { return true }
        return (try? await store.requestAccess(for: .contacts)) ?? false
    }

    public func search(_ query: String, limit: Int) throws -> [ContactCard] {
        let keys: [CNKeyDescriptor] = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                                       CNContactEmailAddressesKey as CNKeyDescriptor, CNContactPhoneNumbersKey as CNKeyDescriptor,
                                       CNContactOrganizationNameKey as CNKeyDescriptor]
        var found: [CNContact]
        if query.contains("@") {
            found = try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingEmailAddress: query), keysToFetch: keys)
        } else {
            found = try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: query), keysToFetch: keys)
            if found.isEmpty, query.filter(\.isNumber).count >= 6 {
                found = try store.unifiedContacts(matching: CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: query)), keysToFetch: keys)
            }
        }
        return found.prefix(limit).map { c in
            ContactCard(name: CNContactFormatter.string(from: c, style: .fullName) ?? "",
                        emails: c.emailAddresses.map { $0.value as String },
                        phones: c.phoneNumbers.map { $0.value.stringValue },
                        organization: c.organizationName.isEmpty ? nil : c.organizationName)
        }
    }
}

public struct ContactsSearchTool: AgentTool {
    public let name = "contacts_search"
    public var isReadOnly: Bool { true }
    public let description = "Look someone up in the user's Contacts by name, email or phone number: full name, emails, phones, organisation. Use it to find an address before drafting mail."
    public let parameters = ToolParameters(properties: [
        "query": ToolParameterProperty(type: "string", description: "A name (or part), an email address, or a phone number."),
        "limit": ToolParameterProperty(type: "integer", description: "Most contacts to return (default 10, max 50)."),
    ], required: ["query"])
    public var inputExamples: [String] { [#"{"query": "Sara"}"#] }
    let store: any ContactsStoring
    public init(store: any ContactsStoring = CNStore()) { self.store = store }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let query = stringArg(parameters["query"]) else { return .error(toolCallId: "", toolName: name, message: "query is required.") }
        guard await store.requestAccess() else {
            return .error(toolCallId: "", toolName: name, message: "macOS has not allowed Naseem to read contacts. Allow it in System Settings ▸ Privacy & Security ▸ Contacts.")
        }
        let limit = min(max(intArg(parameters["limit"]) ?? 10, 1), 50)
        let cards = try store.search(query, limit: limit)
        guard !cards.isEmpty else { return .success(toolCallId: "", toolName: name, result: "No contact matches \"\(query)\".") }
        return .success(toolCallId: "", toolName: name, result: cards.map(\.line).joined(separator: "\n"))
    }
}
#endif
