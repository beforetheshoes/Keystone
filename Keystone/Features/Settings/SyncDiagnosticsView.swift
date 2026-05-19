import SwiftUI
import Dependencies
#if canImport(AppKit)
import AppKit
#endif

/// Sheet hosted by `SyncDiagnosticsSection`. Renders the recent
/// `sync_events` rows with color-coded leading dots, plus action
/// buttons that drive `SyncEngineClient.forcePull` / `forcePush`
/// (no-ops when CloudKit isn't configured — the buttons surface the
/// thrown `notConfigured` error inline so the user sees *why*).
///
/// "Force pull" wording is deliberate even though CKSyncEngine doesn't
/// fetch by time window — it fetches by server-change-token. The Help
/// page (`24-sync-diagnostics.md`) frames the literal semantics.
struct SyncDiagnosticsView: View {
    @Dependency(\.databaseClient) private var dbClient
    @Dependency(\.syncEngineClient) private var syncClient
    @Environment(\.dismiss) private var dismiss

    @State private var events: [SyncEventEntry] = []
    @State private var summary: SyncEventLogger.Summary?
    @State private var inFlightAction: ActionKind?
    @State private var actionError: String?
    @State private var actionResult: String?

    private enum ActionKind: Equatable {
        case pull
        case push
        case clear
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                summaryHeader
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                actionRow
                    .padding(.horizontal, 16)

                if let actionError {
                    Text(actionError)
                        .font(.kstText(size: 12))
                        .foregroundStyle(KstColor.amber)
                        .padding(.horizontal, 16)
                } else if let actionResult {
                    Text(actionResult)
                        .font(.kstText(size: 12))
                        .foregroundStyle(KstColor.sage)
                        .padding(.horizontal, 16)
                }

                Divider()

                eventList
            }
            .navigationTitle("Sync Diagnostics")
            #if os(macOS)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #else
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            #endif
            .task { await refresh() }
        }
    }

    // MARK: - Summary header

    private var summaryHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Last sync")
                    .font(.kstText(size: 11))
                    .foregroundStyle(KstColor.ink2)
                Text(lastSyncDisplay)
                    .font(.kstMono(size: 13))
                    .foregroundStyle(KstColor.ink0)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Events (24h)")
                    .font(.kstText(size: 11))
                    .foregroundStyle(KstColor.ink2)
                Text(summary.map { "\($0.totalEvents)" } ?? "—")
                    .font(.kstMono(size: 13))
                    .foregroundStyle(KstColor.ink0)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Conflicts (24h)")
                    .font(.kstText(size: 11))
                    .foregroundStyle(KstColor.ink2)
                Text(summary.map { "\($0.conflictEvents)" } ?? "—")
                    .font(.kstMono(size: 13))
                    .foregroundStyle((summary?.conflictEvents ?? 0) > 0 ? KstColor.amber : KstColor.ink0)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Action row

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button {
                Task { await runAction(.pull) }
            } label: {
                Label("Force pull", systemImage: "arrow.down.circle")
            }
            .disabled(inFlightAction != nil)

            Button {
                Task { await runAction(.push) }
            } label: {
                Label("Force push", systemImage: "arrow.up.circle")
            }
            .disabled(inFlightAction != nil)

            Spacer()

            Button {
                Task { await refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(inFlightAction != nil)

            Button(role: .destructive) {
                Task { await runAction(.clear) }
            } label: {
                Label("Clear log", systemImage: "trash")
            }
            .disabled(inFlightAction != nil || events.isEmpty)
        }
    }

    // MARK: - Event list

    @ViewBuilder
    private var eventList: some View {
        if events.isEmpty {
            ContentUnavailableView(
                "No sync events",
                systemImage: "bubbles.and.sparkles",
                description: Text(emptyStateDescription)
            )
            .frame(maxHeight: .infinity)
        } else {
            List(events) { event in
                SyncEventRow(event: event)
            }
            .listStyle(.plain)
        }
    }

    private var emptyStateDescription: String {
        if keystoneSyncEngineConfigured {
            return "Sync activity is logged here. Trigger a force-pull or force-push to populate the log."
        }
        return "CloudKit sync isn't configured on this device. Events will appear once the engine starts."
    }

    // MARK: - Display helpers

    private var lastSyncDisplay: String {
        guard let stamp = summary?.lastSyncTimestamp,
              let date = AppDatabase.isoFormatter.date(from: stamp) else { return "—" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Actions

    @MainActor
    private func refresh() async {
        events = (try? dbClient.recentSyncEvents(200)) ?? []
        summary = (try? dbClient.syncEventSummary(24)) ?? .init(
            totalEvents: 0, conflictEvents: 0, lastSyncTimestamp: nil, lastErrorDetails: nil
        )
    }

    @MainActor
    private func runAction(_ kind: ActionKind) async {
        inFlightAction = kind
        actionError = nil
        actionResult = nil
        defer { inFlightAction = nil }

        do {
            switch kind {
            case .pull:
                try await syncClient.forcePull()
                actionResult = "Force pull dispatched."
            case .push:
                try await syncClient.forcePush()
                actionResult = "Force push dispatched."
            case .clear:
                try dbClient.clearSyncEvents()
                actionResult = "Log cleared."
            }
        } catch {
            actionError = error.localizedDescription
        }
        await refresh()
    }
}

// MARK: - Row

private struct SyncEventRow: View {
    let event: SyncEventEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.eventType)
                        .font(.kstText(size: 13, weight: .medium))
                        .foregroundStyle(KstColor.ink0)
                    Spacer(minLength: 8)
                    Text(timeDisplay)
                        .font(.kstMono(size: 11))
                        .foregroundStyle(KstColor.ink3)
                }
                if !subline.isEmpty {
                    Text(subline)
                        .font(.kstMono(size: 11))
                        .foregroundStyle(KstColor.ink2)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var tint: Color {
        switch event.eventType {
        case SyncEventType.syncFailed,
             SyncEventType.engineInitFailed,
             SyncEventType.itemsLost:
            return KstColor.amber
        case SyncEventType.syncSucceeded,
             SyncEventType.engineStarted,
             SyncEventType.itemsRecovered:
            return KstColor.sage
        case SyncEventType.syncBegan,
             SyncEventType.forcePullInvoked,
             SyncEventType.forcePushInvoked:
            return KstColor.ink2
        default:
            return KstColor.ink3
        }
    }

    private var subline: String {
        var parts: [String] = []
        if !event.recordType.isEmpty || !event.recordID.isEmpty {
            let target = [event.recordType, event.recordID].filter { !$0.isEmpty }.joined(separator: ":")
            if !target.isEmpty { parts.append(target) }
        }
        if !event.errorCode.isEmpty { parts.append("code=\(event.errorCode)") }
        if !event.details.isEmpty { parts.append(event.details) }
        return parts.joined(separator: " · ")
    }

    private var timeDisplay: String {
        guard let date = AppDatabase.isoFormatter.date(from: event.timestamp) else {
            return event.timestamp
        }
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f.string(from: date)
    }
}
