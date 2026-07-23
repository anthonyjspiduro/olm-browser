import Foundation

@main
enum ItemCacheSmokeCheck {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OLMItemCacheSmoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let archive = URL(fileURLWithPath: "/synthetic/archive.olm")
        let cache = try OLMItemCache(
            archiveURL: archive, fileSize: 123, modifiedAt: Date(timeIntervalSince1970: 456),
            cacheRoot: root
        )
        let contact = ContactRecord(
            id: "contact-1", sourceID: "contacts.xml", displayName: "Synthetic Contact",
            firstName: "Synthetic", middleName: "", lastName: "Contact",
            company: "Example", jobTitle: "Technician",
            emails: [.init(label: "work", address: "synthetic@example.invalid")],
            phoneNumbers: [.init(label: "work", number: "555-0100")],
            notes: "Synthetic only", modifiedAt: Date(timeIntervalSince1970: 100),
            postalAddresses: [], birthday: nil, categories: ["Synthetic"]
        )
        let event = CalendarEventRecord(
            id: "event-1", sourceID: "calendar.xml", title: "Synthetic Event",
            startAt: Date(timeIntervalSince1970: 200), endAt: Date(timeIntervalSince1970: 300),
            location: "Lab", details: "", organizer: "", attendees: [],
            isAllDay: false, isPrivate: false, hasReminder: false,
            reminderMinutes: nil, recurrence: nil
        )

        cache.storeContacts([contact], sourceID: "contacts.xml")
        cache.storeCalendarEvents([event], sourceID: "calendar.xml")
        require(cache.contacts(for: "contacts.xml") == [contact], "contact round trip")
        require(cache.calendarEvents(for: "calendar.xml") == [event], "calendar round trip")
        require(cache.contacts(for: "other.xml") == nil, "source isolation")
        require(cache.byteCount > 0, "cache size")
        try cache.removeAll()
        require(cache.contacts(for: "contacts.xml") == nil, "cache deletion")
        print("Contact and calendar cache checks passed")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { fatalError("Failed: \(label)") }
    }
}
