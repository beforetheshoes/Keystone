import SwiftUI
import ComposableArchitecture
import Dependencies

/// Inline lock placeholder rendered by `RecordDetailView` when the user
/// has navigated to a record id that's currently in the privacy hidden
/// set. Distinct from `AppLockView` (full-window launch gate) — this one
/// only blocks the record pane while sidebar/home stay reactive.
///
/// Most users never reach this view: the database list / palette / search
/// already filter hidden records, so the only paths in are deep-link nav
/// or a stale recordID surviving an unlock-then-lock cycle.
struct RecordLockView: View {
    @Bindable var store: StoreOf<AppFeature>
    var recordID: String
    /// Best-effort title. We pull it from a non-filtered direct lookup
    /// (`dbClient.record`) at the call site; nil if the id no longer
    /// exists, in which case we render a generic "protected record"
    /// label instead of leaking metadata.
    var title: String?

    @Dependency(\.biometricAuthClient) private var authClient
    @State private var kind: BiometricKind = .none

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "lock.fill")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(KstColor.ink2)

            VStack(spacing: 6) {
                Text(headline)
                    .font(.kstDisplay(size: 22, weight: .semibold))
                    .foregroundStyle(KstColor.ink0)
                Text("Authenticate to view this record's contents.")
                    .font(.kstText(size: 13))
                    .foregroundStyle(KstColor.ink2)
                    .multilineTextAlignment(.center)
            }

            Button {
                store.send(.unlockRecordRequested(recordID: recordID))
            } label: {
                HStack(spacing: 8) {
                    if store.authInFlight {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: kind.sfSymbol)
                    }
                    Text(buttonTitle)
                        .font(.kstText(size: 13, weight: .semibold))
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.authInFlight)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KstColor.paper0)
        .task {
            kind = authClient.kind()
        }
    }

    private var headline: String {
        if let title, !title.isEmpty {
            return "“\(title)” is protected"
        }
        return "This record is protected"
    }

    private var buttonTitle: String {
        if store.authInFlight { return "Authenticating…" }
        switch kind {
        case .none:     return "Authenticate"
        case .touchID:  return "Unlock with Touch ID"
        case .faceID:   return "Unlock with Face ID"
        case .opticID:  return "Unlock with Optic ID"
        }
    }
}
