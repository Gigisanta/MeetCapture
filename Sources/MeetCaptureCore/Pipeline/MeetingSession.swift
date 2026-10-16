// MeetingSession.swift
// Identity of one transcription job (recording, import or re-transcription).
// Created exactly once per job so the .pending name, the contract's
// meetingId and the SQLite row can never disagree.

import Foundation

struct MeetingSession: Equatable, Sendable {
    var startedAt: Date
    var title: String?
    /// Stable for the lifetime of this job and unique across jobs created in
    /// the same second (and across app launches).
    let id: String

    init(startedAt: Date, title: String? = nil) {
        self.startedAt = startedAt
        self.title = title
        let epoch = Int64(startedAt.timeIntervalSince1970)
        self.id = "meet-\(epoch)-\(UUID().uuidString.lowercased())"
    }

    var displayTitle: String { title ?? Self.untitled }

    static let untitled = "Untitled Meeting"

    func pendingPath(in meetingsDir: String) -> String { "\(meetingsDir)/\(id).pending" }
}
