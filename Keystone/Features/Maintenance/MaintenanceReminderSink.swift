import Foundation

/// Seam for delivering next-due alerts to an external system. The
/// concrete EventKit / Apple Reminders integration lands in a
/// follow-up — for now, the engine fires `onNextDueChanged(...)` into
/// a no-op default. Wiring shape:
///
///   1. The next-due engine recomputes statuses (e.g. after a sidecar
///      re-import or an in-app edit moves a maintenance record).
///   2. The dispatcher diffs new vs. last-seen `nextDue*` for each
///      (subject, catalog) pair and forwards changes to the sink.
///   3. A future EventKit sink turns those into actual reminders, with
///      title from the catalog row and trigger date from `nextDue`.
///
/// The protocol lives at the seam so the engine never depends on
/// EventKit (or Calendar permissions, or platform). Tests inject a
/// recording sink to assert the engine fires at the right moments.
public protocol MaintenanceReminderSink: Sendable {
    func onNextDueChanged(
        subjectID: String,
        catalogID: String,
        title: String,
        nextDueDate: Date?,
        nextDueMileage: Int?
    )
}

/// No-op default; registered by the app boot until a real sink is in
/// place. Dropping in a real implementation is a one-line change in
/// the bootstrap.
public struct NoOpMaintenanceReminderSink: MaintenanceReminderSink {
    public init() {}
    public func onNextDueChanged(
        subjectID: String,
        catalogID: String,
        title: String,
        nextDueDate: Date?,
        nextDueMileage: Int?
    ) {}
}

/// Holder used by the engine + view layer to look up the active sink.
/// Replace `current` once a real Apple Reminders integration ships.
public enum MaintenanceReminders {
    nonisolated(unsafe) public static var current: any MaintenanceReminderSink = NoOpMaintenanceReminderSink()
}
