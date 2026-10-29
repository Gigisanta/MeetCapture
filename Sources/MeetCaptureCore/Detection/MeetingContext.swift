// MeetingContext.swift
// Evidence frozen at recording start. Calendar metadata and speaker identities
// never replace the transcript's acoustic speaker labels.

import Foundation

struct CalendarEventSnapshot: Codable, Equatable, Sendable {
    struct Attendee: Codable, Equatable, Sendable {
        var name: String? = nil
        var email: String?
        var isCurrentUser: Bool

        private enum CodingKeys: String, CodingKey { case name, email, isCurrentUser }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(email, forKey: .email)
            try container.encode(isCurrentUser, forKey: .isCurrentUser)
        }
    }

    var id: String?
    var title: String?
    var start: Date
    var end: Date
    var url: URL?
    var notes: String?
    var attendees: [Attendee]
    var organizer: Attendee? = nil
    /// Nil in older metadata means the event's timed/date-only kind is unknown.
    var isAllDay: Bool? = false

    private enum CodingKeys: String, CodingKey {
        case id, title, start, end, url, notes, attendees, organizer, isAllDay
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encode(url, forKey: .url)
        try container.encode(notes, forKey: .notes)
        try container.encode(attendees, forKey: .attendees)
        try container.encode(organizer, forKey: .organizer)
        try container.encode(isAllDay, forKey: .isAllDay)
    }
}

enum CalendarMatch: String, Codable, Equatable, Sendable {
    case matched, none, ambiguous
}

enum MeetingPlatform: String, Codable, Hashable, Sendable {
    case meet, zoom, teams, other, unknown

    var displayName: String {
        switch self {
        case .meet: return "Google Meet"
        case .zoom: return "Zoom"
        case .teams: return "Microsoft Teams"
        case .other: return "Otra plataforma"
        case .unknown: return "Reunión"
        }
    }
}

/// Keep recognized providers distinct until evidence compatibility is checked;
/// the public `other` category is not proof that two providers are the same.
enum MeetingProvider: Hashable, Sendable {
    case meet, zoom, teams, slack, faceTime, discord, webex, skype, whatsapp, signal, telegram, whereby, jitsi

    var platform: MeetingPlatform {
        switch self {
        case .meet: return .meet
        case .zoom: return .zoom
        case .teams: return .teams
        default: return .other
        }
    }
}

struct PlatformEvidence: Codable, Equatable, Sendable {
    enum Source: String, Codable, Hashable, Sendable {
        case calendarURL = "calendar_url"
        case calendarNotes = "calendar_notes"
        case activeMicrophoneBundle = "active_microphone_bundle"
    }

    let source: Source
    let platform: MeetingPlatform
    let value: String
    var calendarEventId: String? = nil
}

struct SpeakerAttribution: Codable, Equatable, Sendable {
    enum Evidence: String, Codable, Equatable, Sendable {
        case calendarCurrentUser = "calendar_current_user"
        case localMicrophone = "local_microphone"
        case calendarOneToOne = "calendar_one_to_one"
        case singleRemoteDiarization = "single_remote_diarization"
    }

    let name: String?
    let email: String
    let evidence: [Evidence]

    private enum CodingKeys: String, CodingKey { case name, email, evidence }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(email, forKey: .email)
        try container.encode(evidence, forKey: .evidence)
    }
}

struct MeetingContext: Codable, Equatable, Sendable {
    let calendarEvent: CalendarEventSnapshot?
    let calendarMatch: CalendarMatch
    let platform: MeetingPlatform
    let timeZone: String
    let platformEvidence: [PlatformEvidence]

    private enum CodingKeys: String, CodingKey {
        case calendarEvent, calendarMatch, platform, timeZone, platformEvidence
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(calendarEvent, forKey: .calendarEvent)
        try container.encode(calendarMatch, forKey: .calendarMatch)
        try container.encode(platform, forKey: .platform)
        try container.encode(timeZone, forKey: .timeZone)
        try container.encode(platformEvidence, forKey: .platformEvidence)
    }

    static func unmatched(timeZone: String = TimeZone.current.identifier) -> MeetingContext {
        MeetingContext(calendarEvent: nil, calendarMatch: .none, platform: .unknown,
                       timeZone: timeZone, platformEvidence: [])
    }

    /// Only known timed events active at this instant with a recognized
    /// conference URL are candidates. This intentionally does not reuse
    /// auto-record's whitelist, approach window, or next-meeting ordering.
    static func capture(events: [CalendarEventSnapshot], at date: Date,
                        activeBundleIDs: [String],
                        timeZone: String = TimeZone.current.identifier) -> MeetingContext {
        var nativeProviders = Set<MeetingProvider>()
        let microphoneEvidence = Set(activeBundleIDs).sorted().map { bundleID in
            let provider = CallAppMatcher.provider(bundleID: bundleID)
            if let provider { nativeProviders.insert(provider) }
            return PlatformEvidence(source: .activeMicrophoneBundle,
                                    platform: provider?.platform ?? .unknown, value: bundleID)
        }
        var candidate: (event: CalendarEventSnapshot, providers: Set<MeetingProvider>)?
        var candidateCount = 0
        var evidence = microphoneEvidence
        for event in events where event.start <= date && event.end > date {
            let links = conferenceEvidence(for: event)
            evidence.append(contentsOf: links.evidence)
            if event.isAllDay == false, !links.evidence.isEmpty {
                candidateCount += 1
                candidate = (event, links.providers)
            }
        }
        guard candidateCount == 1, let candidate else {
            return MeetingContext(calendarEvent: nil,
                                  calendarMatch: candidateCount == 0 ? .none : .ambiguous,
                                  platform: nativeProviders.count == 1 ? nativeProviders.first?.platform ?? .unknown : .unknown,
                                  timeZone: timeZone, platformEvidence: evidence)
        }
        let providers = nativeProviders.union(candidate.providers)
        guard providers.count == 1, let provider = providers.first else {
            // Even two providers in the public "other" category cannot prove
            // which meeting this capture belongs to. Preserve their raw evidence.
            return MeetingContext(calendarEvent: nil, calendarMatch: .none, platform: .unknown,
                                  timeZone: timeZone, platformEvidence: evidence)
        }
        let platform = provider.platform
        guard nonempty(candidate.event.id) != nil else {
            return MeetingContext(calendarEvent: nil, calendarMatch: .none, platform: platform,
                                  timeZone: timeZone, platformEvidence: evidence)
        }
        return MeetingContext(calendarEvent: candidate.event, calendarMatch: .matched, platform: platform,
                              timeZone: timeZone, platformEvidence: evidence)
    }

    /// Map only a demonstrated 1:1 and the diarizer's actual single-remote label.
    /// Unknown identities, additional invitees, and unrecognized speaker labels
    /// make attribution unsafe; the transcript itself is never relabeled.
    func speakerMap(for speakers: [String], remoteSpeakerCount: Int?) -> [String: SpeakerAttribution] {
        guard calendarMatch == .matched, let event = calendarEvent, event.isAllDay == false,
              Self.nonempty(event.id) != nil,
              remoteSpeakerCount == 1, speakers.contains("Participante 1"),
              speakers.allSatisfy({ $0 == "Yo" || $0 == "Participante 1" }) else { return [:] }
        var participants: [String: CalendarEventSnapshot.Attendee] = [:]
        func include(_ participant: CalendarEventSnapshot.Attendee) -> Bool {
            guard let email = Self.nonempty(participant.email),
                  let separator = email.firstIndex(of: "@"), separator != email.startIndex,
                  email.index(after: separator) != email.endIndex,
                  !email[email.index(after: separator)...].contains("@"),
                  !email.contains(where: { $0.isWhitespace || $0 == "," || $0 == ";" }) else { return false }
            let key = email.lowercased()
            if let existing = participants[key] {
                let existingName = Self.nonempty(existing.name)
                let incomingName = Self.nonempty(participant.name)
                if let existingName, let incomingName, existingName != incomingName { return false }
                participants[key] = .init(name: existingName ?? incomingName, email: existing.email,
                                          isCurrentUser: existing.isCurrentUser || participant.isCurrentUser)
            } else {
                participants[key] = .init(name: Self.nonempty(participant.name), email: email,
                                          isCurrentUser: participant.isCurrentUser)
            }
            return true
        }
        for participant in event.attendees {
            guard include(participant) else { return [:] }
        }
        if let organizer = event.organizer, !include(organizer) { return [:] }
        var currentUser: CalendarEventSnapshot.Attendee?
        var remoteParticipant: CalendarEventSnapshot.Attendee?
        for participant in participants.values {
            if participant.isCurrentUser {
                guard currentUser == nil else { return [:] }
                currentUser = participant
            } else {
                guard remoteParticipant == nil else { return [:] }
                remoteParticipant = participant
            }
        }
        guard let user = currentUser, let guest = remoteParticipant,
              let guestName = guest.name, let guestEmail = guest.email,
              let userEmail = user.email else { return [:] }
        var map = ["Participante 1": SpeakerAttribution(name: guestName, email: guestEmail,
                                                     evidence: [.calendarOneToOne, .singleRemoteDiarization])]
        if speakers.contains("Yo") {
            map["Yo"] = SpeakerAttribution(name: user.name, email: userEmail,
                                            evidence: [.calendarCurrentUser, .localMicrophone])
        }
        return map
    }

    private static func conferenceEvidence(for event: CalendarEventSnapshot)
        -> (providers: Set<MeetingProvider>, evidence: [PlatformEvidence]) {
        var providers = Set<MeetingProvider>()
        var evidence: [PlatformEvidence] = []
        if let url = event.url, let provider = ConferenceURL.provider(for: url) {
            providers.insert(provider)
            evidence.append(.init(source: .calendarURL, platform: provider.platform, value: url.absoluteString,
                                  calendarEventId: event.id))
        }
        if let notes = event.notes {
            for url in ConferenceURL.urls(in: notes) {
                if let provider = ConferenceURL.provider(for: url) {
                    providers.insert(provider)
                    evidence.append(.init(source: .calendarNotes, platform: provider.platform, value: url.absoluteString,
                                          calendarEventId: event.id))
                }
            }
        }
        return (providers, evidence)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

extension MeetingContext {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let event = try container.decodeIfPresent(CalendarEventSnapshot.self, forKey: .calendarEvent)
        let match = try container.decode(CalendarMatch.self, forKey: .calendarMatch)
        let platform = try container.decode(MeetingPlatform.self, forKey: .platform)
        let timeZone = try container.decode(String.self, forKey: .timeZone)
        let evidence = try container.decode([PlatformEvidence].self, forKey: .platformEvidence)
        if match == .matched, event?.isAllDay != false {
            // Older snapshots did not preserve EventKit's all-day flag. Their
            // frozen calendar/person claim cannot establish a timed meeting.
            self.init(calendarEvent: nil, calendarMatch: .none, platform: .unknown,
                      timeZone: timeZone, platformEvidence: evidence)
        } else {
            self.init(calendarEvent: event, calendarMatch: match, platform: platform,
                      timeZone: timeZone, platformEvidence: evidence)
        }
    }
}

/// Parse complete URLs before checking hosts: a trusted hostname appearing in
/// another URL's path, query, credentials, or a lookalike suffix is not evidence.
enum ConferenceURL {
    private static let notesPattern = try! NSRegularExpression(pattern: #"https?://[^\s<>\"']+"#,
                                                               options: [.caseInsensitive])
    private static let trailingPunctuation = CharacterSet(charactersIn: ".,;:!?)]}")

    static func platform(for url: URL) -> MeetingPlatform? {
        provider(for: url)?.platform
    }

    static func provider(for url: URL) -> MeetingProvider? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.user == nil, url.password == nil, let host = url.host?.lowercased() else { return nil }
        if host == "meet.google.com" { return .meet }
        if host == "zoom.us" || host.hasSuffix(".zoom.us") { return .zoom }
        if host == "teams.microsoft.com" || host == "teams.live.com" || host == "teams.cloud.microsoft" { return .teams }
        if host == "whereby.com" { return .whereby }
        if host == "meet.jit.si" { return .jitsi }
        if host.hasSuffix(".webex.com") { return .webex }
        return nil
    }

    static func urls(in notes: String) -> [URL] {
        let range = NSRange(notes.startIndex..<notes.endIndex, in: notes)
        return notesPattern.matches(in: notes, range: range).compactMap { match in
            guard let range = Range(match.range, in: notes) else { return nil }
            return URL(string: String(notes[range]).trimmingCharacters(in: trailingPunctuation))
        }
    }
}
