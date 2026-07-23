import Foundation

@main
enum ContactCalendarSmokeCheck {
    static func main() throws {
        let contactSource = ArchiveItemSource(
            id: "synthetic-contacts", accountID: "synthetic@example.invalid",
            name: "Contacts", kind: .contacts, entryPath: "synthetic/Contacts.xml"
        )
        let contactXML = """
        <contacts><contact>
          <OPFContactCopyDisplayName>Recovery Contact</OPFContactCopyDisplayName>
          <OPFContactCopyFirstName>Recovery</OPFContactCopyFirstName>
          <OPFContactCopyLastName>Contact</OPFContactCopyLastName>
          <OPFContactCopyBusinessCompany>Example Org</OPFContactCopyBusinessCompany>
          <OPFContactCopyBusinessTitle>Technician</OPFContactCopyBusinessTitle>
          <OPFContactCopyEmailAddressList>
            <contactEmailAddress OPFContactEmailAddressAddress="recovery@example.invalid" OPFContactEmailAddressType="work" />
          </OPFContactCopyEmailAddressList>
          <OPFContactCopyBusinessPhone>555-0100</OPFContactCopyBusinessPhone>
          <OPFContactCopyBusinessAddressStreet>100 Recovery Way</OPFContactCopyBusinessAddressStreet>
          <OPFContactCopyBusinessAddressCity>Testville</OPFContactCopyBusinessAddressCity>
          <OPFContactCopyBusinessAddressState>PA</OPFContactCopyBusinessAddressState>
          <OPFContactCopyBusinessAddressPostalCode>19000</OPFContactCopyBusinessAddressPostalCode>
          <OPFContactCopyBusinessAddressCountry>US</OPFContactCopyBusinessAddressCountry>
          <OPFContactCopyBirthday>1980-04-12T00:00:00Z</OPFContactCopyBirthday>
          <OPFContactCopyCategory>Recovery;VIP</OPFContactCopyCategory>
          <OPFContactCopyNotesPlain>Synthetic note</OPFContactCopyNotesPlain>
          <OPFContactCopyModDate>2026-07-22T14:30:00Z</OPFContactCopyModDate>
        </contact></contacts>
        """
        let contacts = OLMContactParser().parse(data: Data(contactXML.utf8), source: contactSource)
        require(contacts.count == 1, "contact count")
        require(contacts[0].displayName == "Recovery Contact", "contact display name")
        require(contacts[0].emails.first?.address == "recovery@example.invalid", "contact email")
        require(contacts[0].phoneNumbers.first?.number == "555-0100", "contact phone")
        require(contacts[0].postalAddresses.first?.city == "Testville", "contact postal address")
        require(contacts[0].birthday != nil, "contact birthday")
        require(contacts[0].categories == ["Recovery", "VIP"], "contact categories")

        let calendarSource = ArchiveItemSource(
            id: "synthetic-calendar", accountID: "synthetic@example.invalid",
            name: "Calendar", kind: .calendar, entryPath: "synthetic/Calendar.xml"
        )
        let calendarXML = """
        <appointments><appointment>
          <OPFCalendarEventCopyUUID>synthetic-event@example.invalid</OPFCalendarEventCopyUUID>
          <OPFCalendarEventCopySummary>Recovery Window</OPFCalendarEventCopySummary>
          <OPFCalendarEventCopyStartTime>2026-07-22T15:00:00Z</OPFCalendarEventCopyStartTime>
          <OPFCalendarEventCopyEndTime>2026-07-22T16:00:00Z</OPFCalendarEventCopyEndTime>
          <OPFCalendarEventCopyLocation>Recovery Lab</OPFCalendarEventCopyLocation>
          <OPFCalendarEventCopyDescriptionPlain>Synthetic event</OPFCalendarEventCopyDescriptionPlain>
          <OPFCalendarEventCopyAttendeeList>
            <appointmentAttendee OPFCalendarAttendeeName="Test Attendee" OPFCalendarAttendeeAddress="attendee@example.invalid" OPFCalendarAttendeeType="1" OPFCalendarAttendeeStatus="3" OPFCalendarAttendeeResponseRequested="1" />
          </OPFCalendarEventCopyAttendeeList>
          <OPFCalendarEventGetHasReminder>1</OPFCalendarEventGetHasReminder>
          <OPFCalendarEventCopyReminderDelta>15</OPFCalendarEventCopyReminderDelta>
          <OPFCalendarEventIsRecurring>1</OPFCalendarEventIsRecurring>
          <OPFCalendarEventCopyRecurrence>
            <OPFRecurrencePatternType>weekly</OPFRecurrencePatternType>
            <OPFRecurrencePatternInterval>2</OPFRecurrencePatternInterval>
            <OPFRecurrenceGetOccurenceCount>4</OPFRecurrenceGetOccurenceCount>
          </OPFCalendarEventCopyRecurrence>
        </appointment></appointments>
        """
        let events = OLMCalendarParser().parse(data: Data(calendarXML.utf8), source: calendarSource)
        require(events.count == 1, "calendar count")
        require(events[0].title == "Recovery Window", "calendar title")
        require(events[0].attendees.first?.address == "attendee@example.invalid", "calendar attendee")
        require(events[0].attendees.first?.responseRequested == true, "calendar attendee response request")
        require(OLMItemMailboxParser.parse("Test Person <person@example.invalid>").name == "Test Person", "mailbox display name")
        require(events[0].recurrence?.interval == 2, "calendar recurrence")
        require(OLMItemDateParser.parse("2026-07-22T15:00:00") != nil, "timezone-less Outlook date")

        let vcard = String(decoding: ContactCalendarExporter.contactData(contacts, format: .vcf), as: UTF8.self)
        require(vcard.contains("BEGIN:VCARD") && vcard.contains("EMAIL;TYPE=WORK:recovery@example.invalid"), "vCard export")
        require(vcard.contains("ADR;TYPE=BUSINESS") && vcard.contains("BDAY:19800412"), "vCard address and birthday")
        let contactCSV = String(decoding: ContactCalendarExporter.contactData(contacts, format: .csv), as: UTF8.self)
        require(contactCSV.contains("\"Recovery Contact\"") && contactCSV.contains("\"555-0100\""), "contact CSV export")
        let ics = String(decoding: ContactCalendarExporter.calendarData(events, format: .ics), as: UTF8.self)
        let unfoldedICS = ics.replacingOccurrences(of: "\r\n ", with: "")
        require(ics.contains("BEGIN:VCALENDAR") && ics.contains("DTSTART:20260722T150000Z"), "iCalendar date export")
        require(ics.contains("RRULE:FREQ=WEEKLY;INTERVAL=2;COUNT=4"), "iCalendar recurrence export")
        require(unfoldedICS.contains("ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED;RSVP=TRUE"), "iCalendar attendee export")
        let calendarCSV = String(decoding: ContactCalendarExporter.calendarData(events, format: .csv), as: UTF8.self)
        require(calendarCSV.contains("\"Recovery Window\"") && calendarCSV.contains("\"Recovery Lab\""), "calendar CSV export")

        print("Contact/calendar synthetic parser and export checks passed")
        print("Contacts checked: \(contacts.count)")
        print("Calendar events checked: \(events.count)")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { fatalError("Failed: \(label)") }
    }
}
