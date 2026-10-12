import Foundation
import Combine
import Contacts

struct AppContact: Identifiable, Hashable {
    let id: String
    let givenName: String
    let familyName: String
    let organization: String
    let phones: [String]

    var displayName: String {
        let name = [givenName, familyName].filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? (organization.isEmpty ? "Unknown" : organization) : name
    }
}

@MainActor
final class ContactsManager: ObservableObject {
    @Published private(set) var contacts: [AppContact] = []
    @Published private(set) var authorization = CNAuthorizationStatus.notDetermined

    private let store = CNContactStore()

    init() {
        authorization = CNContactStore.authorizationStatus(for: .contacts)
    }

    func requestAccessAndLoad() {
        authorization = CNContactStore.authorizationStatus(for: .contacts)
        guard authorization != .authorized else {
            load()
            return
        }
        store.requestAccess(for: .contacts) { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.authorization = granted ? .authorized : .denied
                if granted { self?.load() }
            }
        }
    }

    func load() {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return }
        let keys: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor
        ]

        var result: [AppContact] = []
        let request = CNContactFetchRequest(keysToFetch: keys)
        do {
            try store.enumerateContacts(with: request) { contact, _ in
                let phones = contact.phoneNumbers.map { $0.value.stringValue }.filter { !$0.isEmpty }
                guard !phones.isEmpty else { return }
                result.append(AppContact(
                    id: contact.identifier,
                    givenName: contact.givenName,
                    familyName: contact.familyName,
                    organization: contact.organizationName,
                    phones: phones
                ))
            }
            contacts = result.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        } catch {
            contacts = []
        }
    }

    func resolveName(for phoneNumber: String) -> String? {
        guard authorization == .authorized else { return nil }
        let needle = normalize(phoneNumber)
        guard !needle.isEmpty else { return nil }
        return contacts.first(where: { contact in
            contact.phones.contains { normalize($0).hasSuffix(needle) || needle.hasSuffix(normalize($0)) }
        })?.displayName
    }

    func addContact(name: String, phone: String) {
        guard authorization == .authorized else { return }
        let parts = name.split(separator: " ", maxSplits: 1).map(String.init)
        let contact = CNMutableContact()
        contact.givenName = parts.first ?? name
        if parts.count > 1 { contact.familyName = parts[1] }
        contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: phone))]
        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: nil)
        do {
            try store.execute(request)
            load()
        } catch {
            // UI will retain the existing list when Contacts rejects the save.
        }
    }

    private func normalize(_ value: String) -> String {
        let digits = value.filter { $0.isNumber }
        return digits.count > 10 ? String(digits.suffix(10)) : digits
    }
}

