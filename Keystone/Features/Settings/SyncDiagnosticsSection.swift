import SwiftUI
import Dependencies

/// Settings → Sync Diagnostics. Sits as a sibling Section inside
/// `SettingsView`'s Form, between Attachments and Behavior. Shows
/// headline numbers from the local-only `sync_events` log; the button
/// opens the full diagnostic sheet with force-pull / force-push and
/// a per-event timeline.
///
/// When CloudKit isn't configured (CLI bootstraps, dev builds without
/// iCloud entitlements), the table is still present and writable —
/// `engine_init_failed` events show up here, and the rest of the rows
/// stay empty. The button itself stays enabled so the user can read
/// the (likely-empty) log.
struct SyncDiagnosticsSection: View {
    @Dependency(\.databaseClient) private var dbClient

    @State private var summary: SyncEventLogger.Summary?
    @State private var isSheetPresented = false

    var body: some View {
        Section {
            LabeledContent("Last sync") {
                Text(formattedLastSync)
                    .font(.kstMono(size: 12))
                    .foregroundStyle(KstColor.ink1)
            }
            LabeledContent("Events (24h)") {
                Text(formattedCount(summary?.totalEvents))
                    .font(.kstMono(size: 12))
                    .foregroundStyle(KstColor.ink1)
            }
            LabeledContent("Conflicts (24h)") {
                Text(formattedCount(summary?.conflictEvents))
                    .font(.kstMono(size: 12))
                    .foregroundStyle(conflictTint)
            }
            if let err = summary?.lastErrorDetails {
                LabeledContent("Last error") {
                    Text(err)
                        .font(.kstMono(size: 11))
                        .foregroundStyle(KstColor.amber)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.trailing)
                }
            }

            Button {
                isSheetPresented = true
            } label: {
                HStack {
                    Image(systemName: "stethoscope")
                    Text("Open sync diagnostics…")
                }
            }
        } header: {
            Text("Sync Diagnostics")
        } footer: {
            Text("A local-only log of CloudKit sync activity on this device. Use the diagnostics sheet to force a pull or push, see recent conflicts, and copy events for support.")
        }
        .task { await refresh() }
        .sheet(isPresented: $isSheetPresented, onDismiss: {
            Task { await refresh() }
        }) {
            SyncDiagnosticsView()
                #if os(macOS)
                .frame(minWidth: 580, minHeight: 520)
                #endif
        }
    }

    @MainActor
    private func refresh() async {
        summary = (try? dbClient.syncEventSummary(24)) ?? .init(
            totalEvents: 0, conflictEvents: 0, lastSyncTimestamp: nil, lastErrorDetails: nil
        )
    }

    private var formattedLastSync: String {
        guard let stamp = summary?.lastSyncTimestamp,
              let date = Self.iso.date(from: stamp) else { return "—" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    private var conflictTint: Color {
        (summary?.conflictEvents ?? 0) > 0 ? KstColor.amber : KstColor.ink1
    }

    private func formattedCount(_ n: Int?) -> String {
        guard let n else { return "—" }
        return n.formatted(.number)
    }

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
