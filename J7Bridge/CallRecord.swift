import Foundation
import Combine

enum CallDirection: String, Codable {
    case incoming
    case outgoing
    case missed
}

struct CallRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let number: String
    let name: String?
    let direction: CallDirection
    let date: Date
    let duration: TimeInterval
}

@MainActor
final class CallHistoryStore: ObservableObject {
    @Published private(set) var records: [CallRecord] = []

    private let key = "j7bridge.callHistory.v1"

    init() { load() }

    func add(number: String, name: String?, direction: CallDirection, date: Date = Date(), duration: TimeInterval = 0) {
        records.insert(CallRecord(id: UUID(), number: number, name: name, direction: direction, date: date, duration: duration), at: 0)
        if records.count > 200 { records.removeLast(records.count - 200) }
        save()
    }

    func clear() {
        records.removeAll()
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([CallRecord].self, from: data) else { return }
        records = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
