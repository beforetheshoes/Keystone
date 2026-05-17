import Foundation
import ComposableArchitecture

/// Pure helpers for the "advance book status when progress crosses a
/// threshold" reducer behavior. Pulled out of `AppFeature` so the
/// rules can be unit-tested without spinning up a TestStore.
enum BookStatusNudge {
    /// Produce a follow-up effect that nudges the record's `status`
    /// after a property write. Returns `.none` when the write isn't
    /// progress-related, isn't on a book, or doesn't cross a
    /// threshold.
    static func effectAfterUpdate(
        state: AppFeature.State,
        recordID: String,
        changedKey: String,
        newValue: String
    ) -> Effect<AppFeature.Action> {
        // Trigger only on progress-related writes.
        guard ["current_page", "progress_percent", "progress_mode"].contains(changedKey) else {
            return .none
        }
        // Resolve the record. We accept either the currently-open
        // detail record or one in the list — the post-mutation state
        // already carries the new value in both slots.
        let record: RecordRow? = {
            if state.currentRecord?.id == recordID { return state.currentRecord }
            return state.currentRecords.first { $0.id == recordID }
        }()
        guard let record else { return .none }
        // Database check — books only. The current detail/database
        // route carries the active database id.
        let activeDB: String? = {
            switch state.nav {
            case let .database(id): return id
            case let .record(id, _): return id
            case let .view(viewID):
                return state.views.first(where: { $0.id == viewID })?.databaseID
            default: return nil
            }
        }()
        guard activeDB == "books" else { return .none }

        let status = (record.values["status"] ?? "").trimmingCharacters(in: .whitespaces)
        guard let nudge = computeNudge(record: record, status: status) else { return .none }

        var effects: [Effect<AppFeature.Action>] = []
        if nudge.newStatus != status {
            effects.append(.send(.updatePropertyValue(
                recordID: recordID, key: "status", value: nudge.newStatus
            )))
        }
        if nudge.stampFinishedDate {
            effects.append(.send(.updatePropertyValue(
                recordID: recordID, key: "finished_date", value: todayISODate()
            )))
        }
        if nudge.stampStartedDate {
            effects.append(.send(.updatePropertyValue(
                recordID: recordID, key: "started_date", value: todayISODate()
            )))
        }
        return effects.isEmpty ? .none : .merge(effects)
    }

    /// What the nudge rules say to do for a single record. Pure;
    /// covered by unit tests.
    struct Outcome: Equatable {
        var newStatus: String
        var stampStartedDate: Bool
        var stampFinishedDate: Bool
    }

    static func computeNudge(record: RecordRow, status: String) -> Outcome? {
        let mode = (record.values["progress_mode"] ?? "").trimmingCharacters(in: .whitespaces)
        let fraction: Double = {
            if mode == "percent" {
                let pct = Double(record.values["progress_percent"] ?? "") ?? 0
                return min(1.0, pct / 100.0)
            }
            let cur = Double(record.values["current_page"] ?? "") ?? 0
            let total = (Double(record.values["readable_pages"] ?? "")
                ?? Double(record.values["page_count"] ?? "")) ?? 0
            guard total > 0 else { return 0 }
            return min(1.0, cur / total)
        }()

        // Don't override a deliberate "abandoned" or "read" status.
        if status == "abandoned" { return nil }

        if fraction >= 1.0 {
            // Hit the end → mark read + stamp finished_date if blank.
            let stampFinish = (record.values["finished_date"] ?? "").isEmpty
            let stampStart = (record.values["started_date"] ?? "").isEmpty
            return Outcome(
                newStatus: "read",
                stampStartedDate: stampStart,
                stampFinishedDate: stampFinish
            )
        }

        if fraction > 0 && (status.isEmpty || status == "to_read") {
            // Just started → mark reading + stamp started_date if blank.
            let stampStart = (record.values["started_date"] ?? "").isEmpty
            return Outcome(
                newStatus: "reading",
                stampStartedDate: stampStart,
                stampFinishedDate: false
            )
        }

        return nil
    }
}

/// `YYYY-MM-DD` today, in the user's local calendar. Cheap to build
/// each call — used at most twice per status nudge, not in a hot
/// loop, so we skip the formatter cache to dodge `Sendable` woes.
private func todayISODate() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate, .withDashSeparatorInDate]
    return formatter.string(from: Date())
}
